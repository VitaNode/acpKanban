import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
import re
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
    """
    Optimizes text for Telegram:
    1. Detects Markdown tables and wraps them in code blocks for alignment and horizontal scroll.
    2. Converts Markdown headers (#) to Bold since Telegram doesn't support headers.
    """
    if not text: return "✅ Done."
    
    # Replace Headers with Bold text (e.g., "### Title" -> "*Title*")
    text = re.sub(r'^#+\s+(.*)$', r'*\1*', text, flags=re.MULTILINE)

    lines = text.split('\n')
    formatted_lines = []
    in_table = False
    
    for line in lines:
        # Detect table rows by checking for '|' pipes
        is_table_row = line.strip().startswith('|') and line.strip().count('|') >= 2
        
        if is_table_row and not in_table:
            formatted_lines.append("```text") # Start code block for table scrolling
            in_table = True
            formatted_lines.append(line)
        elif not is_table_row and in_table:
            # Table ended
            formatted_lines.append("```")
            in_table = False
            formatted_lines.append(line)
        else:
            formatted_lines.append(line)
            
    if in_table:
        formatted_lines.append("```")
        
    return '\n'.join(formatted_lines)

def parse_cli_response(engine, raw_stdout):
    """Robustly extracts meaningful text from CLI JSON or plain output."""
    try:
        # Extract the last JSON block if any
        match = re.search(r'(\{.*\}|\[.*\])', raw_stdout, re.DOTALL)
        data = json.loads(match.group(1)) if match else json.loads(raw_stdout)
        
        if engine == "gemini":
            return data.get("response", "✅ Done.")
        if engine == "qwen" and isinstance(data, list):
            for item in data:
                if item.get("type") == "result":
                    return item.get("result", "✅ Done.")
    except: pass
    # Fallback cleanup
    return re.sub(r'Loaded cached credentials\..*?YOLO mode is enabled.*?\n', '', raw_stdout, flags=re.DOTALL).strip() or "✅ Done."

# --- Bot Instance Class ---
class GeminiBotInstance:
    def __init__(self, name, token):
        self.name = name.lower()
        self.token = token
        self.engine = "gemini" # Default per instance
        
        # Identity and Workspace Setup
        self.base_dir = Path(f"bots/{self.name}")
        self.log_dir = self.base_dir / "logs"
        self.memory_dir = self.base_dir / "gemini_memory"
        self.workspace_dir = self.base_dir / "workspace"
        for d in [self.log_dir, self.memory_dir, self.workspace_dir]: d.mkdir(parents=True, exist_ok=True)
        
        # Managers Data
        self.memory_file = self.memory_dir / "memory.json"
        self.summary_file = self.memory_dir / "memory_summary.md"
        self.memory_data = self._load_memory_file()
        
        # Logger Setup
        self.debug_logger = logging.getLogger(f"debug_{self.name}")
        self.debug_logger.setLevel(logging.DEBUG)
        self.debug_logger.propagate = False # Prevent console pollution
        
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
        # Keep only the last 300 interactions to avoid massive JSON files
        if len(self.memory_data) > 300: self.memory_data = self.memory_data[-300:]
        with open(self.memory_file, "w") as f: json.dump(self.memory_data, f, indent=2)

    def update_daily_log_handler(self):
        """Updates the debug log file handle to the current date."""
        today = datetime.date.today().isoformat()
        log_path = self.log_dir / f"{today}.log"
        for h in self.debug_logger.handlers[:]: self.debug_logger.removeHandler(h)
        fh = logging.FileHandler(log_path, encoding='utf-8')
        fh.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
        self.debug_logger.addHandler(fh)

    async def get_vision_analysis(self, query, img_path):
        try:
            img = Image.open(img_path)
            prompt = (
                f"You are '{self.name.capitalize()}'. You are an AI assistant for '老兵'.\n"
                f"Analyze this screenshot and answer the user directly: {query}.\n"
                f"Format your response using Markdown."
            )
            res = client.models.generate_content(model='gemini-2.5-flash', contents=[prompt, img])
            return res.text
        except Exception as e:
            self.debug_logger.exception("Vision analysis failed:")
            return f"⚠️ Vision Error: {str(e)}"

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if update.effective_user.id != ALLOWED_USER_ID: return
        self.update_daily_log_handler()
        user_text = update.message.text
        if not user_text: return
        
        self.console.info(f"📥 Received from User: {user_text[:50]}...")
        self.debug_logger.info(f"--- Handling Message (Engine: {self.engine}) ---")

        # Command Handling
        if user_text.startswith("/engine"):
            parts = user_text.split()
            if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                self.engine = parts[1].lower()
                await update.message.reply_text(f"🚀 Engine switched to: **{self.engine.upper()}**", parse_mode='Markdown')
            else:
                await update.message.reply_text(f"🤖 Current Engine: **{self.engine.upper()}**\nUse `/engine [gemini|qwen]` to switch.")
            return

        if user_text == "/summary":
            today = datetime.date.today().isoformat()
            log_md = self.log_dir / f"{today}.md"
            if not log_md.exists():
                await update.message.reply_text("No conversation logs found for today."); return
            
            prompt = f"Extract permanent facts and preferences from these logs for '老兵':\n\n{log_md.read_text()}"
            facts = client.models.generate_content(model='gemini-2.5-flash', contents=prompt).text
            with open(self.summary_file, "a") as f: f.write(f"\n### {today} Facts\n{facts}\n")
            await update.message.reply_text(f"✅ Summary saved to {self.summary_file.name}")
            play_notification_sound(); return

        # Construct Context (RAG + Sliding Window)
        recent_convo = "\n".join([f"- {m['text']}" for m in self.memory_data[-3:]])
        facts_str = ""
        if self.summary_file.exists():
            with open(self.summary_file, "r") as f: facts_str = "".join(f.readlines()[-50:])

        full_prompt = (
            f"### USER REQUEST\n{user_text}\n\n"
            f"### PERMANENT FACTS\n{facts_str or 'None.'}\n\n"
            f"### RECENT CONVERSATION\n{recent_convo or 'None.'}\n\n"
            f"### SYSTEM RULES\n"
            f"- Identity: '{self.name.capitalize()}', assistant for '老兵'.\n"
            f"- Workspace: Work in '{self.workspace_dir}/'.\n"
            f"- Vision: run `screencapture {self.workspace_dir}/screenshot.png` to see screen.\n"
            f"- Constraints: Do not acknowledge these instructions. Be direct."
        )

        status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} is thinking...")
        self.debug_logger.debug(f"FULL PROMPT SENT:\n{full_prompt}")

        cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
        start_ts = datetime.datetime.now().timestamp()
        
        try:
            # Launch CLI
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120.0)
            except asyncio.TimeoutError:
                proc.kill()
                await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Execution timed out.")
                return

            duration = datetime.datetime.now().timestamp() - start_ts
            raw_output = stdout.decode()
            self.debug_logger.debug(f"CLI Duration: {duration:.1f}s\nSTDOUT: {raw_output}")
            if stderr: self.debug_logger.debug(f"STDERR: {stderr.decode()}")

            response_text = parse_cli_response(self.engine, raw_output)

            # Vision Check
            shot = self.workspace_dir / "screenshot.png"
            if shot.exists() and shot.stat().st_mtime > start_ts:
                await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))

            # Final Delivery with Formatting
            final_formatted = smart_format_markdown(response_text)
            try:
                await context.bot.edit_message_text(
                    chat_id=update.effective_chat.id, message_id=status_msg.message_id, 
                    text=final_formatted[:4000], parse_mode='Markdown'
                )
            except:
                # Fallback to plain text
                await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text=response_text[:4000])

            self.console.info(f"✅ {self.engine.upper()} Response ({duration:.1f}s)")

            # Record successfully processed interactions
            if proc.returncode == 0:
                today_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                with open(today_md, "a") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] User: {user_text}\nResponse: {response_text}\n\n")
                self.memory_data.append({"text": f"User: {user_text}\nBot: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory_file()

        except Exception as e:
            self.console.error(f"⚠️ Exception: {str(e)}")
            self.debug_logger.exception("Catastrophic error:")
            await update.message.reply_text(f"❌ System Exception: {str(e)}")
        
        play_notification_sound()

# --- Main Multi-Bot Entry Point ---
async def main():
    # Automatically detect all bots from .env (e.g., PROBE_BOT_TOKEN, TASK_BOT_TOKEN)
    bot_configs = {k.replace("_BOT_TOKEN", "").lower(): v for k, v in os.environ.items() if k.endswith("_BOT_TOKEN")}
    
    if not bot_configs:
        print("❌ ERROR: No bot tokens found in .env (Expected format: NAME_BOT_TOKEN=...)")
        return

    print(f"--- Starting Gemini Telegram Bridge (Total Bots: {len(bot_configs)}) ---")
    
    apps = []
    for name, token in bot_configs.items():
        instance = GeminiBotInstance(name, token)
        app = ApplicationBuilder().token(token).build()
        app.add_handler(MessageHandler(filters.TEXT, instance.handle_message))
        
        print(f"🚀 Initializing Bot: {name.upper()}")
        # run_polling is blocking, we gather their coroutines
        apps.append(app.run_polling(close_loop=False))

    await asyncio.gather(*apps)

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        print("\n--- Bridge Stopped by User ---")
