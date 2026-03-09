import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
import glob
import argparse
from pathlib import Path
from dotenv import load_dotenv

# SDK Imports
try:
    from google import genai
    from google.genai import types
    from PIL import Image
    USE_NEW_SDK = True
except ImportError:
    USE_NEW_SDK = False

from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, MessageHandler, filters

# --- Argument Parsing ---
parser = argparse.ArgumentParser(description="Gemini Telegram Bridge")
parser.add_argument("--name", default="probe", help="Bot identity name")
args = parser.parse_args()

BOT_NAME = args.name.lower()
BASE_DIR = Path(f"bots/{BOT_NAME}")
LOG_DIR = BASE_DIR / "logs"
MEMORY_DIR = BASE_DIR / "gemini_memory"
WORKSPACE_DIR = BASE_DIR / "workspace"

for d in [LOG_DIR, MEMORY_DIR, WORKSPACE_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# --- Configuration & Setup ---
load_dotenv()
TOKEN = os.getenv(f"{BOT_NAME.upper()}_BOT_TOKEN") or os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")

CURRENT_ENGINE = "gemini" 
client = genai.Client(api_key=GEMINI_API_KEY)

# Logging
logging.basicConfig(format='%(asctime)s - %(levelname)s - %(message)s', level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)
console = logging.getLogger("bot_activity")
debug_logger = logging.getLogger("debug_trace")
debug_logger.setLevel(logging.DEBUG)
debug_logger.propagate = False

def update_debug_handler():
    today = datetime.date.today().isoformat()
    log_file = LOG_DIR / f"{today}.log"
    for h in debug_logger.handlers[:]: debug_logger.removeHandler(h)
    fh = logging.FileHandler(log_file, encoding='utf-8')
    fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
    debug_logger.addHandler(fh)

def play_notification_sound():
    try: subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
    except: pass

def parse_cli_response(engine, raw_stdout):
    try:
        data = json.loads(raw_stdout)
        if engine == "gemini": return data.get("response", "✅ Done.")
        elif engine == "qwen":
            if isinstance(data, list):
                for item in data:
                    if item.get("type") == "result": return item.get("result", "✅ Done.")
            return "✅ Done."
    except: return raw_stdout or "✅ Done."

async def get_vision_analysis(user_query, image_path):
    try:
        img = Image.open(image_path)
        prompt = f"You are '{BOT_NAME.capitalize()}'. Analying screenshot for '老兵'. Request: {user_query}"
        response = client.models.generate_content(model='gemini-2.5-flash', contents=[prompt, img])
        return response.text
    except Exception as e: return f"⚠️ Vision Failed: {str(e)}"

# --- Managers ---
class LogManager:
    def write_log(self, engine, user_text, bot_response):
        today = datetime.date.today().isoformat()
        log_file = LOG_DIR / f"{today}.md"
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] [{engine.upper()}] User\n{user_text}\n\n")
            f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] [{engine.upper()}] Response\n{bot_response}\n\n---\n\n")

class VectorMemory:
    def __init__(self, storage_path=MEMORY_DIR / "memory.json", max_entries=500):
        self.storage_path = Path(storage_path)
        self.max_entries = max_entries
        self.memory = self._load()
    def _load(self):
        if self.storage_path.exists():
            try:
                with open(self.storage_path, "r") as f: return json.load(f)
            except: pass
        return []
    def _save(self):
        if len(self.memory) > self.max_entries: self.memory = self.memory[-self.max_entries:]
        self.storage_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.storage_path, "w") as f: json.dump(self.memory, f, indent=2)
    async def add_entry(self, text):
        try:
            result = client.models.embed_content(model="gemini-embedding-001", contents=text, config=types.EmbedContentConfig(task_type="RETRIEVAL_DOCUMENT"))
            self.memory.append({"text": text, "embedding": result.embeddings[0].values, "timestamp": datetime.datetime.now().isoformat()})
            self._save()
        except Exception as e: logging.error(f"Vector error: {e}")
    async def search(self, query, top_k=3):
        if not self.memory: return []
        try:
            result = client.models.embed_content(model="gemini-embedding-001", contents=query, config=types.EmbedContentConfig(task_type="RETRIEVAL_QUERY"))
            qe = result.embeddings[0].values
            sims = sorted([(sum(a*b for a,b in zip(qe, e['embedding'])), e['text']) for e in self.memory], reverse=True)
            return sims[:top_k]
        except: return []

class SummaryManager:
    def __init__(self, summary_path=MEMORY_DIR / "memory_summary.md"):
        self.summary_path = Path(summary_path)
    def get_latest_facts(self):
        if not self.summary_path.exists(): return ""
        try:
            with open(self.summary_path, "r") as f: return "".join(f.readlines()[-50:])
        except: return ""
    async def generate_daily_summary(self, log_dir, vector_memory):
        today = datetime.date.today().isoformat()
        log_file = Path(log_dir) / f"{today}.md"
        if not log_file.exists(): return f"No logs found."
        try:
            with open(log_file, "r") as f: logs = f.read()
            prompt = f"Summarize facts from logs for '老兵'.\n\nLOGS:\n{logs}"
            facts = client.models.generate_content(model='gemini-2.5-flash', contents=prompt).text
            with open(self.summary_path, "a") as f: f.write(f"\n### {today} Facts\n{facts}\n")
            await vector_memory.add_entry(f"Knowledge ({today}): {facts}")
            return f"✅ Facts summarized."
        except Exception as e: return f"❌ Error: {str(e)}"

# --- Initialize ---
log_m, vec_m, sum_m = LogManager(), VectorMemory(), SummaryManager()

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global CURRENT_ENGINE
    update_debug_handler()
    user_id = update.effective_user.id
    if user_id != ALLOWED_USER_ID: return
    user_text = update.message.text
    if not user_text: return

    # Commands
    if user_text.startswith("/engine"):
        parts = user_text.split()
        if len(parts) > 1:
            new_engine = parts[1].lower()
            if new_engine in ["gemini", "qwen"]:
                CURRENT_ENGINE = new_engine
                await update.message.reply_text(f"🚀 Engine: **{CURRENT_ENGINE.upper()}**", parse_mode='Markdown')
        else: await update.message.reply_text(f"🤖 Engine: **{CURRENT_ENGINE.upper()}**")
        return
    if user_text == "/summary":
        res = await sum_m.generate_daily_summary(LOG_DIR, vec_m)
        await update.message.reply_text(res); play_notification_sound(); return

    # RAG
    relevant = await vec_m.search(user_text, top_k=2)
    recent_convo = vec_m.memory[-3:] if vec_m.memory else []
    recent_str = "\n".join([f"- {m['text']}" for m in recent_convo])
    facts = sum_m.get_latest_facts()
    
    # Check for agent.md
    agent_md_path = WORKSPACE_DIR / "agent.md"
    agent_info = f"- Guidelines: Full soul in '{agent_md_path}'." if agent_md_path.exists() else ""

    system_instruction = (
        f"\n\n[System Instruction]:\n"
        f"- Name: '{BOT_NAME.capitalize()}', Assistant for '老兵'.\n"
        f"- Style: Simple, direct. Workspace: '{WORKSPACE_DIR}/'.\n"
        f"- Vision: run `screencapture {WORKSPACE_DIR}/screenshot.png` to see screen.\n"
        f"- Isolation: You only see files/logs in '{BASE_DIR}/'.\n"
        f"{agent_info}"
    )

    status_msg = await update.message.reply_text(f"🧠 {CURRENT_ENGINE.upper()}...")
    full_prompt = f"{user_text}{facts}{recent_str}{system_instruction}"
    debug_logger.debug(f"PROMPT: {full_prompt[:200]}...")

    cmd = [CURRENT_ENGINE, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    start_ts = datetime.datetime.now().timestamp()
    
    try:
        # Added 120s timeout to prevent infinite hang
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=120.0)
        except asyncio.TimeoutError:
            process.kill()
            await update.message.reply_text("⏱️ Execution timed out (120s). Try a simpler request.")
            return

        duration = datetime.datetime.now().timestamp() - start_ts
        if process.returncode == 0:
            resp_text = parse_cli_response(CURRENT_ENGINE, stdout.decode())
            console.info(f"✅ {BOT_NAME}/{CURRENT_ENGINE} ({duration:.1f}s)")
        else:
            resp_text = f"❌ Error: {stderr.decode()[:500]}"

        # Vision Pass
        shot = WORKSPACE_DIR / "screenshot.png"
        if shot.exists() and shot.stat().st_mtime > start_ts:
            await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
            resp_text = await get_vision_analysis(user_text, shot)
            await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=resp_text[:4000])
        log_m.write_log(CURRENT_ENGINE, user_text, resp_text)
        await vec_m.add_entry(f"User: {user_text}\nResponse: {resp_text}")

    except Exception as e:
        await update.message.reply_text(f"⚠️ System Error: {str(e)}")
    
    play_notification_sound()

if __name__ == '__main__':
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    update_debug_handler()
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_message))
    print(f"--- {BOT_NAME.upper()} Online ---")
    app.run_polling()
