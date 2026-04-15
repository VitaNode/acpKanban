import asyncio
import json
import uuid
import re
from pathlib import Path
from typing import Dict, Any, Optional, Callable, Set
from src.logic.engine import SessionEngine, SessionState, SummaryService
from src.persistence.database import KanbanDB
from src.logic.context import ContextBuilder
from src.protocol.ag_ui_mapper import AGUIMapper
from src.config.manager import config
from src.logger import setup_logger, set_request_id
from src.transport.bus import bus

logger = setup_logger("Dispatcher")

class CommandRegistry:
    def __init__(self):
        self._commands: Dict[str, Callable] = {}
    def register(self, name: str, handler: Callable):
        self._commands[name] = handler
    def get_handler(self, text: str) -> Optional[Callable]:
        if not text or not text.startswith("/"): return None
        cmd_name = text.split()[0].lower()
        return self._commands.get(cmd_name)

class TaskRegistry:
    def __init__(self):
        self._tasks: Dict[str, asyncio.Task] = {}
    def add(self, key: str, task: asyncio.Task):
        self._tasks[key] = task
    def remove(self, key: str):
        self._tasks.pop(key, None)
    async def cancel_all(self):
        if not self._tasks: return
        for t in self._tasks.values(): t.cancel()
        await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        self._tasks.clear()

class MessageDispatcher:
    def __init__(self, db: KanbanDB, ui_requests: Optional[Dict[str, asyncio.Future]] = None):
        self.db = db
        self.context_builder = ContextBuilder(db)
        self.summary_service = SummaryService(db)
        self.engines: Dict[str, SessionEngine] = {}
        self.commands = CommandRegistry()
        self.tasks = TaskRegistry()
        self._setup_local_commands()
        self._engine_creation_locks: Dict[str, asyncio.Lock] = {}
        self._internal_sessions: Set[str] = set()
        self._pending_ui_requests = ui_requests if ui_requests is not None else {}

    def _setup_local_commands(self):
        self.commands.register("/status", self._handle_status_cmd)
        self.commands.register("/reset", self._handle_reset_cmd)
        self.commands.register("/summarize", self._handle_summarize_cmd)
        self.commands.register("/help", self._handle_help_cmd)

    def _get_available_commands(self):
        return [
            {"name": "summarize", "description": "Generate an immediate summary of progress."},
            {"name": "reset", "description": "Reset the AI session."},
            {"name": "status", "description": "Show AI engine status."},
            {"name": "help", "description": "List all commands."}
        ]

    async def _advertise_commands(self, session_id: str, on_output: Callable):
        # Phase 5.1: Advertise to UI via standard notification
        notif = {
            "jsonrpc": "2.0", "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "available_commands_update",
                    "availableCommands": self._get_available_commands()
                }
            }
        }
        await on_output(notif)
        # Also publish via bus for API-level subscribers
        bus.publish(session_id, {"type": "available_commands", "commands": self._get_available_commands()})

    async def dispatch(self, data: Dict[str, Any], on_output: Callable) -> Optional[Dict[str, Any]]:
        method = data.get("method")
        params = data.get("params", {})
        request_id = data.get("id")

        # Handle initialize request
        if method == "initialize":
            return {
                "protocolVersion": 1,
                "agentCapabilities": {
                    "tools": {"supported": True},
                    "resources": {"supported": True}
                },
                "agentInfo": {
                    "name": "Kanban-Bridge",
                    "title": "Agent Kanban Bridge",
                    "version": "1.0.0"
                }
            }

        if method == "cards/move":
            cid = params.get("id"); tid = params.get("target_column_id")
            if cid and tid:
                async def trigger():
                    card = await asyncio.to_thread(self.db.cards.get_by_id, cid)
                    target = await asyncio.to_thread(self.db.columns.get_by_id, tid)
                    if card and target:
                        source = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
                        await self.summary_service.summarize_move(cid, source["name"] if source else "Manual", target["name"])
                asyncio.create_task(trigger())

        ui_format = params.get("ui_format", "acp")

        async def wrapped_notification(notif_data):
            """Send notification via on_output WITHOUT waiting for a response."""
            # Notifications are fire-and-forget. Only actual UI requests (permissions, fs access)
            # should wait for a response. We use create_task to avoid blocking.
            try:
                result = on_output(notif_data)
                # If it's a coroutine, run it in background without awaiting
                if asyncio.iscoroutine(result):
                    asyncio.create_task(result)
            except TypeError:
                try:
                    result = on_output(notif_data.get("method", "notification"), notif_data.get("params", {}))
                    if asyncio.iscoroutine(result):
                        asyncio.create_task(result)
                except Exception:
                    pass

        async def wrapped_request(method, req_params):
            """Send a UI request that requires a response from the UI."""
            return await on_output(method, req_params)

        async def wrapped_output(output_data, is_request=False):
            if ui_format == "ag_ui":
                mapped = AGUIMapper.map_notification(output_data)
                if not mapped: return
                if is_request:
                    return await wrapped_request(mapped.get("method"), mapped.get("params", {}))
                else:
                    return await wrapped_notification(mapped)
            else:
                if is_request:
                    return await wrapped_request(output_data.get("method"), output_data.get("params", {}))
                else:
                    return await wrapped_notification(output_data)

        if method in ("chat/message", "session/prompt"):
            prompt_text = params.get("message") or params.get("prompt")
            if isinstance(prompt_text, list):
                prompt_text = " ".join([p.get("text", "") for p in prompt_text if p.get("type") == "text"])
            
            file_refs = re.findall(r"@([\w\.\-/]+)", prompt_text)
            if file_refs:
                if "prompt" not in params: params["prompt"] = [{"type": "text", "text": prompt_text}]
                workspace_root = Path(config.get("system.workspace_root")).resolve()
                for ref in file_refs:
                    try:
                        ref_path = (workspace_root / ref).resolve()
                        if workspace_root in ref_path.parents or workspace_root == ref_path:
                            if ref_path.exists() and ref_path.is_file():
                                with open(ref_path, 'r', encoding='utf-8') as f:
                                    params["prompt"].append({"type": "resource", "resource": {"uri": f"file://{ref}", "text": f.read(), "mimeType": "text/plain"}})
                    except: pass

            handler = self.commands.get_handler(prompt_text)
            if handler: return await handler(params, request_id)

        card_id = params.get("card_id")
        if card_id and method in ("chat/message", "session/prompt"):
            session_id = params.get("sessionId")
            is_internal = session_id in self._internal_sessions
            if not is_internal:
                prompt_text = params.get("message") or params.get("prompt")
                if isinstance(prompt_text, list):
                    prompt_text = " ".join([p.get("text", "") for p in prompt_text if p.get("type") == "text"])
                await asyncio.to_thread(self.db.sessions.add_message, card_id, "user", prompt_text)
                bus.publish(card_id, {"type": "refresh"})

            task_key = f"{card_id}_{request_id}"
            task = asyncio.create_task(self._process_engine_request(card_id, method, params, request_id, wrapped_output))
            self.tasks.add(task_key, task)
            return {"status": "submitted", "card_id": card_id}
        
        return {"error": {"code": -32601, "message": f"Method {method} not handled"}}

    async def _get_or_create_engine(self, card_id: str, on_nested_request: Optional[Callable] = None, on_output: Optional[Callable] = None) -> (SessionEngine, bool):
        if card_id in self.engines and self.engines[card_id].is_alive:
            engine = self.engines[card_id]
            # Phase 6: Always update callback to current WebSocket context
            if on_nested_request:
                engine.set_on_request(on_nested_request)
            
            # Re-push config options if engine already exists (e.g., after reconnect)
            if engine.acp_session_id and engine.current_config_options and on_output:
                bus.publish(card_id, {"type": "config_options", "options": engine.current_config_options})
            return engine, False
        if card_id not in self._engine_creation_locks: self._engine_creation_locks[card_id] = asyncio.Lock()
        async with self._engine_creation_locks[card_id]:
            card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
            if not card: raise ValueError(f"Card {card_id} not found")
            column = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
            provider_id = column.get("acp_provider_id") or card.get("acp_provider_id") or config.default_provider
            workspace_path = config.get("system.workspace_root")
            project = await asyncio.to_thread(self.db.projects.get_by_id, column["project_id"])
            if project and project.get("workspace_path"): workspace_path = project["workspace_path"]
            engine = SessionEngine(card_id, provider_id, workspace_path, card["column_id"], db=self.db)
            engine.acp_session_id = card.get("acp_session_id")
            await engine.start(on_request=on_nested_request)
            self.engines[card_id] = engine
            if engine.acp_session_id and on_output:
                await self._advertise_commands(engine.acp_session_id, on_output)
                if engine.current_config_options:
                    bus.publish(card_id, {"type": "config_options", "options": engine.current_config_options})
            return engine, True

    def _is_safe_path(self, workspace_root: Path, target_path: str) -> bool:
        """Strict sandbox check for fs operations."""
        try:
            resolved = (workspace_root / target_path).resolve()
            return workspace_root in resolved.parents or workspace_root == resolved
        except:
            return False

    async def _process_engine_request(self, card_id, method, params, request_id, on_output):
        task_key = f"{card_id}_{request_id}"
        session_id = params.get("sessionId")
        is_internal = session_id in self._internal_sessions
        try:
            async def handle_nested_request(inner_method, inner_params):
                logger.info(f"[*] Nested request from engine for card {card_id}: {inner_method}")
                if inner_method == "session/request_permission":
                    inner_params["card_id"] = card_id

                    # YOLO 模式：检查列的 approval_mode，自动放行权限请求
                    engine = self.engines.get(card_id)
                    if engine and engine.column_id:
                        column = await asyncio.to_thread(self.db.columns.get_by_id, engine.column_id)
                        if column and column.get("approval_mode") == "yolo":
                            logger.info(f"[*] YOLO mode detected for card {card_id}, auto-approving permission.")
                            return {"outcome": {"optionId": "allow"}}

                    # Not YOLO: forward to Flutter UI for user approval
                    rid = str(uuid.uuid4())
                    fut = asyncio.get_event_loop().create_future()
                    self._pending_ui_requests[rid] = fut
                    logger.info(f"[*] Forwarding session/request_permission to UI (rid: {rid}, card_id: {card_id})")
                    bus.publish(card_id, {
                        "type": "ui_request",
                        "id": rid,
                        "method": inner_method,
                        "params": inner_params
                    })
                    try:
                        res = await asyncio.wait_for(fut, timeout=300.0)
                        logger.info(f"[*] UI Response received for {rid}: {res}")
                        return res
                    except asyncio.TimeoutError:
                        self._pending_ui_requests.pop(rid, None)
                        logger.warning(f"[*] UI Request Timeout for {rid}")
                        return {"error": {"code": -32000, "message": "UI Request Timeout"}}

                if inner_method.startswith("fs/") or inner_method.startswith("terminal/"):
                    inner_params["_request_id"] = inner_params.get("id")
                    result = await on_output({"jsonrpc": "2.0", "method": inner_method, "params": inner_params}, is_request=True)
                    return result

                return await on_output({"jsonrpc": "2.0", "method": inner_method, "params": inner_params}, is_request=True)

            engine, is_new = await self._get_or_create_engine(card_id, on_nested_request=handle_nested_request, on_output=on_output)
            if is_new or not engine.acp_session_id:
                # Serial: wait for context injection to complete before processing user prompt.
                # This prevents concurrent prompt collision on the same ACP session.
                await self._inject_context_async(card_id, engine, on_output)

            async def forward_notif(n):
                if "params" in n: n["params"]["card_id"] = card_id
                if is_internal: await on_output(n); return
                await self._forward_notification(card_id, n, on_output)

            await engine.process_prompt(method, params, on_notification=forward_notif)
            if engine.acp_session_id != params.get("acp_session_id"): await asyncio.to_thread(self.db.cards.update_card_session_id, card_id, engine.acp_session_id)
            # Mark assistant response as complete so Flutter stops showing "AI is thinking..."
            await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", "", True)
            bus.publish(card_id, {"type": "refresh"})
        except Exception as e:
            logger.error(f"Engine error: {e}")
            await on_output({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(e)}})
        finally: self.tasks.remove(task_key)

    async def _inject_context_async(self, card_id: str, engine: SessionEngine, on_output: Optional[Callable] = None):
        if not engine.is_alive or not engine.acp_session_id:
            return

        # 获取列的 prompt_template
        column_prompt = None
        if engine.column_id:
            column = await asyncio.to_thread(self.db.columns.get_by_id, engine.column_id)
            if column:
                column_prompt = column.get("prompt_template")

        context = await self.context_builder.build_initial_context(card_id, column_prompt=column_prompt)

        # 用真实的 ACP sessionId 注入 context
        await engine.process_prompt("session/prompt", {
            "sessionId": engine.acp_session_id,
            "prompt": [{"type": "text", "text": f"[SYSTEM CONTEXT]\n{context}\n\nPlease acknowledge."}]
        }, on_notification=on_output)

    async def _forward_notification(self, card_id, n, on_output):
        """Shared notification forwarding logic for both user and system prompts."""
        method = n.get("method")
        params = n.get("params", {})
        update = params.get("update", {})
        utype = update.get("sessionUpdate")

        # Support multiple chunk formats
        chunk_text = ""
        if utype == "agent_message_chunk":
            chunk_text = update.get("content", {}).get("text", "")
        elif utype == "content_block_delta":
            delta = update.get("delta", {})
            if isinstance(delta, dict):
                chunk_text = delta.get("text", "")
        elif utype == "agent_thought_chunk":
            # Forward thought chunks for display (debugging/transparency)
            thought_text = update.get("content", {}).get("text", "")
            if thought_text:
                bus.publish(card_id, {"type": "agent_thought_chunk", "content": update.get("content", {})})
        elif method == "_qwencode/slash_command":
            chunk_text = params.get("message", "")

        if chunk_text:
            await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", chunk_text, False)
            bus.publish(card_id, {"type": "agent_message_chunk", "content": {"text": chunk_text}})
        elif utype == "plan":
            bus.publish(card_id, {"type": "agent_plan", "plan": {"entries": update.get("entries", [])}})
        elif utype == "config_option_update":
            bus.publish(card_id, {"type": "config_options", "options": update.get("availableOptions", [])})
        elif utype == "tool_call":
            tcid = update.get("toolCallId")
            status = update.get("status", "pending")
            title = update.get("title") or f"Tool: {update.get('tool', 'unknown')}"
            if status == "pending":
                await asyncio.to_thread(self.db.sessions.add_message, card_id, "assistant", f"🛠️ **{title}**", {"type": "tool_call", "toolCallId": tcid, "status": "pending"})
            else:
                is_complete = status in ["completed", "failed"]
                await asyncio.to_thread(self.db.sessions.update_message_with_metadata, card_id, "toolCallId", tcid, f"🛠️ **{title}**", is_complete)
            bus.publish(card_id, {"type": "refresh"})
        elif utype == "tool_call_update":
            tcid = update.get("toolCallId")
            status = update.get("status")
            is_complete = status in ["completed", "failed"]
            await asyncio.to_thread(self.db.sessions.update_message_with_metadata, card_id, "toolCallId", tcid, None, is_complete)
            bus.publish(card_id, {"type": "refresh"})
        elif utype == "session_info_update":
            info = update.get("info", {})
            if info:
                await asyncio.to_thread(self.db.cards.update_card, card_id, title=info.get("title"), description=info.get("description"))
                bus.publish(card_id, {"type": "refresh"})
        elif utype == "stop":
            await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", "", True)
            bus.publish(card_id, {"type": "refresh"})

        # NOTE: Do NOT await on_output(n) here. Notifications are fire-and-forget.
        # Blocking here causes the notification pipeline to stall, as on_output
        # eventually calls on_ui_request which waits up to 300s for a UI response.
        # Actual UI requests (permissions, fs access) are handled via wrapped_request.

    async def handle_set_config_option(self, card_id: str, config_id: str, value: Any):
        engine, _ = await self._get_or_create_engine(card_id)
        new_options = await engine.set_config_option(config_id, value)
        if new_options: bus.publish(card_id, {"type": "config_options", "options": new_options})
        return new_options

    async def _handle_status_cmd(self, p, rid): return {"message": f"Engines active: {len(self.engines)}"}
    async def _handle_summarize_cmd(self, p, rid):
        cid = p.get("card_id")
        if not cid: return {"error": "Missing card_id"}
        asyncio.create_task(self.summary_service.summarize_move(cid, "Manual", "Current"))
        return {"message": "Summary task started."}
    async def _handle_reset_cmd(self, p, rid):
        cid = p.get("card_id")
        if cid in self.engines: await self.engines[cid].stop(); del self.engines[cid]
        await asyncio.to_thread(self.db.cards.update_card_session_id, cid, None)
        return {"message": "Reset complete."}
    async def _handle_help_cmd(self, p, rid):
        return {"message": "Available:\n" + "\n".join([f"- `/{c['name']}`: {c['description']}" for c in self._get_available_commands()])}
    async def shutdown(self):
        await self.tasks.cancel_all()
        await asyncio.gather(*[eng.stop() for eng in self.engines.values()], return_exceptions=True)
