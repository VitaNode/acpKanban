import os
import json
import logging
import asyncio
import subprocess
import datetime
import re
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

import logging.handlers

# --- Global Config ---
load_dotenv()
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
client = genai.Client(api_key=GEMINI_API_KEY)

# Global Main Logger
log_dir = Path("logs")
log_dir.mkdir(exist_ok=True)
main_handler = logging.handlers.TimedRotatingFileHandler(
    log_dir / "bridge.log", when="midnight", interval=1, encoding="utf-8"
)
main_handler.setFormatter(logging.Formatter('%(asctime)s | MAIN | %(levelname)-8s | %(message)s'))
logging.getLogger().setLevel(logging.INFO)
logging.getLogger().addHandler(main_handler)

logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)

def play_notification_sound():
    try: subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
    except: pass

# --- Robust Multi-Format Renderer ---
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

def split_html_message(text, limit=4000):
    """Splits an HTML message into chunks, ensuring tags are closed and reopened."""
    if len(text) <= limit:
        return [text]

    chunks = []
    current_text = text

    while current_text:
        if len(current_text) <= limit:
            chunks.append(current_text)
            break

        # Find a safe split point (prefer newline)
        split_at = current_text.rfind('\n', 0, limit)
        if split_at < limit * 0.7: # If no newline in last 30% of chunk, hard split
            split_at = limit

        # Ensure we don't split in the middle of a tag <...>
        tag_start = current_text.rfind('<', 0, split_at)
        tag_end = current_text.rfind('>', 0, split_at)
        if tag_start > tag_end: # We are inside a tag
            split_at = tag_start

        chunk = current_text[:split_at]
        remaining = current_text[split_at:]

        # Handle tag closure and reopening
        open_tags = []
        for tag in ['b', 'i', 'code', 'pre']:
            # Count tags in THIS chunk
            opened = chunk.count(f"<{tag}>")
            closed = chunk.count(f"</{tag}>")
            if opened > closed:
                open_tags.append(tag)
                chunk += f"</{tag}>"

        chunks.append(chunk)

        # Prefix the next chunk with reopened tags in correct order
        if remaining and open_tags:
            prefix = "".join([f"<{t}>" for t in open_tags])
            remaining = prefix + remaining

        current_text = remaining

    return chunks

async def send_smart_reply(update, context, text, status_msg=None):
    """Sends long messages in chunks to Telegram."""
    chunks = split_html_message(text)

    # Send first chunk (edit status_msg or reply)
    if status_msg:
        try:
            await context.bot.edit_message_text(
                chat_id=update.effective_chat.id,
                message_id=status_msg.message_id,
                text=chunks[0],
                parse_mode=ParseMode.HTML
            )
        except Exception:
            await context.bot.edit_message_text(
                chat_id=update.effective_chat.id,
                message_id=status_msg.message_id,
                text=re.sub('<[^<]+?>', '', chunks[0])[:4000] # Strip HTML if it fails
            )
    else:
        await update.message.reply_text(chunks[0], parse_mode=ParseMode.HTML)

    # Send remaining chunks
    for chunk in chunks[1:]:
        await update.message.reply_text(chunk, parse_mode=ParseMode.HTML)

def find_usage_info(data):
    """Recursively search for usage/token information in the JSON data."""
    if not isinstance(data, (dict, list)): return None
    if isinstance(data, dict):
        if "usage" in data: return data["usage"]
        if "tokens" in data: return data["tokens"]
        for val in data.values():
            res = find_usage_info(val)
            if res: return res
    elif isinstance(data, list):
        for item in data:
            res = find_usage_info(item)
            if res: return res
    return None

def parse_cli_response(engine, raw_stdout, logger=None):
    text, usage = None, None
    try:
        match = re.search(r'(\{.*\}|\[.*\])', raw_stdout, re.DOTALL)
        data = json.loads(match.group(1)) if match else json.loads(raw_stdout)
        
        # For Qwen (array format), prioritize usage from type="result" object
        if engine == "qwen" and isinstance(data, list):
            for item in data:
                if isinstance(item, dict) and item.get("type") == "result":
                    if "usage" in item:
                        usage = item["usage"]
                    if "result" in item:
                        text = item.get("result")
                    break
        
        # Fallback to recursive search if usage not found
        if usage is None:
            usage = find_usage_info(data)
        
        # For Gemini
        if engine == "gemini" and text is None:
            text = data.get("response")
        
        # Fallback for any dict response
        if text is None and isinstance(data, dict):
            text = data.get("result") or data.get("response")
            
        if usage is None and logger:
            logger.debug(f"⚠️ No usage info found. JSON: {json.dumps(data, indent=2)[:2000]}...")
    except: pass
    if text is None: text = re.sub(r'Loaded cached credentials\..*?YOLO mode is enabled.*?\n', '', raw_stdout, flags=re.DOTALL).strip()
    return text or "✅ Done.", usage

# --- Bot Instance Class ---
class GeminiBotInstance:
    def __init__(self, name, token):
        self.name = name.lower()
        self.token = token
        
        # Default engine per bot
        DEFAULT_ENGINES = {
            "probe": "qwen",
            "task": "gemini",
        }
        self.engine = DEFAULT_ENGINES.get(self.name, "gemini")
        
        self.skip_session_once = False
        
        # Proper attribute assignment to fix AttributeError
        self.base_dir = Path(f"bots/{self.name}")
        self.log_dir = self.base_dir / "logs"
        self.memory_dir = self.base_dir / "gemini_memory"
        self.workspace_dir = self.base_dir / "workspace"
        for d in [self.log_dir, self.memory_dir, self.workspace_dir]: d.mkdir(parents=True, exist_ok=True)
        
        self.memory_file = self.memory_dir / "memory.json"
        self.summary_file = self.memory_dir / "memory_summary.md"
        self.agent_file = self.workspace_dir / "agent.md"
        self.memory_data = self._load_memory()
        
        # 统一日志：终端全量输出（DEBUG 级别），带颜色区分
        self.logger = logging.getLogger(f"bot_{self.name}")
        self.logger.setLevel(logging.DEBUG)
        self.logger.propagate = False
        
        # 清除已有 handler（避免重复）
        if not self.logger.handlers:
            # 终端 handler - 彩色输出
            sh = logging.StreamHandler()
            sh.setLevel(logging.DEBUG)
            sh.setFormatter(logging.Formatter(
                f'%(asctime)s | %(name)s | %(levelname)-8s | %(message)s',
                datefmt='%H:%M:%S'
            ))
            self.logger.addHandler(sh)
            
            # 文件 handler - 每天归档一次
            fh = logging.handlers.TimedRotatingFileHandler(
                self.log_dir / f"{self.name}.log",
                when="midnight",
                interval=1,
                encoding="utf-8"
            )
            fh.setFormatter(logging.Formatter('%(asctime)s | %(levelname)-8s | %(message)s'))
            self.logger.addHandler(fh)

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
        agent_content = self.agent_file.read_text(encoding="utf-8") if self.agent_file.exists() else ""
        core_rules = (
            f"\n\n# Mandatory System Rules\n"
            f"- Your identity: '{self.name.capitalize()}', assistant for '老兵'.\n"
            f"- Working Directory: Perform all file operations here in your workspace.\n"
            f"- Vision: run `screencapture screenshot.png` to see screen.\n"
            f"- Output: Always respond in standard Markdown.\n"
        )
        full_content = agent_content + core_rules
        (self.workspace_dir / "GEMINI.md").write_text(full_content, encoding="utf-8")
        (self.workspace_dir / "QWEN.md").write_text(full_content, encoding="utf-8")

    async def get_vision_analysis(self, query, img_path):
        try:
            img = Image.open(img_path)
            prompt = f"You are '{self.name.capitalize()}'. AI for '老兵'. Request: {query}. Respond in Markdown."
            res = client.models.generate_content(model='gemini-2.5-flash', contents=[prompt, img])
            return res.text
        except Exception as e: return f"⚠️ Vision Error: {str(e)}"

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        if not update.effective_user or update.effective_user.id != ALLOWED_USER_ID: return
        user_text = update.message.text
        if not user_text: return

        session_start = datetime.datetime.now().timestamp()
        self.logger.info(f"📥 Received: {user_text[:50]}...")
        self.sync_identity_files()

        def log_phase(name: str):
            """记录阶段耗时"""
            now = datetime.datetime.now().timestamp()
            elapsed = now - session_start
            self.logger.debug(f"⏱️ [{elapsed:5.1f}s] {name}")

        try:
            # Command Handling
            if user_text.startswith("/engine"):
                parts = user_text.split()
                if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                    self.engine = parts[1].lower()
                    await update.message.reply_text(f"🚀 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                else: await update.message.reply_text(f"🤖 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                log_phase(f"Command /engine ({self.engine})")
                return

            if user_text == "/new":
                self.skip_session_once = True
                await update.message.reply_text(f"🧹 <b>{self.engine.upper()}</b> Reset.", parse_mode=ParseMode.HTML)
                log_phase("Command /new (session reset)")
                return

            if user_text == "/summary":
                log_phase("Starting /summary...")
                log_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                if not log_md.exists():
                    await update.message.reply_text("No logs yet."); return
                facts = client.models.generate_content(model='gemini-2.5-flash', contents=f"Extract facts for '老兵':\n\n{log_md.read_text()}").text
                with open(self.summary_file, "a") as f: f.write(f"\n### {datetime.date.today().isoformat()} Facts\n{facts}\n")
                await update.message.reply_text(f"✅ Summary saved."); play_notification_sound(); return
                log_phase(f"/summary completed")

            # Context Construction
            facts_str = ""
            if self.summary_file.exists():
                with open(self.summary_file, "r") as f: facts_str = "".join(f.readlines()[-50:]).strip()
            log_phase("Context built")

            full_prompt = f"=== 已知事实: {facts_str or '暂无'} ===\n老兵: {user_text}"
            if user_text == "/compact": full_prompt = "/compact"

            status_msg = None
            try: 
                status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} thinking...", read_timeout=10, connect_timeout=10)
                log_phase("Status message sent")
            except: pass

            # 🛠️ CLI Execution Logic - Fixed Qwen Session Parameters
            cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
            
            if not self.skip_session_once:
                if self.engine == "gemini": cmd.append("--resume=latest")
                elif self.engine == "qwen": cmd.append("--continue") # Use simple continue inside bot's workspace
            else:
                self.skip_session_once = False # Skip the resume/continue flag for one turn

            self.logger.debug(f"CMD: {' '.join(cmd)}")
            log_phase("CLI start")

            proc = await asyncio.create_subprocess_exec(*cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.workspace_dir)
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=600.0)
            except asyncio.TimeoutError:
                proc.kill()
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="⏱️ Timeout.")
                self.logger.warning("⏱️ CLI execution timeout (>600s)")
                log_phase("CLI TIMEOUT")
                return

            cli_end = datetime.datetime.now().timestamp()
            cli_duration = cli_end - session_start
            raw_stdout = stdout.decode()
            self.logger.debug(f"RAW STDOUT ({len(raw_stdout)} chars): {raw_stdout}")
            if stderr:
                stderr_text = stderr.decode()
                self.logger.debug(f"RAW STDERR ({len(stderr_text)} chars): {stderr_text}")
            log_phase(f"CLI completed ({cli_duration:.1f}s)")
            
            response_text, usage = parse_cli_response(self.engine, raw_stdout, self.logger)
            log_phase("Response parsed")

            shot = self.workspace_dir / "screenshot.png"
            if shot.exists() and shot.stat().st_mtime > cli_end:
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                log_phase("Vision analysis start")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))
                log_phase("Vision completed")

            if proc.returncode == 0:
                today_md = self.log_dir / f"{datetime.date.today().isoformat()}.md"
                with open(today_md, "a", encoding="utf-8") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] 老兵: {user_text}\n{self.name.capitalize()}: {response_text}\n\n")
                self.memory_data.append({"text": f"老兵: {user_text}\n{self.name.capitalize()}: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory()
                log_phase("Logs & memory saved")

            footer = ""
            if usage:
                total = usage.get("total_tokens") or usage.get("total") or usage.get("totalTokens")
                if total:
                    if self.engine == "gemini": footer = f"\n\n<pre>Context Left: {(1048576 - total)/1000:.1f}k</pre>"
                    else: footer = f"\n\n<pre>Tokens Used: {total/1000:.1f}k</pre>"

            # 7. Render and Send (Smart Split)
            final_html = smart_format_render(response_text) + footer
            await send_smart_reply(update, context, final_html, status_msg)
            log_phase("Response sent")
            
            total_duration = datetime.datetime.now().timestamp() - session_start
            self.logger.info(f"✅ {self.engine.upper()} ({total_duration:.1f}s)")

        except (TimedOut, NetworkError):
            self.logger.warning("⚠️ Network timeout (ignored)")
            log_phase("Network error")
        except Exception as e:
            self.logger.error(f"⚠️ Error: {e}")
            self.logger.exception("Catastrophic:")
            log_phase("Error")
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
