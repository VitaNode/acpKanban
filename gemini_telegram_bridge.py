import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
from pathlib import Path
from dotenv import load_dotenv

# Switching to the new google-genai package
try:
    from google import genai
    from google.genai import types
    USE_NEW_SDK = True
except ImportError:
    import google.generativeai as genai_legacy
    USE_NEW_SDK = False

from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, MessageHandler, filters

# --- Configuration & Setup ---
load_dotenv()
TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY")

# Global state for engine
CURRENT_ENGINE = "gemini" # Default engine

# Initialize Clients
if USE_NEW_SDK:
    client = genai.Client(api_key=GEMINI_API_KEY)
else:
    genai_legacy.configure(api_key=EMBEDDING_API_KEY)
    summary_model_legacy = genai_legacy.GenerativeModel('gemini-2.5-flash')

# --- Enhanced Logging Setup ---
Path("logs").mkdir(exist_ok=True)

# 1. Standard logging for console (User-friendly)
logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)

# 2. Silent Debug Logger (File only, isolated from terminal)
debug_logger = logging.getLogger("debug_trace")
debug_logger.setLevel(logging.DEBUG)
debug_logger.propagate = False # Crucial: Don't show debug_logger outputs on console

def update_debug_handler():
    """Dynamically updates the debug log file based on current date."""
    today = datetime.date.today().isoformat()
    log_file = f"logs/{today}.log"
    # Remove old handlers
    for h in debug_logger.handlers[:]:
        debug_logger.removeHandler(h)
    # Add new daily handler
    fh = logging.FileHandler(log_file, encoding='utf-8')
    fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
    debug_logger.addHandler(fh)

console = logging.getLogger("bot_activity")

def play_notification_sound():
    """Plays a system sound on macOS to notify message delivery."""
    try:
        subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
    except Exception:
        pass

def parse_cli_response(engine, raw_stdout):
    """Parses JSON output based on the engine type."""
    try:
        data = json.loads(raw_stdout)
        if engine == "gemini":
            return data.get("response", "✅ Done.")
        elif engine == "qwen":
            if isinstance(data, list):
                for item in data:
                    if item.get("type") == "result":
                        return item.get("result", "✅ Done.")
            return "✅ Done (Result not found in JSON)."
    except json.JSONDecodeError:
        return raw_stdout or "✅ Done (No output)."
    except Exception as e:
        return f"⚠️ Parsing Error: {str(e)}"

# --- Tier 1: Log Manager ---
class LogManager:
    def __init__(self, log_dir="logs"):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)

    def write_log(self, engine, user_text, bot_response):
        today = datetime.date.today().isoformat()
        log_file = self.log_dir / f"{today}.md"
        timestamp = datetime.datetime.now().strftime("%H:%M:%S")
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"### [{timestamp}] [{engine.upper()}] User\n{user_text}\n\n")
            f.write(f"### [{timestamp}] [{engine.upper()}] Response\n{bot_response}\n\n---\n\n")

# --- Tier 3: Optimized Vector Memory ---
class VectorMemory:
    def __init__(self, storage_path="gemini_memory/memory.json", max_entries=500):
        self.storage_path = Path(storage_path)
        self.max_entries = max_entries
        self.memory = self._load()

    def _load(self):
        if self.storage_path.exists():
            try:
                with open(self.storage_path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                logging.error(f"Error loading memory: {e}")
        return []

    def _save(self):
        if len(self.memory) > self.max_entries:
            self.memory = self.memory[-self.max_entries:]
        self.storage_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.storage_path, "w", encoding="utf-8") as f:
            json.dump(self.memory, f, ensure_ascii=False, indent=2)

    def _cosine_similarity(self, v1, v2):
        dot_product = sum(a * b for a, b in zip(v1, v2))
        mag1 = math.sqrt(sum(a * a for a in v1))
        mag2 = math.sqrt(sum(b * b for b in v2))
        return dot_product / (mag1 * mag2) if mag1 > 0 and mag2 > 0 else 0

    async def add_entry(self, text):
        try:
            if USE_NEW_SDK:
                result = client.models.embed_content(
                    model="gemini-embedding-001", 
                    contents=text,
                    config=types.EmbedContentConfig(task_type="RETRIEVAL_DOCUMENT")
                )
                embedding = result.embeddings[0].values
            else:
                result = genai_legacy.embed_content(model="models/gemini-embedding-001", content=text, task_type="retrieval_document")
                embedding = result['embedding']
                
            self.memory.append({
                "text": text,
                "embedding": embedding,
                "timestamp": datetime.datetime.now().isoformat()
            })
            self._save()
        except Exception as e:
            logging.error(f"Vector error: {e}")

    async def search(self, query, top_k=3):
        if not self.memory: return []
        try:
            if USE_NEW_SDK:
                result = client.models.embed_content(
                    model="gemini-embedding-001",
                    contents=query,
                    config=types.EmbedContentConfig(task_type="RETRIEVAL_QUERY")
                )
                qe = result.embeddings[0].values
            else:
                result = genai_legacy.embed_content(model="models/gemini-embedding-001", content=query, task_type="retrieval_query")
                qe = result['embedding']
                
            sims = sorted([(self._cosine_similarity(qe, e['embedding']), e['text']) for e in self.memory], reverse=True)
            return sims[:top_k]
        except Exception as e:
            logging.error(f"Search error: {e}"); return []

# --- Tier 2: Summary Manager ---
class SummaryManager:
    def __init__(self, summary_path="gemini_memory/memory_summary.md"):
        self.summary_path = Path(summary_path)

    def get_latest_facts(self, count=10):
        if not self.summary_path.exists(): return ""
        try:
            with open(self.summary_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
            return "".join(lines[-count*10:])
        except: return ""

    async def generate_daily_summary(self, log_dir, vector_memory):
        today = datetime.date.today().isoformat()
        log_file = Path(log_dir) / f"{today}.md"
        if not log_file.exists(): 
            return f"No logs found for today ({today})."
        
        update_debug_handler() # Ensure correct daily log file
        try:
            with open(log_file, "r", encoding="utf-8") as f:
                logs = f.read()
            
            prompt = f"Extract permanent facts, user preferences, and system states from these logs. Be concise. Format as bullet points.\n\nLOGS:\n{logs}"
            debug_logger.debug(f"Summary Prompt Sent:\n{prompt}")

            if USE_NEW_SDK:
                response = client.models.generate_content(
                    model='gemini-2.5-flash',
                    contents=prompt
                )
                facts = response.text
            else:
                response = await asyncio.to_thread(summary_model_legacy.generate_content, prompt)
                facts = response.text
            
            debug_logger.debug(f"Summary Result:\n{facts}")

            with open(self.summary_path, "a", encoding="utf-8") as f:
                f.write(f"\n### {today} Permanent Facts\n{facts}\n")
            
            await vector_memory.add_entry(f"System Knowledge Summary ({today}): {facts}")
            return f"✅ Facts for {today} summarized and stored."
        except Exception as e:
            debug_logger.error(f"Summary Task Failed: {str(e)}")
            return f"❌ Summary Error: {str(e)}"

# --- Initialize ---
log_m = LogManager()
vec_m = VectorMemory(max_entries=300)
sum_m = SummaryManager()

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global CURRENT_ENGINE
    update_debug_handler() # Ensure debug logs go to the correct daily file
    
    user_id = update.effective_user.id
    console.info(f"📥 Received from {user_id}: {update.message.text[:50]}...")
    debug_logger.info(f"--- Handling Message (Engine: {CURRENT_ENGINE}) ---")
    
    if user_id != ALLOWED_USER_ID:
        console.warning(f"Unauthorized User ID: {user_id}")
        return

    user_text = update.message.text
    if not user_text: return

    # --- Manual Command Handling ---
    if user_text.startswith("/engine"):
        parts = user_text.split()
        if len(parts) > 1:
            new_engine = parts[1].lower()
            if new_engine in ["gemini", "qwen"]:
                CURRENT_ENGINE = new_engine
                await update.message.reply_text(f"🚀 Engine switched to: **{CURRENT_ENGINE.upper()}**", parse_mode='Markdown')
            else:
                await update.message.reply_text("⚠️ Unknown engine.")
        else:
            await update.message.reply_text(f"🤖 Current Engine: **{CURRENT_ENGINE.upper()}**")
        return

    if user_text == "/summary":
        res = await sum_m.generate_daily_summary("logs", vec_m)
        await update.message.reply_text(res)
        play_notification_sound()
        return

    # --- Normal Dialogue Handling with RAG ---
    relevant = await vec_m.search(user_text, top_k=2)
    recent_convo = vec_m.memory[-3:] if vec_m.memory else []
    recent_str = "\n".join([f"- {m['text']}" for m in recent_convo])
    permanent_facts = sum_m.get_latest_facts()
    
    # Optimized System Instruction distilled from agent.md
    system_instruction = (
        "\n\n[System Instruction]:\n"
        "- Your name is '探机' (Probe), an efficient AI assistant for '老兵'.\n"
        "- Style: Simple, direct, no fluff. Skip pleasantries like 'Good question'.\n"
        "- Primary Workspace: Perform all file/tool operations within './workspace/'.\n"
        "- Active Memory: Proactively record key facts/decisions into './workspace/agent.md' or 'memory_summary.md'.\n"
        "- Guidelines: Your full operational manual and 'soul' are defined in './workspace/agent.md'. Read it if unsure about memory or safety rules."
    )

    context_str = ""
    if permanent_facts: context_str += f"\n\n[Permanent Facts/Knowledge]:\n{permanent_facts}"
    if recent_str: context_str += f"\n\n[Recent Conversation History]:\n{recent_str}"
    if relevant:
        semantic_str = "\n".join([f"- {t}" for _, t in relevant if t not in recent_str])
        if semantic_str: context_str += f"\n\n[Related Past Context]:\n{semantic_str}"

    status_msg = await update.message.reply_text(f"🧠 {CURRENT_ENGINE.upper()} is thinking...")

    # 2. Execute via Selected Engine CLI
    full_prompt = f"{user_text}{context_str}{system_instruction}"
    debug_logger.debug(f"FULL INJECTED PROMPT ({CURRENT_ENGINE}):\n{full_prompt}")

    if CURRENT_ENGINE == "gemini":
        cmd = ["gemini", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    else: # qwen
        cmd = ["qwen", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    
    console.info(f"🚀 Launching {CURRENT_ENGINE.upper()} CLI...")
    start_time = datetime.datetime.now()

    try:
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = await process.communicate()
        duration = (datetime.datetime.now() - start_time).total_seconds()
        
        debug_logger.debug(f"CLI Execution Time: {duration}s")
        debug_logger.debug(f"RAW STDOUT:\n{stdout.decode()}")
        if stderr: debug_logger.debug(f"RAW STDERR:\n{stderr.decode()}")
        
        if process.returncode == 0:
            response_text = parse_cli_response(CURRENT_ENGINE, stdout.decode())
            console.info(f"✅ {CURRENT_ENGINE.upper()} Response Received ({duration:.1f}s).")
        else:
            err_output = stderr.decode()
            response_text = f"❌ {CURRENT_ENGINE.upper()} CLI Error:\n{err_output}"
            console.error(f"❌ {CURRENT_ENGINE.upper()} CLI Failed.")
        
        log_m.write_log(CURRENT_ENGINE, user_text, response_text)
        await vec_m.add_entry(f"[{CURRENT_ENGINE.upper()}] User: {user_text}\nResponse: {response_text}")

    except Exception as e:
        response_text = f"⚠️ System Error: {str(e)}"
        console.error(f"⚠️ Exception: {str(e)}")
        debug_logger.exception("Catastrophic handling failure:")

    # 4. Final Reply
    try:
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                                          text=response_text[:4000], parse_mode='Markdown')
    except:
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                                          text=response_text[:4000])
    
    play_notification_sound()

if __name__ == '__main__':
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    update_debug_handler() # Initial setup
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_message))
    print(f"--- Pro-Tiered Bot Online (Current Engine: {CURRENT_ENGINE.upper()}) ---")
    app.run_polling()
