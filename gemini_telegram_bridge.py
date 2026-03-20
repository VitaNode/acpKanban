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

async def send_smart_reply(update, context, text, query, status_msg=None, bot_instance=None):
    """Sends long messages in chunks to Telegram. If fails, saves to outbox with original query."""
    chunks = split_html_message(text)
    
    try:
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
            
    except (TimedOut, NetworkError) as e:
        if bot_instance:
            await bot_instance.save_to_outbox(update.effective_chat.id, text, query)
        raise e # Re-raise to let handle_message know it failed

def find_usage_tokens(data, is_trusted=False):
    """Recursively scans for token counts with transitive trust for sub-blocks."""
    max_count = 0
    if isinstance(data, dict):
        # 1. Capture highly specific keys even without trust
        for key in ["total_tokens", "totalTokens", "input_tokens", "output_tokens"]:
            if key in data and isinstance(data[key], (int, float)):
                max_count = max(max_count, int(data[key]))
        
        # 2. Capture generic 'total' only if in a trusted usage/tokens block
        if is_trusted and "total" in data and isinstance(data["total"], (int, float)):
            max_count = max(max_count, int(data["total"]))
        
        # 3. Recurse with transitive trust
        for key, val in data.items():
            if isinstance(val, (dict, list)):
                # If current key is a known usage indicator, or parent was trusted, child is trusted
                child_trusted = is_trusted or key in ["usage", "tokens", "stats"]
                res = find_usage_tokens(val, child_trusted)
                max_count = max(max_count, res)
                
    elif isinstance(data, list):
        for item in data:
            res = find_usage_tokens(item, is_trusted)
            max_count = max(max_count, res)
            
    return max_count

def parse_cli_response(engine, raw_stdout, logger=None):
    text, occupancy, session_id = None, 0, None
    
    # 🕵️ Detect Chat Compression Info
    compact_match = re.search(r'Chat history compressed from (\d+) to (\d+) tokens', raw_stdout)
    if compact_match:
        old, new = compact_match.groups()
        return f"📉 <b>Context Compressed!</b>\n<code>{old}</code> → <code>{new}</code> tokens", int(new), None

    # 🚨 Detect 429
    if "RESOURCE_EXHAUSTED" in raw_stdout or "MODEL_CAPACITY_EXHAUSTED" in raw_stdout or "status: 429" in raw_stdout:
        return "⚠️ <b>Google 服务器负载过高</b>\n当前模型资源已耗尽，请稍后再试或切换引擎。", 0, None

    try:
        match = re.search(r'(\{.*\}|\[.*\])', raw_stdout, re.DOTALL)
        data = json.loads(match.group(1)) if match else json.loads(raw_stdout)
        
        # 🆔 Capture Session ID
        if isinstance(data, dict):
            session_id = data.get("session_id")
        elif isinstance(data, list) and data:
            session_id = data[-1].get("session_id") or data[0].get("session_id")

        # 📊 Capture Occupancy (Input Tokens of the final state)
        qwen_usage = None
        if engine == "qwen" and isinstance(data, list):
            for item in reversed(data):
                if isinstance(item, dict) and item.get("type") == "result":
                    text = item.get("result")
                    qwen_usage = item.get("usage")
                    if qwen_usage:
                        # For occupancy, we want to know how much history + current prompt is in the "pot"
                        occupancy = qwen_usage.get("input_tokens") or qwen_usage.get("total_tokens") or 0
                    break
        
        if engine == "gemini":
            if isinstance(data, dict):
                text = data.get("response")
                # Try to get input_tokens from the main stats block
                stats = data.get("stats", {})
                usage = stats.get("usage") or data.get("usage")
                if usage:
                    occupancy = usage.get("input_tokens") or usage.get("total_tokens") or usage.get("total") or 0
        
        # Fallback to general scanner if specific fields weren't found
        if occupancy == 0:
            occupancy = find_usage_tokens(data)
            
        if text is None and isinstance(data, dict):
            text = data.get("result") or data.get("response")
    except: pass
    
    if text is None:
        text = re.sub(r'Loaded cached credentials\..*?YOLO mode is enabled.*?\n', '', raw_stdout, flags=re.DOTALL).strip()
    
    return text or "✅ Done.", occupancy, session_id

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
        
        # Directories
        self.base_dir = Path(f"bots/{self.name}")
        self.log_dir = self.base_dir / "logs"
        self.memory_dir = self.base_dir / "gemini_memory"
        self.workspace_dir = self.base_dir / "workspace"
        self.outbox_dir = self.base_dir / "outbox"
        for d in [self.log_dir, self.memory_dir, self.workspace_dir, self.outbox_dir]: d.mkdir(parents=True, exist_ok=True)

        self.memory_file = self.memory_dir / "memory.json"
        self.summary_file = self.memory_dir / "memory_summary.md"
        self.agent_file = self.workspace_dir / "agent.md"
        self.session_id_file = self.base_dir / "current_session.id" # Persistent session locking
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
        # We no longer write the full identity to GEMINI.md/QWEN.md to avoid per-prompt redundancy.
        # Instead, we only write a minimal header to ensure the CLI recognizes its agent capabilities.
        # The full identity is now injected once at the start of each session in handle_message.
        minimal_content = "# Assistant Mode\nYou are an AI agent with access to this workspace and tools. Follow the context provided in the conversation history."
        (self.workspace_dir / "GEMINI.md").write_text(minimal_content, encoding="utf-8")
        (self.workspace_dir / "QWEN.md").write_text(minimal_content, encoding="utf-8")

    async def get_vision_analysis(self, query, img_path):
        try:
            img = Image.open(img_path)
            prompt = f"You are '{self.name.capitalize()}'. AI for '老兵'. Request: {query}. Respond in Markdown."
            res = client.models.generate_content(model='gemini-2.5-flash', contents=[prompt, img])
            return res.text
        except Exception as e: return f"⚠️ Vision Error: {str(e)}"

    async def save_to_outbox(self, chat_id, text, query):
        """Saves failed messages to disk for later retry, including the original query."""
        ts = int(datetime.datetime.now().timestamp())
        path = self.outbox_dir / f"msg_{ts}.json"
        data = {"chat_id": chat_id, "text": text, "query": query, "ts": ts}
        with open(path, "w") as f: json.dump(data, f)
        self.logger.warning(f"📩 Message saved to outbox: {path.name}")

    async def outbox_reaper(self, bot):
        """Background task to periodically try and send pending outbox messages."""
        while True:
            await asyncio.sleep(60) # Try every 60s
            files = sorted(list(self.outbox_dir.glob("msg_*.json")))
            if not files: continue
            
            self.logger.info(f"🔄 Processing {len(files)} messages in outbox...")
            for f in files:
                try:
                    with open(f, "r") as json_f:
                        data = json.load(json_f)
                    
                    time_str = datetime.datetime.fromtimestamp(data["ts"]).strftime("%H:%M")
                    query_snip = data.get("query", "Unknown")[:100] + ("..." if len(data.get("query", "")) > 100 else "")
                    
                    header = f"🕒 <b>Delayed Reply [{time_str}]</b>\n❓ <b>问题:</b> {html.escape(query_snip)}\n\n💡 <b>回答:</b>\n"
                    full_text = header + data["text"]
                    
                    chunks = split_html_message(full_text)
                    for chunk in chunks:
                        await bot.send_message(chat_id=data["chat_id"], text=chunk, parse_mode=ParseMode.HTML)
                    
                    f.unlink() # Success!
                    self.logger.info(f"✅ Outbox message sent: {f.name}")
                except Exception as e:
                    self.logger.warning(f"❌ Failed to send outbox message {f.name}: {e}")
                    break

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
                if self.session_id_file.exists(): self.session_id_file.unlink()
                await update.message.reply_text(f"🧹 <b>{self.engine.upper()}</b> Session Reset.", parse_mode=ParseMode.HTML)
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

            # Context Construction - Inject full identity and summary ONLY on new session start.
            is_new_session = self.skip_session_once or not self.session_id_file.exists()
            
            if is_new_session:
                # 1. Load Full Identity (Agent.md + Core Rules)
                agent_content = self.agent_file.read_text(encoding="utf-8") if self.agent_file.exists() else ""
                core_rules = (
                    f"\n\n# Mandatory System Rules\n"
                    f"- Your identity: '{self.name.capitalize()}', assistant for '老兵'.\n"
                    f"- Working Directory: Perform all file operations here in your workspace.\n"
                    f"- Vision: run `screencapture screenshot.png` to see screen.\n"
                    f"- Output: Always respond in standard Markdown.\n"
                )
                identity_block = f"=== IDENTITY & RULES ===\n{agent_content}{core_rules}\n"
                
                # 2. Load Full Memory Summary
                summary_content = ""
                if self.summary_file.exists():
                    summary_content = self.summary_file.read_text(encoding="utf-8").strip()
                summary_block = f"=== HISTORICAL MEMORY (SUMMARY) ===\n{summary_content or 'No prior memory summary available.'}\n"
                
                full_prompt = f"{identity_block}\n{summary_block}\n=== START SESSION ===\n老兵: {user_text}"
                self.logger.info("🆕 Starting new session with full identity and summary.")
            else:
                # Normal conversation turn, relying on native session memory.
                full_prompt = f"老兵: {user_text}"
            
            log_phase("Context built")

            if user_text in ["/compact", "/compress"]: 
                full_prompt = user_text

            status_msg = None
            try: 
                status_msg = await update.message.reply_text(f"🧠 {self.engine.upper()} thinking...", read_timeout=10, connect_timeout=10)
                log_phase("Status message sent")
            except: pass

            # 🛠️ CLI Execution Logic - Robust Session Locking
            cmd = [self.engine, full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
            
            if not self.skip_session_once:
                if self.session_id_file.exists():
                    saved_id = self.session_id_file.read_text().strip()
                    if saved_id: cmd.append(f"--resume={saved_id}")
                else:
                    if self.engine == "gemini": cmd.append("--resume=latest")
                    elif self.engine == "qwen": cmd.append("--continue")
            else:
                self.skip_session_once = False # Force new session

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
            
            response_text, occupancy, session_id = parse_cli_response(self.engine, raw_stdout, self.logger)
            log_phase("Response parsed")

            # 🆔 Persistent Session Locking
            if session_id:
                self.session_id_file.write_text(session_id)
                self.logger.debug(f"🆔 Locked to session: {session_id}")

            shot = self.workspace_dir / "screenshot.png"
            if shot.exists() and shot.stat().st_mtime > cli_end:
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                log_phase("Vision analysis start")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))
                log_phase("Vision completed")

            if proc.returncode == 0:
                # 1. Save to System Logs (for debugging)
                today_str = datetime.date.today().isoformat()
                system_log = self.log_dir / f"{today_str}.md"
                with open(system_log, "a", encoding="utf-8") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] 老兵: {user_text}\n{self.name.capitalize()}: {response_text}\n\n")
                
                # 2. Save to AI Workspace Memory (for AI retrieval)
                workspace_memory_dir = self.workspace_dir / "memory"
                workspace_memory_dir.mkdir(exist_ok=True)
                workspace_log = workspace_memory_dir / f"{today_str}.md"
                with open(workspace_log, "a", encoding="utf-8") as f:
                    f.write(f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] 老兵: {user_text}\n{self.name.capitalize()}: {response_text}\n\n")

                self.memory_data.append({"text": f"老兵: {user_text}\n{self.name.capitalize()}: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
                self._save_memory()
                log_phase("Logs & workspace memory saved")

            footer = ""
            if occupancy > 0:
                kb = occupancy / 1000
                percent = (occupancy / 1048576) * 100
                footer = f"\n\n<pre>🗂️ Context: {kb:.1f}k / 1024k ({percent:.1f}%)</pre>"

            # 7. Render and Send (Smart Split)
            final_html = smart_format_render(response_text) + footer
            await send_smart_reply(update, context, final_html, user_text, status_msg, bot_instance=self)
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
        
        # Start background tasks
        asyncio.create_task(instance.outbox_reaper(app.bot))
        
        await app.initialize(); await app.start(); await app.updater.start_polling()
        apps.append(app); print(f"🚀 {name.upper()} Ready")
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM): loop.add_signal_handler(sig, lambda: stop_event.set())
    await stop_event.wait()
    for app in apps: await app.updater.stop(); await app.stop(); await app.shutdown()

if __name__ == '__main__':
    asyncio.run(main())
