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

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, ContextTypes, MessageHandler, CallbackQueryHandler, filters
from telegram.constants import ParseMode
from telegram.error import TimedOut, NetworkError, TelegramError

from acp_client import ACPClient

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
main_handler.setFormatter(logging.Formatter('%(asctime)s | %(levelname)-8s | [%(name)s] %(message)s'))

# Configure root logger to capture EVERYTHING
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s | %(levelname)-8s | [%(name)s] %(message)s',
    handlers=[main_handler, logging.StreamHandler()]
)

# Silence noisy libraries
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

def play_notification_sound():
    try: subprocess.run(["afplay", "/System/Library/Sounds/Glass.aiff"], check=False)
    except: pass

def extract_usage(data):
    """Robust usage extraction supporting both camelCase and snake_case."""
    if not data: return None
    usage = data.get("usage") or data.get("_meta", {}).get("usage")
    if not usage: return None
    
    i = usage.get("inputTokens") or usage.get("input_tokens") or 0
    o = usage.get("outputTokens") or usage.get("output_tokens") or 0
    t = usage.get("totalTokens") or usage.get("total_tokens") or (i + o)
    return {"in": i, "out": o, "total": t}

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

def split_html_message(text, limit=2000):
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
    """Sends long messages in chunks to Telegram with retry logic for unstable networks."""
    chunks = split_html_message(text)
    
    for i, chunk in enumerate(chunks):
        max_retries = 3
        retry_count = 0
        while retry_count < max_retries:
            try:
                if i == 0 and status_msg:
                    try:
                        await context.bot.edit_message_text(
                            chat_id=update.effective_chat.id,
                            message_id=status_msg.message_id,
                            text=chunk,
                            parse_mode=ParseMode.HTML
                        )
                    except Exception:
                        # Fallback: simple text if HTML fails
                        await context.bot.edit_message_text(
                            chat_id=update.effective_chat.id,
                            message_id=status_msg.message_id,
                            text=re.sub('<[^<]+?>', '', chunk)[:2000]
                        )
                else:
                    await update.message.reply_text(chunk, parse_mode=ParseMode.HTML)
                
                break # Success!
            except (TimedOut, NetworkError) as e:
                retry_count += 1
                if bot_instance:
                    bot_instance.logger.warning(f"⚠️ Telegram send failed (Attempt {retry_count}/{max_retries}): {e}")
                if retry_count < max_retries:
                    await asyncio.sleep(2) # Wait before retry
                else:
                    if bot_instance:
                        await bot_instance.save_to_outbox(update.effective_chat.id, text, query)
                    raise e
            except Exception as e:
                if bot_instance:
                    bot_instance.logger.error(f"❌ Critical send error: {e}")
                raise e

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
        
        # ACP Client Management
        self.acp_client = None
        self.acp_session_id = None
        self.permission_futures = {} # {request_id: Future}
        
        # 统一日志：终端全量输出（DEBUG 级别），带颜色区分
        self.logger = logging.getLogger(f"bot_{self.name}")
        self.logger.setLevel(logging.DEBUG)
        self.logger.propagate = True
        
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
            fh.setFormatter(logging.Formatter('%(asctime)s | %(levelname)-8s | [%(name)s] %(message)s'))
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

    async def _stop_acp_client(self):
        if self.acp_client:
            self.logger.info(f"Stopping ACP Client for {self.engine}")
            await self.acp_client.stop()
            self.acp_client = None
            self.acp_session_id = None

    async def _get_acp_client(self):
        if self.acp_client and self.acp_client._running:
            return self.acp_client
        
        # Start new client
        abs_workspace = str(self.workspace_dir.resolve())
        cmd = [self.engine, "--acp", "--approval-mode", "default"]
        
        self.acp_client = ACPClient(cmd, cwd=abs_workspace, name=f"{self.name}-{self.engine}")
        await self.acp_client.start()
        
        # Load or Create Session
        if self.session_id_file.exists() and not self.skip_session_once:
            saved_id = self.session_id_file.read_text().strip()
            if saved_id:
                try:
                    self.logger.info(f"Attempting to load ACP Session: {saved_id}")
                    # Try with standard sessionId first
                    load_params = {
                        "sessionId": saved_id,
                        "cwd": abs_workspace,
                        "mcpServers": []
                    }
                    resp = await self.acp_client.request("session/load", load_params)
                    
                    if "error" in resp:
                        # Fallback: try with snake_case session_id just in case
                        self.logger.debug(f"Retrying session/load with session_id fallback...")
                        load_params_fallback = load_params.copy()
                        load_params_fallback["session_id"] = saved_id
                        resp = await self.acp_client.request("session/load", load_params_fallback)

                    if "error" not in resp:
                        self.acp_session_id = saved_id
                        self.logger.info(f"✅ Successfully loaded ACP Session: {saved_id}")
                    else:
                        self.logger.warning(f"❌ Failed to load ACP Session {saved_id}: {resp['error']}")
                except Exception as e:
                    self.logger.error(f"Failed to load ACP session: {e}")

        if not self.acp_session_id:
            # Create new session
            try:
                self.logger.info("Creating new ACP Session...")
                resp = await self.acp_client.request("session/new", {
                    "cwd": abs_workspace,
                    "mcpServers": []
                })
                
                if "error" in resp:
                    self.logger.error(f"ACP session/new failed: {resp['error']}")
                    raise Exception(f"ACP Session Init Failed: {resp['error'].get('message')}")

                self.acp_session_id = resp.get("result", {}).get("sessionId")
                if self.acp_session_id:
                    self.session_id_file.write_text(self.acp_session_id)
                    self.logger.info(f"✅ Created new ACP Session: {self.acp_session_id}")
            except Exception as e:
                self.logger.error(f"Failed to create new ACP session: {e}")
                raise e

        return self.acp_client

    async def handle_callback(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        query = update.callback_query
        await query.answer()
        
        data = query.data # "perm:[approve|deny]:[request_id]"
        if not data.startswith("perm:"):
            return
            
        parts = data.split(":")
        action = parts[1]
        req_id = parts[2]
        
        if req_id in self.permission_futures:
            future = self.permission_futures.pop(req_id)
            if action == "approve":
                future.set_result(True)
                await query.edit_message_text(text=f"{query.message.text}\n\n✅ <b>已批准</b>", parse_mode=ParseMode.HTML)
            else:
                future.set_result(False)
                await query.edit_message_text(text=f"{query.message.text}\n\n❌ <b>已拒绝</b>", parse_mode=ParseMode.HTML)

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
                new_engine = None
                if len(parts) > 1 and parts[1].lower() in ["gemini", "qwen"]:
                    new_engine = parts[1].lower()
                
                if new_engine and new_engine != self.engine:
                    await self._stop_acp_client()
                    self.engine = new_engine
                    await update.message.reply_text(f"🚀 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                else: 
                    await update.message.reply_text(f"🤖 Engine: <b>{self.engine.upper()}</b>", parse_mode=ParseMode.HTML)
                log_phase(f"Command /engine ({self.engine})")
                return

            if user_text == "/new":
                self.skip_session_once = True
                await self._stop_acp_client()
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

            # 🛠️ ACP Execution Logic
            client = await self._get_acp_client()
            queue = client.listen(f"msg_{update.effective_message.id}")
            
            prompt_params = {
                "prompt": [{"type": "text", "text": full_prompt}],
                "sessionId": self.acp_session_id
            }
            
            prompt_task = asyncio.create_task(client.request("session/prompt", prompt_params))
            
            response_text = ""
            usage_data = None # Initialize to prevent UnboundLocalError
            usage_footer = "" 
            last_edit_time = 0
            edit_interval = 1.5 # seconds between Telegram edits to avoid rate limits
            
            try:
                # 1. Main streaming loop
                while not prompt_task.done() or not queue.empty():
                    try:
                        # If task is done, don't wait for timeout, just grab what's left
                        timeout = 0.1 if prompt_task.done() else 0.5
                        msg = await asyncio.wait_for(queue.get(), timeout=timeout)
                        
                        if msg.get("method") == "session/update":
                            params = msg.get("params", {})
                            update_data = params.get("update", {})
                            u_type = update_data.get("sessionUpdate")
                            
                            # Real-time usage extraction from notifications
                            notif_usage = extract_usage(update_data)
                            if notif_usage:
                                usage_data = notif_usage # Update the persistent usage_data
                            
                            if u_type == "agent_message_chunk":
                                content = update_data.get("content", {})
                                chunk = content.get("text", "")
                                response_text += chunk
                                
                                # Periodically update Telegram message
                                now = datetime.datetime.now().timestamp()
                                if response_text.strip() and now - last_edit_time > edit_interval:
                                    try:
                                        rendered = smart_format_render(response_text) + "\n\n(typing...)"
                                        await context.bot.edit_message_text(
                                            chat_id=update.effective_chat.id,
                                            message_id=status_msg.message_id,
                                            text=rendered,
                                            parse_mode=ParseMode.HTML
                                        )
                                        last_edit_time = now
                                    except Exception as e:
                                        self.logger.debug(f"Streaming edit failed: {e}")
                        
                        elif msg.get("method") == "session/request_permission":
                            # 🛡️ ACP Permission Interception
                            req_id = msg.get("id")
                            params = msg.get("params", {})
                            permission = params.get("permission", {})
                            
                            p_type = permission.get("type", "unknown")
                            p_desc = "AI 请求权限执行操作"
                            if p_type == "tool_call":
                                tool = permission.get("tool_call", {})
                                p_desc = f"🛠️ <b>工具调用申请</b>\n工具: <code>{tool.get('name')}</code>\n参数: <code>{json.dumps(tool.get('arguments'))}</code>"
                            
                            # Create buttons
                            keyboard = [
                                [
                                    InlineKeyboardButton("✅ 批准", callback_data=f"perm:approve:{req_id}"),
                                    InlineKeyboardButton("❌ 拒绝", callback_data=f"perm:deny:{req_id}")
                                ]
                            ]
                            reply_markup = InlineKeyboardMarkup(keyboard)
                            
                            # Send permission request
                            perm_msg = await update.message.reply_text(
                                f"🛡️ <b>权限审批请求</b>\n\n{p_desc}",
                                reply_markup=reply_markup,
                                parse_mode=ParseMode.HTML
                            )
                            
                            # Wait for user response
                            future = asyncio.get_running_loop().create_future()
                            self.permission_futures[req_id] = future
                            
                            self.logger.info(f"Waiting for permission decision on {req_id}...")
                            approved = await future
                            
                            # Send result back to ACP
                            await client.respond(req_id, result={"approved": approved})
                            self.logger.info(f"Permission {req_id} decision: {approved}")
                    except asyncio.TimeoutError:
                        continue
                
                # 2. Final wrap up and Usage Extraction
                final_resp = await prompt_task
                
                # IMPORTANT: Only update usage_data if the final response actually contains it.
                # Do not overwrite the usage we might have captured during streaming chunks!
                final_usage = extract_usage(final_resp.get("result", {}))
                if final_usage:
                    usage_data = final_usage

                # Ensure usage_footer is updated even if it was extracted earlier
                if usage_data:
                    usage_footer = f"\n\n<pre>📊 Tokens: {usage_data['total']/1000:.1f}k (In: {usage_data['in']/1000:.1f}k | Out: {usage_data['out']/1000:.1f}k)</pre>"
                
                if "error" in final_resp:
                    error_obj = final_resp["error"]
                    error_msg = error_obj.get("message", "Unknown error")
                    error_data = error_obj.get("data", "")
                    response_text = f"❌ <b>ACP Error:</b>\n<code>{html.escape(error_msg)}</code>"
                    if error_data:
                        response_text += f"\n\n<b>Detail:</b>\n<code>{html.escape(json.dumps(error_data, indent=2))}</code>"
                
                log_phase("ACP Prompt completed and usage extracted")
            finally:
                client.stop_listening(f"msg_{update.effective_message.id}")

            # 🆔 Persistent Session Locking - already handled in _get_acp_client
            
            shot = self.workspace_dir / "screenshot.png"
            if shot.exists() and shot.stat().st_mtime > session_start:
                if status_msg: await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=status_msg.message_id, text="👀 Analyzing screen...")
                log_phase("Vision analysis start")
                response_text = await self.get_vision_analysis(user_text, shot)
                await context.bot.send_photo(chat_id=update.effective_chat.id, photo=open(shot, 'rb'))
                log_phase("Vision completed")

            # --- Unified Logging Strategy ---
            today_str = datetime.date.today().isoformat()
            log_content = f"### [{datetime.datetime.now().strftime('%H:%M:%S')}] 老兵: {user_text}\n{self.name.capitalize()}: {response_text}\n\n"
            
            # 1. System Raw Log (Audit)
            system_log = self.log_dir / f"{today_str}.md"
            with open(system_log, "a", encoding="utf-8") as f: f.write(log_content)
            
            # 2. AI Memory (Retrievable by AI in its workspace)
            # We keep this as a dedicated folder for AI to "discover" its history
            workspace_memory_dir = self.workspace_dir / "memory"
            workspace_memory_dir.mkdir(exist_ok=True)
            workspace_log = workspace_memory_dir / f"{today_str}.md"
            with open(workspace_log, "a", encoding="utf-8") as f: f.write(log_content)

            self.memory_data.append({"text": f"老兵: {user_text}\n{self.name.capitalize()}: {response_text}", "timestamp": datetime.datetime.now().isoformat()})
            self._save_memory()
            log_phase("Logs and memory updated")

            # 7. Render and Send (Smart Split)
            final_html = smart_format_render(response_text) + usage_footer
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
    from telegram.request import HTTPXRequest
    
    # Advanced network settings for unstable connections
    t_request = HTTPXRequest(
        connect_timeout=60.0,
        read_timeout=60.0,
        write_timeout=60.0,
        pool_timeout=60.0,
    )

    bot_configs = {k.replace("_BOT_TOKEN", "").lower(): v for k, v in os.environ.items() if k.endswith("_BOT_TOKEN")}
    if not bot_configs: return
    print(f"--- Starting Native Session Bridge (Bots: {len(bot_configs)}) ---")
    apps = []
    for name, token in bot_configs.items():
        instance = GeminiBotInstance(name, token)
        app = ApplicationBuilder().token(token).request(t_request).build()
        app.add_handler(MessageHandler(filters.TEXT, instance.handle_message))
        app.add_handler(CallbackQueryHandler(instance.handle_callback))
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
