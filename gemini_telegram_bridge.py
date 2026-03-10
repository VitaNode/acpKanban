import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
import re
import argparse
import signal
import html
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
from telegram.constants import ParseMode
from telegram.error import TimedOut, NetworkError, TelegramError

# --- Global Config ---
load_dotenv()
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
client = genai.Client(api_key=GEMINI_API_KEY)

logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)

def play_notification_sound():
    try: subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
    except: pass

# --- Improved Robust Multi-Format Renderer ---
def smart_format_render(text):
    if not text: return "✅ Done."
    
    placeholders = []
    
    def save_block(match):
        content = match.group(1) if match.lastindex and match.lastindex >= 1 else match.group(0)
        # Use <pre> for scrolling support
        placeholders.append(f"<pre>{html.escape(content.strip())}</pre>")
        return f"XYZPH{len(placeholders)-1}XYZ" # Unique tag without underscores to avoid regex collision

    # 1. Protect code blocks and tables first
    # Triple backticks
    text = re.sub(r'```(?:[\w]*)\n?(.*?)```', save_block, text, flags=re.DOTALL)
    # Tables (lines starting/ending with |)
    text = re.sub(r'((?:\n|^)\|.*?\|(?:\n|$)(?:\|.*?\|(?:\n|$))*)', save_block, text)
    
    # Inline code
    def save_inline(match):
        placeholders.append(f"<code>{html.escape(match.group(1))}</code>")
        return f"XYZPH{len(placeholders)-1}XYZ"
    text = re.sub(r'`(.*?)`', save_inline, text)

    # 2. Escape all other HTML special characters
    text = html.escape(text)

    # 3. Apply formatting to the escaped text
    # Bold **text**
    text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
    # Headers # -> Bold
    text = re.sub(r'^#+\s+(.*)$', r'<b>\1</b>', text, flags=re.MULTILINE)
    # Italic _text_ (Only if bounded by word boundaries and not part of our placeholder)
    text = re.sub(r'(?<!\w)_(.*?)_(?!\w)', r'<i>\1</i>', text)

    # 4. Restore the protected blocks
    for i, ph in enumerate(placeholders):
        text = text.replace(f"XYZPH{i}XYZ", ph)

    return text

def safe_truncate_html(text, limit=4000):
    if len(text) <= limit: return text
    truncated = text[:limit-100] + "..."
    for tag in ['pre', 'code', 'b', 'i']:
        if truncated.count(f'<{tag}>') > truncated.count(f'</{tag}>'):
            truncated += f'</{tag}>'
    truncated += "\n\n<i>(Truncated)</i>"
    return truncated

def parse_cli_response(engine, raw_stdout):
    try:
        match = re.search(r'(\{.*\}|\[.*\])', raw_stdout, re.DOTALL)
        data = json.loads(match.group(1)) if match else json.loads(raw_stdout)
        if engine == "gemini": return data.get("response", "✅ Done.")
        if engine == "qwen" and isinstance(data, list):
            for item in data:
                if item.get("type") == "result": return item.get("result", "✅ Done.")
    except: pass
    return re.sub(r'Loaded cached credentials\..*?YOLO mode is enabled.*?\n', '', raw_stdout, flags=re.DOTALL).strip() or "✅ Done."

# --- Bot Instance Class ---
class GeminiBotInstance:
    def __init__(self, name, token):
        self.name = name.lower()
        self.token = token
        self.engine = "gemini"
        
        self.base_dir = Path(f"bots/{self.name}")
        self.log_dir = self.base_dir / "logs"
        self.memory_dir = self.base_dir / "gemini_memory"
        self.workspace_dir = self.base_dir / "workspace"
        for d in [self.log_dir, self.memory_dir, self.workspace_dir]: d.mkdir(parents=True, exist_ok=True)
        
        self.memory_file = self.memory_dir / "memory.json"
        self.summary_file = self.memory_dir / "memory_summary.md"
        self.memory_data = self._load_memory()
        
        self.debug_logger = logging.getLogger(f"debug_{self.name}")
        self.debug_logger.setLevel(logging.DEBUG)
        self.debug_logger.propagate = False
        
        self.console = logging.getLogger(f"console_{self.name}")
        self.console.setLevel(logging.INFO)
        if not self.console.handlers:
            sh = logging.StreamHandler()
            sh.setFormatter(logging.Formatter(f'%(asctime)s - {self.name.upper()} - %(message)s'))
            self.console.addHandler(sh)

    def _load_memory(self):
        if self.memory_file.exists():
            try:
                with open(self.memory_file, "r") as f: return json.load(f)
            except: pass
        return []

    def _save_memory(self):
        if len(self.memory_data) > 300: self.memory_data = self.memory_data[-300:]
        with open(self.memory_file, "w") as f: json.dump(self.memory_data, f, indent=2)

    def update_daily_log_handler(self):
        today = datetime.date.today().isoformat()
        log_path = self.log_dir / f"{today}.log"
        for h in self.debug_logger.handlers[:]: self.debug_logger.removeHandler(h)
        fh = logging.FileHandler(log_path, encoding='utf-8')
        fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
        self.debug_logger.addHandler(fh)

    async def get_vision_analysis(self, query, img_path):
        try:
            img = Image.open(img_path)
            prompt = f"You are '{self.name.capitalize()}'. AI for '老兵'. Analysis for: {query}. Respond in Markdown."
            res = client.models.generate_content(model='gemini-2.5-flash', contents=[prompt, img])
            return res.text
        except Exception as e:
            self.debug_logger.exception("Vision fail:")
            return f"⚠️ Vision Error: {str(e)}"

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if not update.effective_user or update.effective_user.id != ALLOWED_USER_ID: return
        self.update_daily_log_handler()
        user_text = update.message.text
        if not user_text: return
        
        self.console.info(f"📥 Received: {user_text[:50]}...")

        try:
            # 1. Command Handling
            if user_text.startswith("/engine"):
                parts = user_text.split()
                if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                    self.engine = parts[1].lower()
                    await update.message.reply_text(f"🚀 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                else: await update.message.reply_text(f"🤖 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                return

            if user_text == "/summary":
                log_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                if not log_md.exists():
                    await update.message.reply_text("No logs yet."); return
                facts = client.models.generate_content(model='gemini-2.5-flash', contents=f"Extract facts for '老兵':\n\n{log_md.read_text()}").text
                with open(self.summary_file, "a") as f: f.write(f"\n### {datetime.date.today().isoformat()} Facts\n{facts}\n")
                await update.message.reply_text(f"✅ Summary saved."); play_notification_sound(); return

            # 2. Context Construction
            recent_convo = "\n".join([f"- {m['text']}" for m in self.memory_data[-3:]])
            facts_str = ""
            if self.summary_file.exists():
                with open(self.summary_file, "r") as f: facts_str = "".join(f.readlines()[-50:])

            full_prompt = (
                f"### USER REQUEST\n{user_text}\n\n"
                f"### FACTS\n{facts_str or 'None.'}\n\n"
                f"### RECENT HISTORY\n{recent_convo or 'None.'}\n\n"
                f"### SYSTEM\n- Name: '{self.name.capitalize()}'. Assistant for '老兵'.\n"
                f"- Workspace: '{self.workspace_dir}/'.\n"
                f"- Vision: run `screencapture {self.workspace_dir}/screenshot.png`."
            )

            status_msg = None
            try: status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} thinking...")
            except: pass

            # 3. CLI Execution
            cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
            start_ts = datetime.datetime.now().timestamp()
            
            # 🚀 Logging-First: ensure we have the prompt even if it hangs
            self.debug_logger.debug(f"FULL PROMPT SENT:\n{full_prompt}")
            self.console.info(f"🚀 Launching {self.engine.upper()} CLI...")

            proc = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120.0)
            except asyncio.TimeoutError:
                proc.kill()
                # 🛑 Improved Error Logging
                self.console.error(f"❌ {self.engine.upper()} TIMEOUT after 120s")
                self.debug_logger.error(f"Execution TIMEOUT after 120s for prompt: {user_text[:50]}...")
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Timeout.")
                return

            duration = datetime.datetime.now().timestamp() - start_ts
            raw_stdout = stdout.decode()
            raw_stderr = stderr.decode()
            
            self.debug_logger.debug(f"CLI Duration: {duration:.1f}s")
            self.debug_logger.debug(f"RAW STDOUT:\n{raw_stdout}")
            if raw_stderr: self.debug_logger.debug(f"RAW STDERR:\n{raw_stderr}")
            
            response_text = parse_cli_response(self.engine, raw_stdout)

            # 4. Vision Check
            shot = self.workspace_dir / "screenshot.png"
            if shot.exists() and shot.stat().st_mtime > start_ts:
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

            # 5. IMMEDIATELY SAVE LOGS AND MEMORY (Before rendering/sending)
            if proc.returncode == 0:
                today_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                with open(today_md, "a", encoding="utf-8") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] User: {user_text}\nResponse: {response_text}\n\n")
                self.memory_data.append({"text": f"User: {user_text}\nBot: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory()
                self.console.info(f"✅ {self.engine.upper()} ({duration:.1f}s) - Logged.")

            # 6. Render and Send to Telegram
            final_html = safe_truncate_html(smart_format_render(response_text))
            
            if status_msg:
                try:
                    await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=final_html, parse_mode=ParseMode.HTML)
                except Exception as e:
                    self.console.warning(f"HTML fail: {e}")
                    await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=response_text[:4000])
            else:
                await update.message.reply_text(text=response_text[:4000])

        except (TimedOut, NetworkError): pass
        except Exception as e:
            self.console.error(f"⚠️ Error: {e}")
            self.debug_logger.exception("Catastrophic:")
        
        play_notification_sound()

# --- Multi-Bot Async Runner ---
async def error_handler(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    logging.error("Exception:", exc_info=context.error)

async def main():
    bot_configs = {k.replace("_BOT_TOKEN", "").lower(): v for k, v in os.environ.items() if k.endswith("_BOT_TOKEN")}
    if not bot_configs: return
    print(f"--- Starting Bridge (Bots: {len(bot_configs)}) ---")
    apps = []
    for name, token in bot_configs.items():
        instance = GeminiBotInstance(name, token)
        app = ApplicationBuilder().token(token).connect_timeout(20).read_timeout(20).build()
        app.add_handler(MessageHandler(filters.TEXT, instance.handle_message))
        app.add_error_handler(error_handler)
        await app.initialize(); await app.start(); await app.updater.start_polling()
        apps.append(app); print(f"🚀 {name.upper()} Ready")
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM): loop.add_signal_handler(sig, lambda: stop_event.set())
    await stop_event.wait()
    for app in apps: await app.updater.stop(); await app.stop(); await app.shutdown()

if __name__ == '__main__':
    asyncio.run(main())
