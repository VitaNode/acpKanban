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

# --- Shared Helper Functions ---
def smart_format_render(text):
    if not text: return "✅ Done."
    placeholders = []
    def save_block(match):
        content = match.group(1) if match.lastindex and match.lastindex >= 1 else match.group(0)
        placeholders.append(f"<pre>{html.escape(content.strip())}</pre>")
        return f"XYZPH{len(placeholders)-1}XYZ"
    text = re.sub(r'```(?:[\w]*)\n?(.*?)```', save_block, text, flags=re.DOTALL)
    text = re.sub(r'((?:\n|^)\|.*?\|(?:\n|$)(?:\|.*?\|(?:\n|$))*)', save_block, text)
    def save_inline(match):
        placeholders.append(f"<code>{html.escape(match.group(1))}</code>")
        return f"XYZPH{len(placeholders)-1}XYZ"
    text = re.sub(r'`(.*?)`', save_inline, text)
    text = html.escape(text)
    text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'^#+\s+(.*)$', r'<b>\1</b>', text, flags=re.MULTILINE)
    text = re.sub(r'(?<!\w)_(.*?)_(?!\w)', r'<i>\1</i>', text)
    for i, ph in enumerate(placeholders): text = text.replace(f"XYZPH{i}XYZ", ph)
    return text

def safe_truncate_html(text, limit=4000):
    if len(text) <= limit: return text
    truncated = text[:limit-100] + "..."
    for tag in ['pre', 'code', 'b', 'i']:
        if truncated.count(f'<{tag}>') > truncated.count(f'</{tag}>'):
            truncated += f'</{tag}>'
    truncated += "\n\n<i>(Truncated)</i>"
    return truncated

def find_usage_info(data):
    if not isinstance(data, (dict, list)): return None
    if isinstance(data, dict):
        if "usage" in data: return data["usage"]
        for key in ["stats", "metadata"]:
            if key in data:
                res = find_usage_info(data[key])
                if res: return res
        for val in data.values():
            res = find_usage_info(val)
            if res: return res
    elif isinstance(data, list):
        for item in data:
            res = find_usage_info(item)
            if res: return res
    return None

def parse_cli_response(engine, raw_stdout):
    text, usage = None, None
    try:
        match = re.search(r'(\{.*\}|\[.*\])', raw_stdout, re.DOTALL)
        data = json.loads(match.group(1)) if match else json.loads(raw_stdout)
        usage = find_usage_info(data)
        if engine == "gemini": text = data.get("response")
        elif engine == "qwen" and isinstance(data, list):
            for item in data:
                if item.get("type") == "result":
                    text = item.get("result")
                    break
        if text is None and isinstance(data, dict): text = data.get("result") or data.get("response")
    except: pass
    if text is None: text = re.sub(r'Loaded cached credentials\..*?YOLO mode is enabled.*?\n', '', raw_stdout, flags=re.DOTALL).strip()
    return text or "⚠️ Empty response from CLI.", usage

# --- Bot Instance Class ---
class GeminiBotInstance:
    def __init__(self, name, token):
        self.name = name.lower()
        self.token = token
        self.engine = "gemini"
        self.skip_session_once = False
        
        self.base_dir = Path(f"bots/{self.name}")
        for d in ["logs", "gemini_memory", "workspace"]: (self.base_dir / d).mkdir(parents=True, exist_ok=True)
        
        self.memory_file = self.base_dir / "gemini_memory/memory.json"
        self.summary_file = self.base_dir / "gemini_memory/memory_summary.md"
        self.agent_file = self.base_dir / "workspace/agent.md"
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
        
        # Initial identity sync
        self.sync_identity_files()

    def _load_memory(self):
        if self.memory_file.exists():
            try:
                with open(self.memory_file, "r") as f: return json.load(f)
            except: pass
        return []

    def _save_memory(self):
        if len(self.memory_data) > 300: self.memory_data = self.memory_data[-300:]
        with open(self.memory_file, "w") as f: json.dump(self.memory_data, f, indent=2)

    def sync_identity_files(self):
        """Merges agent.md with core system rules into GEMINI.md and QWEN.md."""
        agent_content = ""
        if self.agent_file.exists():
            agent_content = self.agent_file.read_text(encoding="utf-8")
        
        core_rules = (
            f"\n\n# Mandatory System Rules\n"
            f"- Your identity: '{self.name.capitalize()}', assistant for '老兵'.\n"
            f"- Working Directory: You are running in your dedicated workspace. Perform all file operations here.\n"
            f"- Vision: To see the screen, run `screencapture screenshot.png`. The system will automatically analyze it for you.\n"
            f"- Output: Always respond in standard Markdown.\n"
        )
        
        full_content = agent_content + core_rules
        (self.base_dir / "workspace/GEMINI.md").write_text(full_content, encoding="utf-8")
        (self.base_dir / "workspace/QWEN.md").write_text(full_content, encoding="utf-8")
        self.debug_logger.debug("Identity files (GEMINI.md/QWEN.md) synchronized.")

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
        except Exception as e: return f"⚠️ Vision Error: {str(e)}"

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if not update.effective_user or update.effective_user.id != ALLOWED_USER_ID: return
        self.update_daily_log_handler()
        user_text = update.message.text
        if not user_text: return
        
        self.console.info(f"📥 Received: {user_text[:50]}...")
        # Sync before each call in case agent.md was modified by the bot itself
        self.sync_identity_files()

        try:
            # Command Handling
            if user_text.startswith("/engine"):
                parts = user_text.split()
                if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                    self.engine = parts[1].lower()
                    await update.message.reply_text(f"🚀 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                else: await update.message.reply_text(f"🤖 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                return

            if user_text == "/new":
                self.skip_session_once = True
                await update.message.reply_text(f"🧹 <b>{self.engine.upper()}</b> Session Reset.", parse_mode=ParseMode.HTML)
                return

            if user_text == "/summary":
                log_md = self.base_dir / f"logs/{datetime.date.today().isoformat()}.md"
                if not log_md.exists():
                    await update.message.reply_text("No logs today."); return
                facts = client.models.generate_content(model='gemini-2.5-flash', contents=f"Extract facts for '老兵':\n\n{log_md.read_text()}").text
                with open(self.summary_file, "a") as f: f.write(f"\n### {datetime.date.today().isoformat()} Facts\n{facts}\n")
                await update.message.reply_text(f"✅ Summary saved."); play_notification_sound(); return

            # Context Construction (Simplified)
            facts_str = ""
            if self.summary_file.exists():
                with open(self.summary_file, "r") as f: facts_str = "".join(f.readlines()[-50:]).strip()

            # The Prompt is now just the Dialogue
            full_prompt = f"=== 已知事实：{facts_str or '暂无。'} ===\n老兵：{user_text}"
            if user_text == "/compact": full_prompt = "/compact"

            status_msg = None
            try: status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} thinking...", read_timeout=10, connect_timeout=10)
            except: pass

            cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
            if not self.skip_session_once:
                if self.engine == "gemini": cmd.append("--resume=latest")
                elif self.engine == "qwen": cmd.extend(["--continue", f"--session-id={self.name}"])
            else: self.skip_session_once = False

            start_ts = datetime.datetime.now().timestamp()
            self.debug_logger.debug(f"CMD: {' '.join(cmd)}")
            
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.base_dir / "workspace")
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120.0)
            except asyncio.TimeoutError:
                proc.kill()
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Timeout.")
                return

            duration = datetime.datetime.now().timestamp() - start_ts
            raw_stdout = stdout.decode()
            self.debug_logger.debug(f"RAW STDOUT: {raw_stdout}")
            if stderr: self.debug_logger.debug(f"RAW STDERR: {stderr.decode()}")
            
            response_text, usage = parse_cli_response(self.engine, raw_stdout)

            shot = self.base_dir / "workspace/screenshot.png"
            if shot.exists() and shot.stat().st_mtime > start_ts:
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

            if proc.returncode == 0:
                today_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                with open(today_md, "a", encoding="utf-8") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] 老兵: {user_text}\n{self.name.capitalize()}: {response_text}\n\n")
                self.memory_data.append({"text": f"老兵: {user_text}\n{self.name.capitalize()}: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory()

            footer = ""
            if usage:
                total = usage.get("total_tokens") or usage.get("total") or usage.get("totalTokens")
                if total:
                    if self.engine == "gemini": footer = f"\n\n<pre>Context Left: {(1048576 - total)/1000:.1f}k</pre>"
                    else: footer = f"\n\n<pre>Tokens Used: {total/1000:.1f}k</pre>"

            final_html = safe_truncate_html(smart_format_render(response_text) + footer)
            if status_msg:
                try: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=final_html, parse_mode=ParseMode.HTML)
                except: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=response_text[:4000])
            else: await update.message.reply_text(text=response_text[:4000])
            self.console.info(f"✅ {self.engine.upper()} ({duration:.1f}s)")

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
    print(f"--- Starting Native Session Bridge (Bots: {len(bot_configs)}) ---")
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
