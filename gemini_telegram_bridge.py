import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
import re
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

def smart_format_markdown(text):
    """
    Optimizes text for Telegram:
    1. Detects Markdown tables and wraps them in code blocks for alignment.
    2. Escapes risky characters or ensures proper Markdown structure.
    """
    if not text: return "✅ Done."
    
    # Simple Table Detection: lines starting and ending with | or containing multiple |
    lines = text.split('\n')
    formatted_lines = []
    in_table = False
    
    for line in lines:
        # Heuristic: line looks like part of a table if it has | and follows or starts a header/divider
        is_table_row = line.strip().startswith('|') and line.strip().count('|') >= 2
        
        if is_table_row and not in_table:
            formatted_lines.append("```") # Start code block for table
            in_table = True
            formatted_lines.append(line)
        elif not is_table_row and in_table:
            formatted_lines.append("```") # End code block
            in_table = False
            formatted_lines.append(line)
        else:
            formatted_lines.append(line)
            
    if in_table:
        formatted_lines.append("```")
        
    final_text = '\n'.join(formatted_lines)
    
    # Telegram Legacy Markdown is more forgiving but still picky
    # We ensure code blocks don't nest and bolding is closed
    return final_text

def extract_json_response(raw_output):
    try:
        match = re.search(r'(\{.*\}|\[.*\])', raw_output, re.DOTALL)
        if match: return json.loads(match.group(1))
        return json.loads(raw_output)
    except: return None

def parse_cli_response(engine, raw_stdout):
    data = extract_json_response(raw_stdout)
    if data:
        if engine == "gemini": return data.get("response", "✅ Done.")
        elif engine == "qwen":
            if isinstance(data, list):
                for item in data:
                    if item.get("type") == "result": return item.get("result", "✅ Done.")
    clean_text = re.sub(r'Loaded cached credentials\..*?YOLO mode is enabled.*?\n', '', raw_stdout, flags=re.DOTALL).strip()
    return clean_text or "✅ Done."

async def get_vision_analysis(user_query, image_path):
    try:
        img = Image.open(image_path)
        prompt = f"You are '{BOT_NAME.capitalize()}'. Analyze screenshot for '老兵'. Request: {user_query}. Respond in Markdown."
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
            f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] [{engine.upper()}] Final Response\n{bot_response}\n\n---\n\n")

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
        if "❌ Error" in text or "Timed out" in text: return
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
            prompt = f"Summarize key facts from logs for '老兵'.\n\nLOGS:\n{logs}"
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

    # Context
    relevant = await vec_m.search(user_text, top_k=2)
    recent_convo = vec_m.memory[-3:] if vec_m.memory else []
    recent_str = "\n".join([f"- {m['text']}" for m in recent_convo])
    facts = sum_m.get_latest_facts()
    agent_md_path = WORKSPACE_DIR / "agent.md"
    
    full_prompt = (
        f"### USER REQUEST\n{user_text}\n\n"
        f"### LONG-TERM FACTS\n{facts or 'No facts yet.'}\n\n"
        f"### RECENT CONVERSATION HISTORY\n{recent_str or 'No history yet.'}\n\n"
        f"### SYSTEM INSTRUCTIONS\n"
        f"- Name is '{BOT_NAME.capitalize()}', assistant for '老兵'.\n"
        f"- Sandbox: Work in '{WORKSPACE_DIR}/'.\n"
        f"- Vision: run `screencapture {WORKSPACE_DIR}/screenshot.png` to see screen.\n"
        f"- Format: Use Markdown for tables and code blocks."
    )

    status_msg = await update.message.reply_text(f"🧠 {CURRENT_ENGINE.upper()}...")
    
    cmd = [CURRENT_ENGINE, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    start_ts = datetime.datetime.now().timestamp()
    
    try:
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=120.0)
        except asyncio.TimeoutError:
            process.kill()
            await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Timeout.")
            return

        raw_stdout = stdout.decode()
        resp_text = parse_cli_response(CURRENT_ENGINE, raw_stdout)

        # Vision Pass
        shot = WORKSPACE_DIR / "screenshot.png"
        if shot.exists() and shot.stat().st_mtime > start_ts:
            await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
            resp_text = await get_vision_analysis(user_text, shot)
            await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

        # Final Formatting and Delivery
        formatted_text = smart_format_markdown(resp_text)
        try:
            await context.bot.edit_message_text(
                chat_id=update.effective_chat.id, 
                message_id=status_msg.message_id, 
                text=formatted_text[:4000],
                parse_mode='Markdown'
            )
        except Exception as e:
            # Fallback to plain text if Markdown parsing fails
            await context.bot.edit_message_text(
                chat_id=update.effective_chat.id, 
                message_id=status_msg.message_id, 
                text=resp_text[:4000]
            )
        
        if process.returncode == 0:
            log_m.write_log(CURRENT_ENGINE, user_text, resp_text)
            await vec_m.add_entry(f"User: {user_text}\nResponse: {resp_text}")

    except Exception as e:
        await update.message.reply_text(f"⚠️ Error: {str(e)}")
    
    play_notification_sound()

if __name__ == '__main__':
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    update_debug_handler()
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_message))
    print(f"--- {BOT_NAME.upper()} Ready ---")
    app.run_polling()
