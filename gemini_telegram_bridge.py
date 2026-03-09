import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
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

# --- Configuration & Setup ---
load_dotenv()
TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY")

CURRENT_ENGINE = "gemini" # Default engine
WORKSPACE_DIR = Path("./workspace")
WORKSPACE_DIR.mkdir(exist_ok=True)

# Initialize Clients
client = genai.Client(api_key=GEMINI_API_KEY)

# --- Enhanced Logging Setup ---
Path("logs").mkdir(exist_ok=True)
logging.basicConfig(format='%(asctime)s - %(levelname)s - %(message)s', level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)

debug_logger = logging.getLogger("debug_trace")
debug_logger.setLevel(logging.DEBUG)
debug_logger.propagate = False

def update_debug_handler():
    today = datetime.date.today().isoformat()
    log_file = f"logs/{today}.log"
    for h in debug_logger.handlers[:]: debug_logger.removeHandler(h)
    fh = logging.FileHandler(log_file, encoding='utf-8')
    fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
    debug_logger.addHandler(fh)

console = logging.getLogger("bot_activity")

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
            return "✅ Done (Result not found in JSON)."
    except: return raw_stdout or "✅ Done."

async def get_vision_analysis(prompt, image_path):
    """Sends an image to Gemini for real visual analysis."""
    try:
        img = Image.open(image_path)
        # Using 2.5-flash which is excellent at vision
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=[prompt, img]
        )
        return response.text
    except Exception as e:
        return f"⚠️ Vision Analysis Failed: {str(e)}"

# --- Tier 1 & 2 & 3 Managers ---
class LogManager:
    def write_log(self, engine, user_text, bot_response):
        today = datetime.date.today().isoformat()
        log_file = Path("logs") / f"{today}.md"
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] [{engine.upper()}] User\n{user_text}\n\n")
            f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] [{engine.upper()}] Response\n{bot_response}\n\n---\n\n")

class VectorMemory:
    def __init__(self, storage_path="gemini_memory/memory.json", max_entries=500):
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
    def _cosine_similarity(self, v1, v2):
        dot = sum(a * b for a, b in zip(v1, v2))
        m1, m2 = math.sqrt(sum(a*a for a in v1)), math.sqrt(sum(b*b for b in v2))
        return dot / (m1 * m2) if m1 > 0 and m2 > 0 else 0
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
            sims = sorted([(self._cosine_similarity(qe, e['embedding']), e['text']) for e in self.memory], reverse=True)
            return sims[:top_k]
        except: return []

class SummaryManager:
    def __init__(self, summary_path="gemini_memory/memory_summary.md"):
        self.summary_path = Path(summary_path)
    def get_latest_facts(self):
        if not self.summary_path.exists(): return ""
        try:
            with open(self.summary_path, "r") as f: lines = f.readlines()
            return "".join(lines[-100:])
        except: return ""
    async def generate_daily_summary(self, log_dir, vector_memory):
        today = datetime.date.today().isoformat()
        log_file = Path(log_dir) / f"{today}.md"
        if not log_file.exists(): return f"No logs found for today."
        update_debug_handler()
        try:
            with open(log_file, "r") as f: logs = f.read()
            prompt = f"Extract permanent facts, user preferences, and system states from these logs. Be concise. Bullet points.\n\nLOGS:\n{logs}"
            facts = client.models.generate_content(model='gemini-2.5-flash', contents=prompt).text
            with open(self.summary_path, "a") as f: f.write(f"\n### {today} Permanent Facts\n{facts}\n")
            await vector_memory.add_entry(f"Knowledge Summary ({today}): {facts}")
            return f"✅ Facts for {today} summarized and stored."
        except Exception as e: return f"❌ Summary Error: {str(e)}"

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
            else: await update.message.reply_text("⚠️ Unknown engine.")
        else: await update.message.reply_text(f"🤖 Current Engine: **{CURRENT_ENGINE.upper()}**")
        return
    if user_text == "/summary":
        res = await sum_m.generate_daily_summary("logs", vec_m)
        await update.message.reply_text(res); play_notification_sound(); return

    # RAG Context
    relevant = await vec_m.search(user_text, top_k=2)
    recent_convo = vec_m.memory[-3:] if vec_m.memory else []
    recent_str = "\n".join([f"- {m['text']}" for m in recent_convo])
    permanent_facts = sum_m.get_latest_facts()
    
    system_instruction = (
        "\n\n[System Instruction]:\n"
        "- Name: '探机'. Assistant for '老兵'.\n"
        "- Style: Simple, direct. Workspace: './workspace/'.\n"
        "- Vision: If asked to see the screen, run `screencapture ./workspace/screenshot.png`. Confirmation is enough; vision model will handle analysis later.\n"
        "- Operational Soul: More rules in './workspace/agent.md'."
    )

    context_str = ""
    if permanent_facts: context_str += f"\n\n[Permanent Facts]:\n{permanent_facts}"
    if recent_str: context_str += f"\n\n[Recent History]:\n{recent_str}"
    if relevant:
        semantic_str = "\n".join([f"- {t}" for _, t in relevant if t not in recent_str])
        if semantic_str: context_str += f"\n\n[Related Context]:\n{semantic_str}"

    status_msg = await update.message.reply_text(f"🧠 {CURRENT_ENGINE.upper()} is thinking...")
    full_prompt = f"{user_text}{context_str}{system_instruction}"
    debug_logger.debug(f"FULL PROMPT:\n{full_prompt}")

    # Step 1: Tool Execution
    cmd = [CURRENT_ENGINE, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    start_time_float = datetime.datetime.now().timestamp()
    
    try:
        process = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = await process.communicate()
        duration = datetime.datetime.now().timestamp() - start_time_float
        
        debug_logger.debug(f"STDOUT: {stdout.decode()}")
        
        if process.returncode == 0:
            response_text = parse_cli_response(CURRENT_ENGINE, stdout.decode())
            console.info(f"✅ {CURRENT_ENGINE.upper()} Response ({duration:.1f}s).")
        else:
            response_text = f"❌ {CURRENT_ENGINE.upper()} Error:\n{stderr.decode()}"
            console.error(f"❌ Failed.")

        # Step 2: Check for Vision Trigger (Screenshot)
        screenshot_path = WORKSPACE_DIR / "screenshot.png"
        if screenshot_path.exists() and screenshot_path.stat().st_mtime > start_time_float:
            await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Screen captured. Analyzing...")
            vision_analysis = await get_vision_analysis(f"User asked: {user_text}. Based on this screen, provide the answer.", screenshot_path)
            response_text = vision_analysis
            await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(screenshot_path, 'rb'))

        await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=response_text[:4000])
        
        log_m.write_log(CURRENT_ENGINE, user_text, response_text)
        await vec_m.add_entry(f"User: {user_text}\nResponse: {response_text}")

    except Exception as e:
        await update.message.reply_text(f"⚠️ Error: {str(e)}")
        debug_logger.exception("Failure:")
    
    play_notification_sound()

if __name__ == '__main__':
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    update_debug_handler()
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_message))
    print(f"--- Pro-Tiered Bot Online (Vision & Multimedia Enabled) ---")
    app.run_polling()
