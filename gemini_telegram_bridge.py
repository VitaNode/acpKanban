import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
from pathlib import Path
from dotenv import load_dotenv

import google.generativeai as genai
from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, MessageHandler, filters

# --- Configuration & Setup ---
load_dotenv()
TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY")

# Configure Gemini
genai.configure(api_key=EMBEDDING_API_KEY)
# Using gemini-2.0-flash as it is the latest and highly capable for summarization
summary_model = genai.GenerativeModel('gemini-2.0-flash')

logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

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
        # Eviction strategy: Keep only the most recent max_entries
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
            result = genai.embed_content(model="models/gemini-embedding-001", content=text, task_type="retrieval_document")
            self.memory.append({
                "text": text,
                "embedding": result['embedding'],
                "timestamp": datetime.datetime.now().isoformat()
            })
            self._save()
        except Exception as e:
            logging.error(f"Vector error: {e}")

    async def search(self, query, top_k=3):
        if not self.memory: return []
        try:
            result = genai.embed_content(model="models/gemini-embedding-001", content=query, task_type="retrieval_query")
            qe = result['embedding']
            sims = sorted([(self._cosine_similarity(qe, e['embedding']), e['text']) for e in self.memory], reverse=True)
            return sims[:top_k]
        except Exception as e:
            logging.error(f"Search error: {e}"); return []

# --- Tier 2: Summary Manager (Integrated Facts) ---
class SummaryManager:
    def __init__(self, summary_path="gemini_memory/memory_summary.md"):
        self.summary_path = Path(summary_path)

    def get_latest_facts(self, count=10):
        if not self.summary_path.exists(): return ""
        try:
            with open(self.summary_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
            # Return last few lines of the summary file
            return "".join(lines[-count*10:]) # Heuristic to get recent facts
        except: return ""

    async def generate_daily_summary(self, log_dir, vector_memory):
        today = datetime.date.today().isoformat()
        log_file = Path(log_dir) / f"{today}.md"
        if not log_file.exists(): return "No logs found for today."
        
        try:
            with open(log_file, "r", encoding="utf-8") as f:
                logs = f.read()
            
            prompt = f"Extract permanent facts, user preferences, and system states from these logs. Be concise. Format as bullet points.\n\nLOGS:\n{logs}"
            response = await asyncio.to_thread(summary_model.generate_content, prompt)
            facts = response.text
            
            with open(self.summary_path, "a", encoding="utf-8") as f:
                f.write(f"\n### {today} Permanent Facts\n{facts}\n")
            
            # Also add summary to vector memory for semantic retrieval
            await vector_memory.add_entry(f"System Knowledge Summary ({today}): {facts}")
            return f"✅ Facts for {today} summarized and stored."
        except Exception as e:
            return f"❌ Summary Error: {str(e)}"

# --- Initialize ---
log_m = LogManager()
vec_m = VectorMemory(max_entries=300) # Only keep 300 recent vectors to save space
sum_m = SummaryManager()

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ALLOWED_USER_ID: return
    user_text = update.message.text
    if not user_text: return

    if user_text == "/summary":
        res = await sum_m.generate_daily_summary("logs", vec_m)
        await update.message.reply_text(res); return

    # 1. Hybrid Context Retrieval
    # A: Semantic Memory (Vector)
    relevant = await vec_m.search(user_text, top_k=3)
    # B: Explicit Facts (Summary File)
    permanent_facts = sum_m.get_latest_facts()
    
    context_str = "\n\n[Permanent Facts]:\n" + permanent_facts if permanent_facts else ""
    if relevant:
        context_str += "\n\n[Related Past Interactions]:\n" + "\n".join([f"- {t}" for _, t in relevant])

    status_msg = await update.message.reply_text("🧠 Processing...")

    # 2. Execute via Gemini CLI
    # We pass BOTH permanent facts and relevant semantic memories
    full_prompt = f"{user_text}{context_str}"
    cmd = ["gemini", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    
    try:
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = await process.communicate()
        
        if process.returncode == 0:
            result = json.loads(stdout.decode())
            response_text = result.get("response", "✅ Done.")
        else:
            response_text = f"❌ CLI Error:\n{stderr.decode()}"
        
        # 3. Layered Saving
        log_m.write_log(user_text, response_text)
        await vec_m.add_entry(f"User: {user_text}\nGemini: {response_text}")

    except Exception as e:
        response_text = f"⚠️ System Error: {str(e)}"

    # 4. Final Reply
    try:
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                                          text=response_text[:4000], parse_mode='Markdown')
    except:
        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                                          text=response_text[:4000])

if __name__ == '__main__':
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), handle_message))
    print("--- Pro-Tiered Gemini Bot with Hybrid Memory Online ---")
    app.run_polling()
