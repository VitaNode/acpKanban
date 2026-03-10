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

# Suppress noisy library logs
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)

def play_notification_sound():
    try: subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
    except: pass

# --- Robust Multi-Format Renderer ---
def smart_format_render(text):
    """
    Optimizes text for Telegram using HTML mode for maximum reliability.
    1. Escapes HTML entities.
    2. Converts Markdown tables and code blocks to <pre> or <code>.
    3. Converts **bold** and # headers to <b>.
    """
    if not text: return "✅ Done."
    
    # 1. First, protect code blocks and tables by extracting them
    placeholders = []
    
    def save_block(match):
        content = match.group(1) if match.lastindex >= 1 else match.group(0)
        # Use <pre> for blocks to support scrolling
        placeholders.append(f"<pre>{html.escape(content.strip())}</pre>")
        return f"__PLACEHOLDER_{len(placeholders)-1}__"

    # Save Triple Backtick Blocks
    text = re.sub(r'```(?:[\w]*)\n?(.*?)```', save_block, text, flags=re.DOTALL)
    
    # Save Tables (any block of lines starting/ending with |)
    text = re.sub(r'((?:\n|^)\|.*?\|(?:\n|$)(?:\|.*?\|(?:\n|$))*)', save_block, text)

    # Save Inline Code `...`
    def save_inline(match):
        placeholders.append(f"<code>{html.escape(match.group(1))}</code>")
        return f"__PLACEHOLDER_{len(placeholders)-1}__"
    text = re.sub(r'`(.*?)`', save_inline, text)

    # 2. Escape the rest of the text for HTML
    text = html.escape(text)

    # 3. Apply formatting to the escaped text
    # Headers # -> Bold
    text = re.sub(r'^#+\s+(.*)$', r'<b>\1</b>', text, flags=re.MULTILINE)
    # Bold ** -> <b>
    text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
    # Italic _ -> <i> (Simplified, can be tricky with underscores)
    text = re.sub(r'\b_(.*?)_\b', r'<i>\1</i>', text)

    # 4. Restore the protected blocks
    for i, ph in enumerate(placeholders):
        text = text.replace(html.escape(f"__PLACEHOLDER_{i}__"), ph)

    return text

def safe_truncate_html(text, limit=4000):
    """Truncates HTML safely by ensuring tags are closed."""
    if len(text) <= limit: return text
    
    truncated = text[:limit-50] + "..."
    # A very basic tag balancer for common tags
    for tag in ['pre', 'code', 'b', 'i']:
        open_count = truncated.count(f'<{tag}>')
        close_count = truncated.count(f'</{tag}>')
        if open_count > close_count:
            truncated += f'</{tag}>'
    
    truncated += "\n\n<i>(Content truncated due to length)</i>"
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
        for d in ["logs", "gemini_memory", "workspace"]: (self.base_dir / d).mkdir(parents=True, exist_ok=True)
        
        self.memory_file = self.base_dir / "gemini_memory/memory.json"
        self.summary_file = self.base_dir / "gemini_memory/memory_summary.md"
        self.memory_data = self._load_memory_file()
        
        self.debug_logger = logging.getLogger(f"debug_{self.name}")
        self.debug_logger.setLevel(logging.DEBUG)
        self.debug_logger.propagate = False
        
        self.console = logging.getLogger(f"console_{self.name}")
        self.console.setLevel(logging.INFO)
        if not self.console.handlers:
            sh = logging.StreamHandler()
            sh.setFormatter(logging.Formatter(f'%(asctime)s - {self.name.upper()} - %(message)s'))
            self.console.addHandler(sh)

    def _load_memory_file(self):
        if self.memory_file.exists():
            try:
                with open(self.memory_file, "r") as f: return json.load(f)
            except: pass
        return []

    def _save_memory_file(self):
        if len(self.memory_data) > 300: self.memory_data = self.memory_data[-300:]
        with open(self.memory_file, "w") as f: json.dump(self.memory_data, f, indent=2)

    def update_daily_log_handler(self):
        today = datetime.date.today().isoformat()
        log_path = self.base_dir / f"logs/{today}.log"
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
            self.debug_logger.exception("Vision analysis failed:")
            return f"⚠️ Vision Error: {str(e)}"

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if not update.effective_user or update.effective_user.id != ALLOWED_USER_ID: return
        self.update_daily_log_handler()
        user_text = update.message.text
        if not user_text: return
        
        self.console.info(f"📥 Received: {user_text[:50]}...")

        try:
            # Command Handling
            if user_text.startswith("/engine"):
                parts = user_text.split()
                if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                    self.engine = parts[1].lower()
                    await update.message.reply_text(f"🚀 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                else: await update.message.reply_text(f"🤖 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                return

            if user_text == "/summary":
                log_md = self.base_dir / f"logs/{datetime.date.today().isoformat()}.md"
                if not log_md.exists():
                    await update.message.reply_text("No logs today."); return
                facts = client.models.generate_content(model='gemini-2.5-flash', contents=f"Extract facts for '老兵':\n\n{log_md.read_text()}").text
                with open(self.summary_file, "a") as f: f.write(f"\n### {datetime.date.today().isoformat()} Facts\n{facts}\n")
                await update.message.reply_text(f"✅ Summary saved."); play_notification_sound(); return

            # Context
            recent_convo = "\n".join([f"- {m['text']}" for m in self.memory_data[-3:]])
            facts_str = ""
            if self.summary_file.exists():
                with open(self.summary_file, "r") as f: facts_str = "".join(f.readlines()[-50:])

            full_prompt = (
                f"### USER REQUEST\n{user_text}\n\n"
                f"### FACTS\n{facts_str or 'None.'}\n\n"
                f"### RECENT HISTORY\n{recent_convo or 'None.'}\n\n"
                f"### SYSTEM\n- Name: '{self.name.capitalize()}'. Assistant for '老兵'.\n"
                f"- Workspace: '{self.base_dir}/workspace/'.\n"
                f"- Vision: run `screencapture {self.base_dir}/workspace/screenshot.png`."
            )

            status_msg = None
            try:
                status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} thinking...", read_timeout=10, connect_timeout=10)
            except Exception as e:
                self.console.warning(f"Status msg fail: {e}")

            cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
            start_ts = datetime.datetime.now().timestamp()
            
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120.0)
            except asyncio.TimeoutError:
                proc.kill()
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Timeout.")
                return

            duration = datetime.datetime.now().timestamp() - start_ts
            raw_output = stdout.decode()
            self.debug_logger.debug(f"RAW: {raw_output}")
            response_text = parse_cli_response(self.engine, raw_output)

            # Vision Check
            shot = self.base_dir / "workspace/screenshot.png"
            if shot.exists() and shot.stat().st_mtime > start_ts:
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

            # Final Render (Switching to HTML for robustness)
            final_html = smart_format_render(response_text)
            final_html = safe_truncate_html(final_html)
            
            if status_msg:
                try:
                    await context.bot.edit_message_text(
                        chat_id=update.effective_chat.id, 
                        message_id=status_msg.message_id, 
                        text=final_html, 
                        parse_mode=ParseMode.HTML
                    )
                except Exception as e:
                    self.console.warning(f"HTML Render fail: {e}")
                    # Ultimate fallback: No formatting, just raw response text truncated
                    await context.bot.edit_message_text(
                        chat_id=update.effective_chat.id, 
                        message_id=status_msg.message_id, 
                        text=response_text[:4000]
                    )
            else:
                await update.message.reply_text(text=response_text[:4000])

            self.console.info(f"✅ {self.engine.upper()} ({duration:.1f}s)")

            if proc.returncode == 0:
                with open(self.base_dir / f"logs/{datetime.date.today().isoformat()}.md", "a") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] User: {user_text}\nResponse: {response_text}\n\n")
                self.memory_data.append({"text": f"User: {user_text}\nBot: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory_file()

        except (TimedOut, NetworkError): pass
        except Exception as e:
            self.console.error(f"⚠️ Error: {e}")
            self.debug_logger.exception("Fail:")
        
        play_notification_sound()

# --- Multi-Bot Async Runner ---
async def error_handler(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    logging.error("Exception while handling update:", exc_info=context.error)

async def main():
    bot_configs = {k.replace("_BOT_TOKEN", "").lower(): v for k, v in os.environ.items() if k.endswith("_BOT_TOKEN")}
    if not bot_configs: return

    print(f"--- Starting Bridge (Total Bots: {len(bot_configs)}) ---")
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
