import asyncio
import json
from typing import Dict, Any, Optional, Callable
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
    """Manages tracking and lifecycle of background tasks (P2-2 FIX)."""
    def __init__(self):
        self._tasks: Dict[str, asyncio.Task] = {}

    def add(self, key: str, task: asyncio.Task):
        self._tasks[key] = task

    def remove(self, key: str):
        self._tasks.pop(key, None)

    async def cancel_all(self):
        if not self._tasks:
            return
        logger.info(f"Cancelling {len(self._tasks)} active tasks...")
        for task in self._tasks.values():
            task.cancel()
        # P2-6 FIX: Await task completion after cancellation
        await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        self._tasks.clear()

class MessageDispatcher:
    """
    Main orchestrator that routes incoming messages to 
    SessionEngines, local commands, or management logic.
    """
    def __init__(self, db: KanbanDB):
        self.db = db
        self.context_builder = ContextBuilder(db)
        self.summary_service = SummaryService(db) # Phase 3: New Service
        self.engines: Dict[str, SessionEngine] = {}
        self.commands = CommandRegistry()
        self.tasks = TaskRegistry()
        self._setup_local_commands()
        self._engine_creation_locks: Dict[str, asyncio.Lock] = {}

    def _setup_local_commands(self):
        self.commands.register("/status", self._handle_status_cmd)
        self.commands.register("/reset", self._handle_reset_cmd)

    async def dispatch(self, data: Dict[str, Any], on_output: Callable) -> Optional[Dict[str, Any]]:
        """
        Routes the request and returns a synchronous response if applicable.
        """
        method = data.get("method")
        params = data.get("params", {})
        request_id = data.get("id")
        
        # Phase 3: Trigger summary generation on move
        if method == "cards/move":
            card_id = params.get("id")
            target_col_id = params.get("target_column_id")
            if card_id and target_col_id:
                # Capture current column before move
                async def trigger_summary_with_context():
                    card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
                    target_col = await asyncio.to_thread(self.db.columns.get_by_id, target_col_id)
                    if card and target_col:
                        source_col = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
                        from_name = source_col["name"] if source_col else "Unknown"
                        to_name = target_col["name"]
                        await self.summary_service.summarize_move(card_id, from_name, to_name)
                
                asyncio.create_task(trigger_summary_with_context())
        
        ui_format = params.get("ui_format", "acp")

        # Wrap output to handle AG-UI mapping if requested
        async def wrapped_output(output_data):
            if ui_format == "ag_ui":
                mapped = AGUIMapper.map_notification(output_data)
                if mapped:
                    await on_output(mapped)
                    return
            await on_output(output_data)

        # 1. Handle Slash Commands (Interceptors)
        if method in ("chat/message", "session/prompt"):
            prompt_text = params.get("message") or params.get("prompt")
            if isinstance(prompt_text, list):
                prompt_text = " ".join([p.get("text", "") for p in prompt_text if p.get("type") == "text"])
            
            handler = self.commands.get_handler(prompt_text)
            if handler:
                return await handler(params, request_id)

        # 2. Route to SessionEngine for Conversation
        card_id = params.get("card_id")
        if card_id and method in ("chat/message", "session/prompt"):
            # P0-1 FIX: Save user message immediately
            prompt_text = params.get("message") or params.get("prompt")
            if isinstance(prompt_text, list):
                prompt_text = " ".join([p.get("text", "") for p in prompt_text if p.get("type") == "text"])
            
            await asyncio.to_thread(self.db.sessions.add_message, card_id, "user", prompt_text)
            
            # Record timeline for user message
            card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
            if card and card.get("project_id"):
                await asyncio.to_thread(
                    self.db.projects.add_timeline_event, 
                    card["project_id"], card_id, "user_message", f"[user] {prompt_text[:100]}"
                )

            # Background the long-running prompt
            task_key = f"{card_id}_{request_id}"
            task = asyncio.create_task(self._process_engine_request(card_id, method, params, request_id, wrapped_output))
            self.tasks.add(task_key, task)
            return {"status": "submitted", "card_id": card_id}

        # 3. Fallback: Unknown or management methods
        return {"error": {"code": -32601, "message": f"Method {method} not handled by dispatcher"}}

    async def _get_or_create_engine(self, card_id: str, on_nested_request: Optional[Callable] = None) -> (SessionEngine, bool):
        # P0-2 FIX: Pre-check without lock
        if card_id in self.engines:
            engine = self.engines[card_id]
            if engine.is_alive:
                return engine, False

        # Acquire lock for this card
        if card_id not in self._engine_creation_locks:
            self._engine_creation_locks[card_id] = asyncio.Lock()

        async with self._engine_creation_locks[card_id]:
            # Load current card state
            card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
            if not card:
                raise ValueError(f"Card {card_id} not found")

            # HIGH-2: Check if existing engine belongs to a different column
            if card_id in self.engines:
                engine = self.engines[card_id]
                if engine.is_alive:
                    if engine.column_id == card["column_id"]:
                        return engine, False
                    else:
                        logger.info(f"Card {card_id[:8]} moved columns. Restarting session.")
                        await engine.stop()
                        self.engines.pop(card_id, None)

            # Get column strategy
            column = await asyncio.to_thread(self.db.columns.get_by_id, card["column_id"])
            if not column:
                raise ValueError(f"Column {card['column_id']} not found")

            # Strategy: Column Provider -> Card Provider -> Default Provider
            provider_id = column.get("acp_provider_id") or card.get("acp_provider_id") or config.default_provider
            
            # Get project workspace
            project_id = column["project_id"]
            workspace_path = config.get("system.workspace_root")
            project = await asyncio.to_thread(self.db.projects.get_by_id, project_id)
            if project and project.get("workspace_path"):
                workspace_path = project["workspace_path"]

            engine = SessionEngine(card_id, provider_id, workspace_path, card["column_id"])
            engine.acp_session_id = card.get("acp_session_id")
            
            # Additional column-level metadata could be stored here
            engine.column_prompt_template = column.get("prompt_template")
            engine.column_approval_mode = column.get("approval_mode")

            # Pass the handler for server-to-client requests
            await engine.start(on_request=on_nested_request)
            self.engines[card_id] = engine
            return engine, True

    async def _process_engine_request(self, card_id, method, params, request_id, on_output):
        task_key = f"{card_id}_{request_id}"
        try:
            # Local nested request handler
            async def handle_nested_request(inner_method, inner_params):
                self.logger.info(f"Forwarding nested request: {inner_method} for card {card_id}")
                # We need to send this to the UI and wait for result
                # The 'on_output' callback here is usually used for notifications, 
                # but for requests we need a blocking wait.
                # This requires bridge support.
                if inner_method == "session/request_permission":
                    # Add card_id to params so UI knows which card is asking
                    inner_params["card_id"] = card_id
                    return await on_output({
                        "jsonrpc": "2.0",
                        "method": inner_method,
                        "params": inner_params
                    }, is_request=True)
                return {"error": "Method not supported"}

            engine, is_new = await self._get_or_create_engine(card_id, on_nested_request=handle_nested_request)            
            # P1-2 FIX: Non-blocking context injection
            if is_new or not engine.acp_session_id:
                # Fire and forget context injection
                asyncio.create_task(self._inject_context_async(card_id, engine))

            async def forward_notification(n):
                if "params" in n:
                    n["params"]["card_id"] = card_id
                
                # P0-1 FIX: Persist ACP notifications
                update = n.get("params", {}).get("update", {})
                update_type = update.get("sessionUpdate")
                
                if update_type == "agent_message_chunk":
                    text = update.get("content", {}).get("text", "")
                    if text:
                        await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", text, is_complete=False)
                
                elif update_type == "tool_call":
                    title = update.get("title") or update.get("tool") or "Tool Call"
                    status = update.get("status", "pending")
                    tool_id = update.get("toolCallId")
                    text = f"🛠️ **{title}** ({status})"
                    await asyncio.to_thread(
                        self.db.sessions.add_message, 
                        card_id, "assistant", text, 
                        {"type": "tool_call", "toolCallId": tool_id}, 
                        is_complete=False
                    )
                
                elif update_type == "tool_call_update":
                    status = update.get("status")
                    tool_id = update.get("toolCallId")
                    is_finished = status in ["completed", "failed"]
                    await asyncio.to_thread(
                        self.db.sessions.update_message_with_metadata,
                        card_id, "toolCallId", tool_id, None, is_finished
                    )
                
                elif update_type == "stop":
                    # Mark last message as complete
                    await asyncio.to_thread(self.db.sessions.append_message, card_id, "assistant", "", is_complete=True)
                    
                    # Record timeline event for AI action (LOW-3: Wrap in try-except)
                    try:
                        card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
                        if card and card.get("project_id"):
                            last_msg = await asyncio.to_thread(self.db.sessions.get_latest_message, card_id, "assistant")
                            if last_msg:
                                content = last_msg.get("content", "")
                                await asyncio.to_thread(
                                    self.db.projects.add_timeline_event,
                                    card["project_id"], card_id, "ai_action", f"[assistant] {content[:100]}"
                                )
                    except Exception as te:
                        logger.warning(f"Failed to add timeline event: {te}")

                await on_output(n)

            result = await engine.process_prompt(method, params, on_notification=forward_notification)
            
            if engine.acp_session_id != params.get("acp_session_id"):
                await asyncio.to_thread(self.db.cards.update_card_session_id, card_id, engine.acp_session_id)
                
            await on_output({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"card_id": card_id, "update": {"sessionUpdate": "stop"}}
            })
            
        except Exception as e:
            logger.error(f"Engine process error: {e}")
            await on_output({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(e)}})
        finally:
            self.tasks.remove(task_key)

    async def _inject_context_async(self, card_id: str, engine: SessionEngine):
        """Background task to inject system context."""
        try:
            # 1. Quick check if engine is already in error state
            if not engine.is_alive or engine.state == SessionState.ERROR:
                return

            # Pass column prompt template if available
            column_prompt = getattr(engine, "column_prompt_template", None)
            context = await self.context_builder.build_initial_context(card_id, column_prompt=column_prompt)
            logger.info(f"Injecting initial context for card {card_id[:8]} (background)")
            
            # 2. Re-check before starting prompt
            if not engine.is_alive or engine.state == SessionState.ERROR:
                return

            async def silent_output(n): pass 
            await engine.process_prompt(
                "session/prompt", # Standardized method
                {"message": f"[SYSTEM CONTEXT]\n{context}\n\nPlease acknowledge this context and wait for user input."},
                on_notification=silent_output
            )
        except Exception as ce:
            logger.warning(f"Background context injection failed: {ce}")

    async def _handle_status_cmd(self, params, request_id):
        engine_stats = {cid: eng.state for cid, eng in self.engines.items() if eng.is_alive}
        return {
            "message": f"Bridge Status:\n- Active Engines: {len(engine_stats)}\n- Details: {json.dumps(engine_stats)}",
            "type": "system_info"
        }

    async def _handle_reset_cmd(self, params, request_id):
        card_id = params.get("card_id")
        if card_id in self.engines:
            await self.engines[card_id].stop()
            del self.engines[card_id]
        
        await asyncio.to_thread(self.db.cards.update_card_session_id, card_id, None)
        return {"message": "Session reset successfully.", "card_id": card_id}

    async def shutdown(self):
        logger.info("Shutting down dispatcher...")
        await self.tasks.cancel_all()
        
        stop_tasks = [eng.stop() for eng in self.engines.values()]
        if stop_tasks:
            await asyncio.gather(*stop_tasks, return_exceptions=True)
        self.engines.clear()
        logger.info("Dispatcher shutdown complete.")
