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

# --- Shared Helper Functions ---
def smart_format_markdown(text):
    if not text: return "✅ Done."
    text = re.sub(r'^#+\s+(.*)$', r'*\1*', text, flags=re.MULTILINE)
    lines = text.split('\n')
    formatted, in_table = [], False
    for line in lines:
        is_row = line.strip().startswith('|') and line.strip().count('|') >= 2
        if is_row and not in_table:
            formatted.append("```text")
            in_table = True
            formatted.append(line)
        elif not is_row and in_table:
            formatted.append("```")
            in_table = False
            formatted.append(line)
        else: formatted.append(line)
    if in_table: formatted.append("```")
    return '\n'.join(formatted)

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
        
        # Directories
        self.base_dir = Path(f"bots/{self.name}")
        self.log_dir = self.base_dir / "logs"
        self.memory_dir = self.base_dir / "gemini_memory"
        self.workspace_dir = self.base_dir / "workspace"
        for d in [self.log_dir, self.memory_dir, self.workspace_dir]: d.mkdir(parents=True, exist_ok=True)
        
        self.memory_file = self.memory_dir / "memory.json"
        self.summary_file = self.memory_dir / "memory_summary.md"
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
        log_path = self.log_dir / f"{today}.log"
        for h in self.debug_logger.handlers[:]: self.debug_logger.removeHandler(h)
        fh = logging.FileHandler(log_path, encoding='utf-8')
        fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
        self.debug_logger.addHandler(fh)

    async def get_vision_analysis(self, query, img_path):
        try:
            img = Image.open(img_path)
            prompt = f"You are '{self.name.capitalize()}'. AI for '老兵'. Analysis for: {query}. Use Markdown."
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

        # Command Handling
        if user_text.startswith("/engine"):
            parts = user_text.split()
            if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                self.engine = parts[1].lower()
                await update.message.reply_text(f"🚀 Engine: **{self.engine.upper()}**", parse_mode='Markdown')
            else: await update.message.reply_text(f"🤖 Engine: **{self.engine.upper()}**")
            return

        if user_text == "/summary":
            today = datetime.date.today().isoformat()
            log_md = self.log_dir / f"{today}.md"
            if not log_md.exists():
                await update.message.reply_text("No logs yet."); return
            prompt = f"Extract permanent facts from logs for '老兵':\n\n{log_md.read_text()}"
            facts = client.models.generate_content(model='gemini-2.5-flash', contents=prompt).text
            with open(self.summary_file, "a") as f: f.write(f"\n### {today} Facts\n{facts}\n")
            await update.message.reply_text(f"✅ Summary saved.")
            play_notification_sound(); return

        # Context (RAG)
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

        status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} thinking...")
        self.debug_logger.debug(f"PROMPT: {full_prompt}")

        cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
        start_ts = datetime.datetime.now().timestamp()
        
        try:
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120.0)
            except asyncio.TimeoutError:
                proc.kill(); await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Timeout."); return

            duration = datetime.datetime.now().timestamp() - start_ts
            raw_stdout = stdout.decode()
            self.debug_logger.debug(f"Duration: {duration:.1f}s\nSTDOUT: {raw_stdout}")

            response_text = parse_cli_response(self.engine, raw_stdout)

            # Vision Check
            shot = self.workspace_dir / "screenshot.png"
            if shot.exists() and shot.stat().st_mtime > start_ts:
                await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

            # Final Render
            final_formatted = smart_format_markdown(response_text)
            try:
                await context.bot.edit_message_text(
                    chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                    text=final_formatted[:4000], parse_mode='Markdown'
                )
            except:
                await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=response_text[:4000])

            self.console.info(f"✅ {self.engine.upper()} ({duration:.1f}s)")

            if proc.returncode == 0:
                today_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                with open(today_md, "a") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] User: {user_text}\nResponse: {response_text}\n\n")
                self.memory_data.append({"text": f"User: {user_text}\nBot: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory_file()

        except Exception as e:
            self.console.error(f"⚠️ Exception: {e}")
            await update.message.reply_text(f"❌ Error: {str(e)}")
        
        play_notification_sound()

# --- Async Multi-Bot Runner ---
async def main():
    bot_configs = {k.replace("_BOT_TOKEN", "").lower(): v for k, v in os.environ.items() if k.endswith("_BOT_TOKEN")}
    
    if not bot_configs:
        print("❌ No bot tokens found in .env")
        return

    print(f"--- Starting Gemini Telegram Bridge (Total Bots: {len(bot_configs)}) ---")
    
    apps = []
    for name, token in bot_configs.items():
        instance = GeminiBotInstance(name, token)
        app = ApplicationBuilder().token(token).build()
        app.add_handler(MessageHandler(filters.TEXT, instance.handle_message))
        
        print(f"🚀 Launching Bot: {name.upper()}")
        # Manually initialize and start
        await app.initialize()
        await app.start()
        await app.updater.start_polling()
        apps.append(app)

    # Use a permanent wait event
    stop_event = asyncio.Event()
    
    # Handle termination signals
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: stop_event.set())

    print("--- Bridge is running. Press Ctrl+C to stop. ---")
    await stop_event.wait()
    
    print("\n--- Shutting down all bots... ---")
    for app in apps:
        await app.updater.stop()
        await app.stop()
        await app.shutdown()

if __name__ == '__main__':
    asyncio.run(main())
