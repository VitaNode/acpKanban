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
        self._setup_handlers()
        self._engine_creation_locks: Dict[str, asyncio.Lock] = {}
        self._internal_sessions: Set[str] = set()
        self._pending_ui_requests = ui_requests if ui_requests is not None else {}
        self._current_turn_usage: Dict[str, Dict[str, int]] = {} # card_id -> {"input": 0, "output": 0}
        
        # AG-UI Buffer Layer (Phase 1)
        self._seq_counters: Dict[str, int] = {}  # card_id -> next seqId
        self._chunk_buffers: Dict[str, list] = {}  # card_id -> list of chunks
        self._flush_timers: Dict[str, asyncio.TimerHandle] = {}  # card_id -> timer handle
        self._flush_locks: Dict[str, asyncio.Lock] = {}  # card_id -> flush lock
        self._card_ui_formats: Dict[str, str] = {}  # card_id -> "acp" or "ag_ui"
        
        # AG-UI Configuration
        self._ag_ui_flush_interval_ms = 500  # Time-based flush trigger
        self._ag_ui_buffer_capacity = 20  # Capacity-based flush trigger (chunks)

    def _setup_local_commands(self):
        self.commands.register("/status", self._handle_status_cmd)
        self.commands.register("/reset", self._handle_reset_cmd)
        self.commands.register("/summarize", self._handle_summarize_cmd)
        self.commands.register("/help", self._handle_help_cmd)

    def _setup_handlers(self):
        self._handlers = {
            "initialize": self._handle_initialize,
            "kanban/progress/get": self._handle_get_progress,
            "kanban/milestone/create": self._handle_create_milestone,
            "kanban/milestone/update": self._handle_update_milestone,
            "kanban/milestone/delete": self._handle_delete_milestone,
            "kanban/feature/create": self._handle_create_feature,
            "kanban/feature/update": self._handle_update_feature,
            "kanban/feature/delete": self._handle_delete_feature,
            "kanban/card/create": self._handle_create_card,
            "kanban/card/update": self._handle_update_card,
            "cards/move": self._handle_card_move,
        }

    async def _handle_initialize(self, params, rid):
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

    async def _handle_get_progress(self, params, rid):
        pid = params.get("project_id")
        depth = params.get("depth", 3)
        if not pid: return {"error": "Missing project_id"}
        stats = await asyncio.to_thread(self.db.get_project_progress, pid)
        
        if depth == 1:
            for m in stats: m['features'] = []
        elif depth == 2:
            for m in stats:
                for f in m['features']: f['cards'] = []
        return stats

    async def _handle_create_milestone(self, params, rid):
        pid = params.get("project_id"); title = params.get("title")
        if not pid or not title: return {"error": "Missing project_id or title"}
        m_id = await asyncio.to_thread(self.db.create_milestone, pid, title, params.get("description"), params.get("target_date"))
        return {"id": m_id}

    async def _handle_update_milestone(self, params, rid):
        mid = params.get("milestone_id")
        if not mid: return {"error": "Missing milestone_id"}
        await asyncio.to_thread(self.db.update_milestone, mid, params.get("title"), params.get("description"), params.get("status"), params.get("target_date"))
        return {"status": "ok"}

    async def _handle_delete_milestone(self, params, rid):
        mid = params.get("milestone_id")
        if not mid: return {"error": "Missing milestone_id"}
        await asyncio.to_thread(self.db.delete_milestone, mid)
        return {"status": "ok"}

    async def _handle_create_feature(self, params, rid):
        mid = params.get("milestone_id"); title = params.get("title")
        if not mid or not title: return {"error": "Missing milestone_id or title"}
        fid = await asyncio.to_thread(self.db.create_feature, mid, title, params.get("description"))
        return {"id": fid}

    async def _handle_update_feature(self, params, rid):
        fid = params.get("feature_id")
        if not fid: return {"error": "Missing feature_id"}
        await asyncio.to_thread(self.db.update_feature, fid, params.get("title"), params.get("description"), params.get("status"))
        return {"status": "ok"}

    async def _handle_delete_feature(self, params, rid):
        fid = params.get("feature_id")
        if not fid: return {"error": "Missing feature_id"}
        await asyncio.to_thread(self.db.delete_feature, fid)
        return {"status": "ok"}

    async def _handle_create_card(self, params, rid):
        col_id = params.get("column_id"); title = params.get("title")
        if not col_id or not title: return {"error": "Missing column_id or title"}
        cid = await asyncio.to_thread(self.db.create_card, col_id, title, params.get("description"), feature_id=params.get("feature_id"))
        return {"id": cid}

    async def _handle_update_card(self, params, rid):
        cid = params.get("card_id")
        if not cid: return {"error": "Missing card_id"}
        await asyncio.to_thread(self.db.update_card, cid, params.get("title"), params.get("description"), feature_id=params.get("feature_id"))
        return {"status": "ok"}

    async def _handle_card_move(self, params, rid):
        cid = params.get("id"); tid = params.get("target_column_id")
        if not cid or not tid: return {"error": "Missing id or target_column_id"}
        
        async def trigger():
            card = await asyncio.to_thread(self.db.cards.get_by_id, cid)
            target = await asyncio.to_thread(self.db.columns.get_by_id, tid)
            if card and target:
                source = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
                await self.summary_service.summarize_move(cid, source["name"] if source else "Manual", target["name"])
        
        asyncio.create_task(trigger())
        return {"status": "ok"}

    def _get_available_commands(self, card_id: Optional[str] = None):
        system_cmds = [
            {"name": "summarize", "description": "Generate an immediate summary of progress."},
            {"name": "reset", "description": "Reset the AI session."},
            {"name": "status", "description": "Show AI engine status."},
            {"name": "help", "description": "List all commands."}
        ]
        
        if not card_id or card_id not in self.engines:
            return system_cmds
            
        engine = self.engines[card_id]
        agent_cmds = engine.available_commands if hasattr(engine, 'available_commands') else []
        
        # Merge and deduplicate by name
        seen = {cmd['name'] for cmd in system_cmds}
        merged = list(system_cmds)
        for cmd in agent_cmds:
            if cmd['name'] not in seen:
                merged.append(cmd)
                seen.add(cmd['name'])
        
        return merged

    async def _advertise_commands(self, session_id: str, on_output: Optional[Callable] = None, card_id: Optional[str] = None):
        # Phase 5.1: Advertise to UI via standard notification
        cmds = self._get_available_commands(card_id)
        logger.info(f"[*] Advertising {len(cmds)} commands for card {card_id or 'N/A'} (session: {session_id[:8]})")
        notif = {
            "jsonrpc": "2.0", "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "available_commands_update",
                    "availableCommands": cmds
                }
            }
        }
        
        if on_output:
            try:
                res = on_output(notif)
                if asyncio.iscoroutine(res):
                    await res
            except Exception:
                pass
                
        # Also publish via bus for API-level subscribers
        bus.publish(card_id or session_id, {"type": "available_commands", "commands": cmds})

    def _extract_and_update_tokens(self, data: Dict[str, Any], card_id: str):
        """Extract tokens from various agent formats and update the database."""
        if not card_id or not isinstance(data, dict):
            return

        # VERY LOUD DEBUG
        logger.info(f"[TOKEN DEBUG] Analyzing data for {card_id}: keys={list(data.keys())}")

        in_val = 0
        out_val = 0

        # Check in result (RPC response)
        result = data.get("result") if isinstance(data.get("result"), dict) else {}
        usage = result.get("usage") or data.get("usage") or {}
        meta = result.get("_meta") or data.get("_meta") or {}

        # 1. OpenCode/Common format: usage.inputTokens / usage.outputTokens
        if usage:
            in_val = usage.get("inputTokens", 0) or usage.get("input_tokens", 0)
            out_val = usage.get("outputTokens", 0) or usage.get("output_tokens", 0)
            # Add support for 'used' field seen in some adapters/logs
            if in_val == 0 and "used" in usage:
                in_val = usage.get("used", 0)
        
        # Check direct fields (for usage_update notifications or flat results)
        if in_val == 0 and "used" in data:
            in_val = data.get("used", 0)
        if in_val == 0 and "inputTokens" in data:
            in_val = data.get("inputTokens", 0)
        if out_val == 0 and "outputTokens" in data:
            out_val = data.get("outputTokens", 0)
        
        # 2. Gemini/Qwen format in meta
        if meta:
            # Gemini quota
            quota = meta.get("quota", {})
            tc = quota.get("token_count", {})
            if tc:
                in_val = max(in_val, tc.get("input_tokens", 0))
                out_val = max(out_val, tc.get("output_tokens", 0))
            
            # Qwen/Common usage in meta
            q_usage = meta.get("usage", {})
            if q_usage:
                in_val = max(in_val, q_usage.get("inputTokens", 0) or q_usage.get("input_tokens", 0))
                out_val = max(out_val, q_usage.get("outputTokens", 0) or q_usage.get("output_tokens", 0))

        if in_val > 0 or out_val > 0:
            # Use delta-based updates to handle cumulative usage reporting in chunks
            if not hasattr(self, '_current_turn_usage'):
                self._current_turn_usage = {}
            
            turn_usage = self._current_turn_usage.get(card_id, {"input": 0, "output": 0})
            delta_in = max(0, in_val - turn_usage["input"])
            delta_out = max(0, out_val - turn_usage["output"])

            if delta_in > 0 or delta_out > 0:
                logger.info(f"[*] Token Usage Update for {card_id}: +↑{delta_in} +↓{delta_out} (Current turn: ↑{in_val} ↓{out_val})")
                try:
                    self.db.update_card_token_usage(card_id, delta_in, delta_out)
                    # Update turn state
                    self._current_turn_usage[card_id] = {"input": in_val, "output": out_val}
                    
                    # Publish latest totals to bus
                    card = self.db.get_card(card_id)
                    if card:
                        bus.publish(card_id, {
                            "type": "token_update",
                            "input_tokens": card.get("input_tokens", 0),
                            "output_tokens": card.get("output_tokens", 0)
                        })
                except Exception as e:
                    logger.error(f"Failed to update token usage: {e}")
        else:
            # Debug: what did we see?
            if any(k in data for k in ["used", "usage", "_meta", "inputTokens"]):
                logger.debug(f"DEBUG: Found possible usage data but values are zero: {data}")

    async def dispatch(self, data: Dict[str, Any], on_output: Callable) -> Optional[Dict[str, Any]]:
        method = data.get("method")
        params = data.get("params", {})
        request_id = data.get("id")

        # Reset turn usage on new prompt to avoid double counting across turns
        if method == "session/prompt":
            card_id = params.get("card_id")
            if card_id:
                if not hasattr(self, '_current_turn_usage'):
                    self._current_turn_usage = {}
                self._current_turn_usage[card_id] = {"input": 0, "output": 0}

        # Use registered handlers first
        if method in self._handlers:
            return await self._handlers[method](params, request_id)

        ui_format = params.get("ui_format", "acp")
        
        # Store ui_format for this card (for use in _forward_notification)
        card_id_for_format = params.get("card_id")
        if card_id_for_format:
            self._card_ui_formats[card_id_for_format] = ui_format

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
            prompt_data = params.get("message") or params.get("prompt")
            prompt_text = ""
            if isinstance(prompt_data, list):
                prompt_text = " ".join([p.get("text", "") for p in prompt_data if p.get("type") == "text"])
            elif isinstance(prompt_data, str):
                prompt_text = prompt_data
            
            file_refs = re.findall(r"@([\w\.\-/]+)", prompt_text)
            if file_refs:
                if "prompt" not in params: 
                    params["prompt"] = [{"type": "text", "text": prompt_text, "content": prompt_text}]
                workspace_root = Path(config.get("system.workspace_root")).resolve()
                for ref in file_refs:
                    try:
                        if self._is_safe_path(workspace_root, ref):
                            ref_path = (workspace_root / ref).resolve()
                            if ref_path.exists() and ref_path.is_file():
                                with open(ref_path, 'r', encoding='utf-8') as f:
                                    params["prompt"].append({"type": "resource", "resource": {"uri": f"file://{ref}", "text": f.read(), "mimeType": "text/plain"}})
                    except: pass

            handler = self.commands.get_handler(prompt_text)
            if handler:
                logger.info(f"[*] Executing local command: {prompt_text} (rid: {request_id})")
                card_id = params.get("card_id")
                if card_id:
                    # Record the command in history
                    await asyncio.to_thread(self.db.sessions.add_message, card_id, "user", prompt_text)
                
                result = await handler(params, request_id)
                
                if card_id and isinstance(result, dict) and "message" in result:
                    # Record the response in history and trigger UI refresh to clear "Agent is working"
                    await asyncio.to_thread(self.db.sessions.add_message, card_id, "assistant", result["message"], is_complete=True)
                    bus.publish(card_id, {"type": "refresh"})
                
                return result

        card_id = params.get("card_id")
        if card_id and method in ("chat/message", "session/prompt"):
            logger.info(f"[*] Processing AI prompt for card {card_id} (rid: {request_id})")
            session_id = params.get("sessionId")
            is_internal = session_id in self._internal_sessions
            if not is_internal:
                prompt_text = params.get("message") or params.get("prompt")
                if isinstance(prompt_text, list):
                    prompt_text = " ".join([p.get("text", "") for p in prompt_text if p.get("type") == "text"])
                await asyncio.to_thread(self.db.sessions.add_message, card_id, "user", prompt_text)
                bus.publish(card_id, {"type": "refresh"})
                
                # Phase 7: Immediate "Thinking" feedback
                bus.publish(card_id, {"type": "agent_thought_chunk", "content": {"text": "..."}})

            task_key = f"{card_id}_{request_id}"
            task = asyncio.create_task(self._process_engine_request(card_id, method, params, request_id, wrapped_output))
            self.tasks.add(task_key, task)
            return {"status": "submitted", "card_id": card_id}
        
        return {"error": {"code": -32601, "message": f"Method {method} not handled"}}

    async def _get_or_create_engine(self, card_id: str, on_nested_request: Optional[Callable] = None, on_output: Optional[Callable] = None, is_quiet: bool = False) -> (SessionEngine, bool):
        card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
        if not card: raise ValueError(f"Card {card_id} not found")
        column = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
        target_provider_id = column.get("acp_provider_id") or card.get("acp_provider_id") or config.default_provider

        # Define a persistent notification handler for this card
        async def stable_notif_handler(n):
            if "params" in n:
                n["params"]["card_id"] = card_id
            
            # Get ui_format for this card (default to "acp")
            card_ui_format = self._card_ui_formats.get(card_id, "acp")
            
            # ALWAYS forward to logic, even if on_output is None
            # This ensures bus.publish is called for background events
            await self._forward_notification(card_id, n, on_output, ui_format=card_ui_format)

        # Phase 5.3 FIX: Check if cached engine exists and matches the target provider
        if card_id in self.engines:
            existing_engine = self.engines[card_id]
            if existing_engine.is_alive:
                if existing_engine.provider_id == target_provider_id:
                    # Provider matches, reuse engine
                    if on_nested_request:
                        existing_engine.set_on_request(on_nested_request)
                    if on_output:
                        existing_engine.set_on_notification(stable_notif_handler)
                    
                    if existing_engine.acp_session_id and on_output:
                        # Always advertise commands on connection to ensure UI is in sync
                        await self._advertise_commands(existing_engine.acp_session_id, on_output, card_id=card_id)
                        if existing_engine.current_config_options:
                            bus.publish(card_id, {"type": "config_options", "options": existing_engine.current_config_options})
                    return existing_engine, False
                else:
                    # Provider mismatch! Stop the old engine to ensure isolation
                    logger.info(f"[*] Provider changed ({existing_engine.provider_id} -> {target_provider_id}) for card {card_id}. Recreating engine...")
                    await existing_engine.stop()
                    self.engines.pop(card_id, None)

        if card_id not in self._engine_creation_locks: self._engine_creation_locks[card_id] = asyncio.Lock()
        async with self._engine_creation_locks[card_id]:
            workspace_path = config.get("system.workspace_root")
            project = await asyncio.to_thread(self.db.projects.get_by_id, column["project_id"])
            if project and project.get("workspace_path"): workspace_path = project["workspace_path"]
            engine = SessionEngine(card_id, target_provider_id, workspace_path, card["column_id"], db=self.db)
            engine.acp_session_id = card.get("acp_session_id")
            await engine.start(on_request=on_nested_request, on_notification=stable_notif_handler, is_quiet=is_quiet)
            self.engines[card_id] = engine
            if engine.acp_session_id and on_output:
                await self._advertise_commands(engine.acp_session_id, on_output, card_id=card_id)
                if engine.current_config_options:
                    bus.publish(card_id, {"type": "config_options", "options": engine.current_config_options})
            return engine, True

    def _is_safe_path(self, workspace_root: Path, target_path: str) -> bool:
        """Strict sandbox check for fs operations."""
        try:
            # Join and resolve to absolute paths
            workspace_root = workspace_root.resolve()
            target_abs = (workspace_root / target_path).resolve()
            
            # check if target_abs is under workspace_root
            return workspace_root == target_abs or workspace_root in target_abs.parents
        except Exception:
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
            # if is_new or not engine.acp_session_id:
            #     # Serial: wait for context injection to complete before processing user prompt.
            #     # This prevents concurrent prompt collision on the same ACP session.
            #     await self._inject_context_async(card_id, engine, on_output)

            async def forward_notif(n):
                if "params" in n: n["params"]["card_id"] = card_id
                if is_internal: await on_output(n); return
                card_ui_format = self._card_ui_formats.get(card_id, "acp")
                await self._forward_notification(card_id, n, on_output, ui_format=card_ui_format)

            res = await engine.process_prompt(method, params, on_notification=forward_notif)

            # Extract tokens from the final prompt result
            if isinstance(res, dict):
                self._extract_and_update_tokens(res, card_id)

            if engine.acp_session_id != params.get("acp_session_id"):
                await asyncio.to_thread(self.db.update_card_session_id, card_id, engine.acp_session_id)
            
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

    async def _forward_notification(self, card_id, n, on_output: Optional[Callable] = None, ui_format: str = "acp"):
        """Shared notification forwarding logic for both user and system prompts."""
        if isinstance(n, dict):
            self._extract_and_update_tokens(n, card_id)
            if "params" in n and isinstance(n["params"], dict):
                self._extract_and_update_tokens(n["params"], card_id)
                if "update" in n["params"] and isinstance(n["params"]["update"], dict):
                    self._extract_and_update_tokens(n["params"]["update"], card_id)

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
                await asyncio.to_thread(self.db.append_thought, card_id, thought_text)
                bus.publish(card_id, {"type": "agent_thought_chunk", "content": update.get("content", {})})
        elif method == "_qwencode/slash_command":
            chunk_text = params.get("message", "")

        # AG-UI Buffer Layer: Buffer chunks instead of immediate dispatch
        if ui_format == "ag_ui" and chunk_text:
            # Map to AG-UI event and buffer
            ag_event = AGUIMapper.map_notification(n)
            if ag_event:
                await self._buffer_chunk(card_id, ag_event, on_output)
                # Also persist to DB for history
                await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", chunk_text, False)
            return

        if chunk_text:
            await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", chunk_text, False)
            bus.publish(card_id, {"type": "agent_message_chunk", "content": {"text": chunk_text}})
        elif utype == "plan":
            bus.publish(card_id, {"type": "agent_plan", "plan": {"entries": update.get("entries", [])}})
        elif utype == "config_option_update":
            engine = self.engines.get(card_id)
            if engine:
                # Use engine's normalization logic on the full update dict
                normalized = engine._normalize_session_config(update)
                if normalized:
                    engine.current_config_options = normalized
                    engine._save_config_options_to_db()
                    bus.publish(card_id, {"type": "config_options", "options": normalized})
            else:
                # Fallback if engine not found (less likely but possible)
                new_opts = update.get("availableOptions", [])
                if new_opts:
                    bus.publish(card_id, {"type": "config_options", "options": new_opts})
        elif utype == "available_commands_update":
            engine = self.engines.get(card_id)
            agent_cmds = update.get("availableCommands", [])
            if engine and agent_cmds:
                logger.info(f"[*] Received async command update for card {card_id}: {len(agent_cmds)} commands")
                engine.available_commands = agent_cmds
                engine._save_available_commands_to_db()
                # Re-advertise merged list
                await self._advertise_commands(engine.acp_session_id, on_output, card_id=card_id)
        elif utype == "tool_call":
            tcid = update.get("toolCallId")
            status = update.get("status", "pending")
            title = update.get("title") or f"Tool: {update.get('tool', 'unknown')}"
            
            # Phase 5.3: Integrate tool call into thought trace for end-to-end transparency
            trace_msg = ""
            if status == "pending":
                trace_msg = f"\n\n🛠️ **Calling tool:** `{title}`\n"
            elif status == "completed":
                trace_msg = f"\n✅ **Tool call finished:** `{title}`\n"
            elif status == "failed":
                trace_msg = f"\n❌ **Tool call failed:** `{title}`\n"
                
            if trace_msg:
                await asyncio.to_thread(self.db.append_thought, card_id, trace_msg)
                bus.publish(card_id, {"type": "agent_thought_chunk", "content": {"type": "text", "text": trace_msg}})

            # We no longer add a separate message for tool calls to avoid "message explosion"
            # All tool lifecycle info is now in the thought trace.
            bus.publish(card_id, {"type": "refresh"})
        elif utype == "tool_call_update":
            tcid = update.get("toolCallId")
            status = update.get("status")
            content = update.get("content")
            
            # Extract text from content list if possible
            output_text = None
            if content and isinstance(content, list):
                output_text = "\n".join([c.get("content", {}).get("text", "") for c in content if c.get("type") == "content" and "text" in c.get("content", {})])
            
            # Phase 5.3: Integrate summary of tool result into thought trace
            if output_text and status in ["completed", "failed"]:
                # Deduplicate/Compact: If output is just "Success" or "OK", use a single line
                clean_output = output_text.strip()
                if clean_output in ["Success", "OK", "Success.", "{}"]:
                    trace_msg = f"> Result: {clean_output}\n"
                else:
                    preview = clean_output[:1000] + ("..." if len(clean_output) > 1000 else "")
                    trace_msg = f"\n> **Output:** {preview}\n"
                
                await asyncio.to_thread(self.db.append_thought, card_id, trace_msg)
                bus.publish(card_id, {"type": "agent_thought_chunk", "content": {"type": "text", "text": trace_msg}})

            # We no longer update the "message body" with tool output to avoid redundant info
            bus.publish(card_id, {"type": "refresh"})
        elif utype == "session_info_update":
            info = update.get("info", {})
            if info:
                await asyncio.to_thread(self.db.cards.update_card, card_id, title=info.get("title"), description=info.get("description"))
                bus.publish(card_id, {"type": "refresh"})
        elif utype == "stop":
            await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", "", True)
            # AG-UI: Flush buffer on session stop
            if self._card_ui_formats.get(card_id) == "ag_ui":
                await self._flush_on_event(card_id, "session_stop")
            bus.publish(card_id, {"type": "refresh"})

        # NOTE: Do NOT await on_output(n) here. Notifications are fire-and-forget.
        # Blocking here causes the notification pipeline to stall, as on_output
        # eventually calls on_ui_request which waits up to 300s for a UI response.
        # Actual UI requests (permissions, fs access) are handled via wrapped_request.

    # ==================== AG-UI Buffer Layer (Phase 1) ====================
    
    def _get_next_seq(self, card_id: str) -> int:
        """
        Generate next sequence ID for a session.
        Each card_id maintains its own independent counter.
        
        Args:
            card_id: The card/session identifier
            
        Returns:
            Next sequential ID (1-indexed)
        """
        if card_id not in self._seq_counters:
            self._seq_counters[card_id] = 0
        self._seq_counters[card_id] += 1
        return self._seq_counters[card_id]
    
    def set_ui_format(self, card_id: str, ui_format: str):
        """
        Explicitly set the UI format for a session.
        
        Args:
            card_id: The card/session identifier
            ui_format: "acp" or "ag_ui"
        """
        logger.info(f"[AG-UI] Setting UI format to {ui_format} for card {card_id}")
        self._card_ui_formats[card_id] = ui_format
    
    async def _buffer_chunk(self, card_id: str, chunk: Dict[str, Any], on_output: Optional[Callable] = None):
        """
        Buffer a chunk and schedule flush based on time/capacity triggers.
        
        Args:
            card_id: The card/session identifier
            chunk: The chunk data to buffer
            on_output: Optional callback for immediate dispatch
        """
        if card_id not in self._chunk_buffers:
            self._chunk_buffers[card_id] = []
            self._flush_locks[card_id] = asyncio.Lock()
        
        # Add seqId to chunk
        chunk["seqId"] = self._get_next_seq(card_id)
        self._chunk_buffers[card_id].append(chunk)
        
        logger.debug(f"[AG-UI] Buffered chunk for {card_id}: seqId={chunk['seqId']}, buffer_size={len(self._chunk_buffers[card_id])}")
        
        # Check capacity trigger (immediate flush if buffer is full)
        if len(self._chunk_buffers[card_id]) >= self._ag_ui_buffer_capacity:
            await self._trigger_flush(card_id, "capacity")
            return
        
        # Schedule time-based flush if not already scheduled
        if card_id not in self._flush_timers or self._flush_timers[card_id].cancelled():
            self._flush_timers[card_id] = asyncio.get_event_loop().call_later(
                self._ag_ui_flush_interval_ms / 1000.0,
                lambda: asyncio.create_task(self._trigger_flush(card_id, "timeout"))
            )
    
    async def _trigger_flush(self, card_id: str, reason: str = "manual"):
        """
        Trigger a buffer flush for the given card.
        
        Args:
            card_id: The card/session identifier
            reason: Reason for flush (timeout, capacity, event, manual)
        """
        # Cancel pending timer
        if card_id in self._flush_timers and not self._flush_timers[card_id].cancelled():
            self._flush_timers[card_id].cancel()
        
        await self._flush_buffer(card_id, reason)
    
    async def _flush_buffer(self, card_id: str, reason: str = "manual"):
        """
        Flush buffered chunks to persistent storage.
        
        Args:
            card_id: The card/session identifier
            reason: Reason for flush
        """
        if card_id not in self._flush_locks:
            self._flush_locks[card_id] = asyncio.Lock()
        
        async with self._flush_locks[card_id]:
            buffer = self._chunk_buffers.get(card_id, [])
            if not buffer:
                logger.debug(f"[AG-UI] No chunks to flush for {card_id}")
                return
            
            logger.info(f"[AG-UI] Flushing {len(buffer)} chunks for {card_id} (reason: {reason})")
            
            try:
                # Persist chunks to database
                # TODO: Implement actual persistence logic based on your storage schema
                # For now, we'll just log and clear the buffer
                for chunk in buffer:
                    # Example: self.db.sessions.add_ag_ui_chunk(card_id, chunk)
                    pass
                
                # Clear buffer after successful flush
                self._chunk_buffers[card_id] = []
                logger.debug(f"[AG-UI] Flush complete for {card_id}")
                
            except Exception as e:
                logger.error(f"[AG-UI] Flush failed for {card_id}: {e}")
                # Keep buffer on failure for retry
    
    async def _flush_on_event(self, card_id: str, event_type: str):
        """
        Flush buffer on specific events (message_end, session_stop).
        
        Args:
            card_id: The card/session identifier
            event_type: Type of event triggering the flush
        """
        if event_type in ("message_end", "session_stop", "stop"):
            logger.info(f"[AG-UI] Event-triggered flush for {card_id} (event: {event_type})")
            await self._trigger_flush(card_id, f"event:{event_type}")
    
    async def recover_incomplete_messages(self, card_id: str):
        """
        Recover incomplete messages from previous session (crash recovery).
        Scans for is_complete=0 records and marks them as interrupted.
        
        Args:
            card_id: The card/session identifier
        """
        logger.info(f"[AG-UI] Recovering incomplete messages for {card_id}")
        
        # Get incomplete messages from DB
        incomplete = await asyncio.to_thread(self.db.sessions.get_incomplete_messages, card_id)
        
        for msg in incomplete:
            # Mark as interrupted in metadata
            metadata = msg.get("metadata") or {}
            metadata["is_interrupted"] = True
            metadata["interrupted_at"] = asyncio.get_event_loop().time()
            
            # Update in database
            await asyncio.to_thread(
                self.db.sessions.update_message_metadata,
                msg["id"],
                metadata
            )
            
            logger.debug(f"[AG-UI] Marked message {msg['id']} as interrupted")
        
        logger.info(f"[AG-UI] Recovery complete: {len(incomplete)} messages marked")
    
    async def shutdown_ag_ui_buffers(self):
        """
        Flush all pending buffers during shutdown.
        """
        logger.info("[AG-UI] Flushing all pending buffers on shutdown")
        
        for card_id in list(self._chunk_buffers.keys()):
            await self._trigger_flush(card_id, "shutdown")
        
        # Cancel all pending timers
        for timer in self._flush_timers.values():
            if not timer.cancelled():
                timer.cancel()
        
        self._chunk_buffers.clear()
        self._flush_timers.clear()
    
    # ==================== End AG-UI Buffer Layer ====================

    async def handle_set_config_option(self, card_id: str, config_id: str, value: Any):
        engine, _ = await self._get_or_create_engine(card_id)
        new_options = await engine.set_config_option(config_id, value)
        if new_options is not None: bus.publish(card_id, {"type": "config_options", "options": new_options})
        return new_options

    async def _handle_status_cmd(self, p, rid):
        msg = f"Engines active: {len(self.engines)}"
        logger.info(f"[*] Command /status: {msg}")
        return {"message": msg}

    async def _handle_summarize_cmd(self, p, rid):
        cid = p.get("card_id")
        if not cid: return {"error": "Missing card_id"}
        logger.info(f"[*] Command /summarize for card {cid}")
        asyncio.create_task(self.summary_service.summarize_move(cid, "Manual", "Current"))
        return {"message": "Summary task started."}

    async def _handle_reset_cmd(self, p, rid):
        cid = p.get("card_id")
        logger.info(f"[*] Command /reset for card {cid}")
        if cid in self.engines: await self.engines[cid].stop(); del self.engines[cid]
        await asyncio.to_thread(self.db.update_card_session_id, cid, None)
        return {"message": "Reset complete."}

    async def _handle_help_cmd(self, p, rid):
        msg = "Available:\n" + "\n".join([f"- `/{c['name']}`: {c['description']}" for c in self._get_available_commands()])
        logger.info(f"[*] Command /help")
        return {"message": msg}

    async def shutdown(self):
        # Flush AG-UI buffers before shutdown
        await self.shutdown_ag_ui_buffers()
        
        await self.tasks.cancel_all()
        await asyncio.gather(*[eng.stop() for eng in self.engines.values()], return_exceptions=True)
