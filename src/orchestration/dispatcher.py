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

logger = setup_logger("Dispatcher")

class CommandRegistry:
    """Registry for local slash commands."""
    def __init__(self):
        self._commands: Dict[str, Callable] = {}

    def register(self, name: str, handler: Callable):
        self._commands[name] = handler
        logger.info(f"Registered local command: {name}")

    def get_handler(self, text: str) -> Optional[Callable]:
        if not text or not text.startswith("/"):
            return None
        cmd_name = text.split()[0].lower()
        return self._commands.get(cmd_name)

class TaskRegistry:
    """Manages tracking and lifecycle of background tasks."""
    def __init__(self):
        self._tasks: Dict[str, asyncio.Task] = {}

    def add(self, key: str, task: asyncio.Task):
        self._tasks[key] = task

    def remove(self, key: str):
        self._tasks.pop(key, None)

    async def cancel_all(self):
        if not self._tasks: return
        logger.info(f"Cancelling {len(self._tasks)} active tasks...")
        for task in self._tasks.values():
            task.cancel()
        await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        self._tasks.clear()

class MessageDispatcher:
    def __init__(self, db: KanbanDB):
        self.db = db
        self.context_builder = ContextBuilder(db)
        self.summary_service = SummaryService(db)
        self.engines: Dict[str, SessionEngine] = {}
        self.commands = CommandRegistry()
        self.tasks = TaskRegistry()
        self._setup_local_commands()
        self._engine_creation_locks: Dict[str, asyncio.Lock] = {}
        self._internal_sessions: Set[str] = set()

    def _setup_local_commands(self):
        self.commands.register("/status", self._handle_status_cmd)
        self.commands.register("/reset", self._handle_reset_cmd)
        self.commands.register("/summarize", self._handle_summarize_cmd)
        self.commands.register("/help", self._handle_help_cmd)

    def _get_available_commands(self):
        """Phase 5.1: ACP standard command definitions."""
        return [
            {"name": "summarize", "description": "Generate an immediate summary of current card progress."},
            {"name": "reset", "description": "Reset the current AI session (purges AI memory)."},
            {"name": "status", "description": "Show the health of active AI engines."},
            {"name": "help", "description": "List all available slash commands."}
        ]

    async def _advertise_commands(self, session_id: str, on_output: Callable):
        """Phase 5.1: Send available_commands_update notification."""
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

    async def dispatch(self, data: Dict[str, Any], on_output: Callable) -> Optional[Dict[str, Any]]:
        method = data.get("method")
        params = data.get("params", {})
        request_id = data.get("id")
        
        # Move logic for summaries
        if method == "cards/move":
            card_id = params.get("id")
            target_col_id = params.get("target_column_id")
            if card_id and target_col_id:
                async def trigger_sum():
                    card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
                    target_col = await asyncio.to_thread(self.db.columns.get_by_id, target_col_id)
                    if card and target_col:
                        source_col = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
                        await self.summary_service.summarize_move(card_id, source_col["name"] if source_col else "Manual", target_col["name"])
                asyncio.create_task(trigger_sum())

        ui_format = params.get("ui_format", "acp")
        async def wrapped_output(output_data):
            if ui_format == "ag_ui":
                mapped = AGUIMapper.map_notification(output_data)
                if mapped: await on_output(mapped)
            else: await on_output(output_data)

        if method in ("chat/message", "session/prompt"):
            prompt_text = params.get("message") or params.get("prompt")
            if isinstance(prompt_text, list):
                prompt_text = " ".join([p.get("text", "") for p in prompt_text if p.get("type") == "text"])
            
            # --- Phase 4.2: Resource Reference (@filename) ---
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

            task_key = f"{card_id}_{request_id}"
            task = asyncio.create_task(self._process_engine_request(card_id, method, params, request_id, wrapped_output))
            self.tasks.add(task_key, task)
            return {"status": "submitted", "card_id": card_id}
        
        return {"error": {"code": -32601, "message": f"Method {method} not handled"}}

    async def _get_or_create_engine(self, card_id: str, on_nested_request: Optional[Callable] = None) -> (SessionEngine, bool):
        if card_id in self.engines and self.engines[card_id].is_alive:
            return self.engines[card_id], False

        if card_id not in self._engine_creation_locks: self._engine_creation_locks[card_id] = asyncio.Lock()
        async with self._engine_creation_locks[card_id]:
            card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
            if not card: raise ValueError(f"Card {card_id} not found")

            column = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
            provider_id = column.get("acp_provider_id") or card.get("acp_provider_id") or config.default_provider
            workspace_path = config.get("system.workspace_root")
            project = await asyncio.to_thread(self.db.projects.get_by_id, column["project_id"])
            if project and project.get("workspace_path"): workspace_path = project["workspace_path"]

            engine = SessionEngine(card_id, provider_id, workspace_path, card["column_id"])
            engine.acp_session_id = card.get("acp_session_id")
            engine.column_prompt_template = column.get("prompt_template")
            engine.column_approval_mode = column.get("approval_mode")

            await engine.start(on_request=on_nested_request)
            self.engines[card_id] = engine
            return engine, True

    async def _process_engine_request(self, card_id, method, params, request_id, on_output):
        task_key = f"{card_id}_{request_id}"
        session_id = params.get("sessionId")
        is_internal = session_id in self._internal_sessions
        try:
            async def handle_nested_request(inner_method, inner_params):
                if inner_method == "session/request_permission": inner_params["card_id"] = card_id
                return await on_output({"jsonrpc": "2.0", "method": inner_method, "params": inner_params}, is_request=True)

            engine, is_new = await self._get_or_create_engine(card_id, on_nested_request=handle_nested_request)            
            # Phase 5.1: Advertise Commands
            if engine.acp_session_id and not is_internal:
                await self._advertise_commands(engine.acp_session_id, on_output)

            if is_new or not engine.acp_session_id:
                asyncio.create_task(self._inject_context_async(card_id, engine))

            async def forward_notif(n):
                if "params" in n: n["params"]["card_id"] = card_id
                if is_internal:
                    await on_output(n); return

                update = n.get("params", {}).get("update", {})
                utype = update.get("sessionUpdate")
                if utype == "agent_message_chunk":
                    await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", update.get("content", {}).get("text", ""), False)
                elif utype == "tool_call":
                    await asyncio.to_thread(self.db.sessions.add_message, card_id, "assistant", f"🛠️ **{update.get('title') or update.get('tool')}**", {"type": "tool_call", "toolCallId": update.get("toolCallId")}, False)
                elif utype == "tool_call_update":
                    await asyncio.to_thread(self.db.sessions.update_message_with_metadata, card_id, "toolCallId", update.get("toolCallId"), None, update.get("status") in ["completed", "failed"])
                elif utype == "stop":
                    await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", "", True)
                await on_output(n)

            await engine.process_prompt(method, params, on_notification=forward_notif)
            if engine.acp_session_id != params.get("acp_session_id"):
                await asyncio.to_thread(self.db.cards.update_card_session_id, card_id, engine.acp_session_id)
            await on_output({"jsonrpc": "2.0", "method": "session/update", "params": {"card_id": card_id, "update": {"sessionUpdate": "stop"}}})
        except Exception as e:
            logger.error(f"Engine error: {e}")
            await on_output({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(e)}})
        finally: self.tasks.remove(task_key)

    async def _inject_context_async(self, card_id: str, engine: SessionEngine):
        internal_id = f"internal-{uuid.uuid4()}"
        self._internal_sessions.add(internal_id)
        try:
            if not engine.is_alive: return
            context = await self.context_builder.build_initial_context(card_id, column_prompt=getattr(engine, "column_prompt_template", None))
            async def silent(n): pass 
            await engine.process_prompt("session/prompt", {"sessionId": internal_id, "prompt": [{"type": "text", "text": f"[SYSTEM CONTEXT]\n{context}\n\nPlease acknowledge."}]}, on_notification=silent)
        finally: self._internal_sessions.discard(internal_id)

    async def _handle_status_cmd(self, params, request_id):
        return {"message": f"Active: {len([e for e in self.engines.values() if e.is_alive])}", "type": "status"}

    async def _handle_summarize_cmd(self, params, request_id):
        cid = params.get("card_id")
        if cid: asyncio.create_task(self.summary_service.summarize_move(cid, "Manual", "Current"))
        return {"message": "Summary task started."}

    async def _handle_reset_cmd(self, params, request_id):
        cid = params.get("card_id")
        if cid in self.engines:
            await self.engines[cid].stop(); del self.engines[cid]
        await asyncio.to_thread(self.db.cards.update_card_session_id, cid, None)
        return {"message": "Reset complete."}

    async def _handle_help_cmd(self, params, request_id):
        help_text = "\n".join([f"- `/{c['name']}`: {c['description']}" for c in self._get_available_commands()])
        return {"message": f"Available commands:\n{help_text}"}

    async def shutdown(self):
        await self.tasks.cancel_all()
        await asyncio.gather(*[eng.stop() for eng in self.engines.values()], return_exceptions=True)
        self.engines.clear()
