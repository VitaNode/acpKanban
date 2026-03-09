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

# --- Tier 1: Log Manager ---
class LogManager:
    def __init__(self, log_dir="logs"):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)

    def write_log(self, user_text, bot_response):
        today = datetime.date.today().isoformat()
        log_file = self.log_dir / f"{today}.md"
        timestamp = datetime.datetime.now().strftime("%H:%M:%S")
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"### [{timestamp}] User\n{user_text}\n\n")
            f.write(f"### [{timestamp}] Gemini\n{bot_response}\n\n---\n\n")

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
                    model="text-embedding-004", # text-embedding-004 is recommended for new SDK
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
                    model="text-embedding-004",
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
    # Debug logging for authorization
    user_id = update.effective_user.id
    console.info(f"📥 Received message from {user_id}: {update.message.text}")
    
    if user_id != ALLOWED_USER_ID:
        console.warning(f"Unauthorized User ID: {user_id}. Expected: {ALLOWED_USER_ID}")
        return

    user_text = update.message.text
    if not user_text: return

    # MANUAL COMMAND HANDLING (because we removed filters.COMMAND)
    if user_text == "/summary":
        console.info("Executing /summary command...")
        res = await sum_m.generate_daily_summary("logs", vec_m)
        await update.message.reply_text(res)
        play_notification_sound()
        return

    if user_text.startswith("/search "):
        console.info("Executing /search command...")
        query = user_text.replace("/search ", "").strip()
        results = await vec_m.search(query)
        resp = "🔍 Search results:\n\n" + "\n\n".join([f"• {t}" for s, t in results])
        await update.message.reply_text(resp if results else "No memories found.")
        return

    # 1. Hybrid Context Retrieval
    relevant = await vec_m.search(user_text, top_k=3)
    permanent_facts = sum_m.get_latest_facts()
    
    system_instruction = "\n\n[System Instruction]: Your primary working directory for file operations, tool installations, and project tasks is the './workspace/' folder. Please perform all work inside it to avoid conflicts with the bot's core logic."

    context_str = "\n\n[Permanent Facts]:\n" + permanent_facts if permanent_facts else ""
    if relevant:
        context_str += "\n\n[Related Past Interactions]:\n" + "\n".join([f"- {t}" for _, t in relevant])

    status_msg = await update.message.reply_text("🧠 Processing...")

    # 2. Execute via Gemini CLI
    full_prompt = f"{user_text}{context_str}{system_instruction}"
    cmd = ["gemini", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    
    console.info(f"🚀 Launching Gemini CLI...")
    
    try:
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = await process.communicate()
        
        if process.returncode == 0:
            result = json.loads(stdout.decode())
            response_text = result.get("response", "✅ Done.")
            console.info(f"✅ Gemini Response Received.")
        else:
            err_output = stderr.decode()
            response_text = f"❌ CLI Error:\n{err_output}"
            console.error(f"❌ Gemini CLI Failed.")
        
        log_m.write_log(user_text, response_text)
        await vec_m.add_entry(f"User: {user_text}\nGemini: {response_text}")

    except Exception as e:
        response_text = f"⚠️ System Error: {str(e)}"
        console.error(f"⚠️ Exception: {str(e)}")

    try:
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                                          text=response_text[:4000], parse_mode='Markdown')
        play_notification_sound()
    except:
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                                          text=response_text[:4000])
        play_notification_sound()

if __name__ == '__main__':
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    # REMOVED filters.COMMAND to allow handle_message to catch /summary
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_message))
    
    print("--- Pro-Tiered Gemini Bot with Hybrid Memory Online (google-genai) ---")
    app.run_polling()
