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

# Logging configuration
logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)

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
            # Gemini CLI usually returns a single object with a "response" field
            return data.get("response", "✅ Done.")
        elif engine == "qwen":
            # Qwen Code returns a list of objects, we look for type == "result"
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
            logging.info(f"Memory sharded: Kept latest {self.max_entries} entries.")
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
            return f"No logs found for today ({today}). Logs directory: {log_dir}"
        
        try:
            with open(log_file, "r", encoding="utf-8") as f:
                logs = f.read()
            
            prompt = f"Extract permanent facts, user preferences, and system states from these logs. Be concise. Format as bullet points.\n\nLOGS:\n{logs}"
            
            if USE_NEW_SDK:
                response = client.models.generate_content(
                    model='gemini-2.5-flash',
                    contents=prompt
                )
                facts = response.text
            else:
                response = await asyncio.to_thread(summary_model_legacy.generate_content, prompt)
                facts = response.text
            
            with open(self.summary_path, "a", encoding="utf-8") as f:
                f.write(f"\n### {today} Permanent Facts\n{facts}\n")
            
            await vector_memory.add_entry(f"System Knowledge Summary ({today}): {facts}")
            return f"✅ Facts for {today} summarized and stored."
        except Exception as e:
            return f"❌ Summary Error: {str(e)}"

# --- Initialize ---
log_m = LogManager()
vec_m = VectorMemory(max_entries=300)
sum_m = SummaryManager()

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global CURRENT_ENGINE
    user_id = update.effective_user.id
    console.info(f"📥 Received message from {user_id}: {update.message.text}")
    
    if user_id != ALLOWED_USER_ID:
        console.warning(f"Unauthorized User ID: {user_id}. Expected: {ALLOWED_USER_ID}")
        return

    user_text = update.message.text
    if not user_text: return

    # --- Manual Command Handling ---
    
    # 1. /engine command
    if user_text.startswith("/engine"):
        parts = user_text.split()
        if len(parts) > 1:
            new_engine = parts[1].lower()
            if new_engine in ["gemini", "qwen"]:
                CURRENT_ENGINE = new_engine
                await update.message.reply_text(f"🚀 Engine switched to: **{CURRENT_ENGINE.upper()}**", parse_mode='Markdown')
            else:
                await update.message.reply_text("⚠️ Unknown engine. Use 'gemini' or 'qwen'.")
        else:
            await update.message.reply_text(f"🤖 Current Engine: **{CURRENT_ENGINE.upper()}**\nUse `/engine [gemini|qwen]` to switch.", parse_mode='Markdown')
        return

    # 2. /summary command
    if user_text == "/summary":
        console.info("Executing /summary command...")
        res = await sum_m.generate_daily_summary("logs", vec_m)
        await update.message.reply_text(res)
        play_notification_sound()
        return

    # 3. /search command
    if user_text.startswith("/search "):
        console.info("Executing /search command...")
        query = user_text.replace("/search ", "").strip()
        results = await vec_m.search(query)
        resp = "🔍 Search results:\n\n" + "\n\n".join([f"• {t}" for s, t in results])
        await update.message.reply_text(resp if results else "No memories found.")
        return

    # --- Normal Dialogue Handling with RAG ---

    # 1. Hybrid Context Retrieval
    relevant = await vec_m.search(user_text, top_k=2)
    recent_convo = vec_m.memory[-3:] if vec_m.memory else []
    recent_str = "\n".join([f"- {m['text']}" for m in recent_convo])
    permanent_facts = sum_m.get_latest_facts()
    
    system_instruction = "\n\n[System Instruction]: Your primary working directory for file operations, tool installations, and project tasks is the './workspace/' folder. Please perform all work inside it to avoid conflicts with the bot's core logic."

    context_str = ""
    if permanent_facts:
        context_str += f"\n\n[Permanent Facts/Knowledge]:\n{permanent_facts}"
    if recent_str:
        context_str += f"\n\n[Recent Conversation History]:\n{recent_str}"
    if relevant:
        semantic_str = "\n".join([f"- {t}" for _, t in relevant if t not in recent_str])
        if semantic_str:
            context_str += f"\n\n[Related Past Context]:\n{semantic_str}"

    status_msg = await update.message.reply_text(f"🧠 {CURRENT_ENGINE.upper()} is thinking...")

    # 2. Execute via Selected Engine CLI
    full_prompt = f"{user_text}{context_str}{system_instruction}"
    
    # Commands are very similar for both
    if CURRENT_ENGINE == "gemini":
        cmd = ["gemini", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    else: # qwen
        cmd = ["qwen", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    
    console.info(f"🚀 Launching {CURRENT_ENGINE.upper()} CLI...")
    
    try:
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = await process.communicate()
        
        if process.returncode == 0:
            response_text = parse_cli_response(CURRENT_ENGINE, stdout.decode())
            console.info(f"✅ {CURRENT_ENGINE.upper()} Response Received.")
        else:
            err_output = stderr.decode()
            response_text = f"❌ {CURRENT_ENGINE.upper()} CLI Error:\n{err_output}"
            console.error(f"❌ {CURRENT_ENGINE.upper()} CLI Failed.")
        
        # 3. Layered Saving (Shared Memory!)
        log_m.write_log(CURRENT_ENGINE, user_text, response_text)
        await vec_m.add_entry(f"[{CURRENT_ENGINE.upper()}] User: {user_text}\nResponse: {response_text}")

    except Exception as e:
        response_text = f"⚠️ System Error: {str(e)}"
        console.error(f"⚠️ Exception: {str(e)}")

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
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_message))
    
    print(f"--- Pro-Tiered Bot Online (Current Engine: {CURRENT_ENGINE.upper()}) ---")
    app.run_polling()
