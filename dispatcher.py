import asyncio
import json
from typing import Dict, Any, Optional, Callable
from session_engine import SessionEngine
from database import KanbanDB
from logger import setup_logger, set_request_id
from config_manager import config

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

class MessageDispatcher:
    """
    Main orchestrator that routes incoming messages to 
    SessionEngines, local commands, or management logic.
    """
    def __init__(self, db: KanbanDB):
        self.db = db
        self.engines: Dict[str, SessionEngine] = {}
        self.commands = CommandRegistry()
        self._setup_local_commands()
        self._active_tasks: Dict[str, asyncio.Task] = {}

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
            # Background the long-running prompt
            task_key = f"{card_id}_{request_id}"
            task = asyncio.create_task(self._process_engine_request(card_id, method, params, request_id, on_output))
            self._active_tasks[task_key] = task
            return {"status": "submitted", "card_id": card_id}

        # 3. Fallback: Unknown or management methods
        return {"error": {"code": -32601, "message": f"Method {method} not handled by dispatcher"}}

    async def _get_or_create_engine(self, card_id: str) -> SessionEngine:
        if card_id in self.engines:
            engine = self.engines[card_id]
            if engine.is_alive:
                return engine

        # Load from DB to get provider
        card = await asyncio.to_thread(self.db.cards.get_by_id, card_id)
        if not card:
            raise ValueError(f"Card {card_id} not found")

        provider_id = card.get("acp_provider_id") or config.default_provider
        
        # Get project workspace
        project_id = None
        column = await asyncio.to_thread(self.db.columns.get_column_simple_for_bridge, card["column_id"])
        if column:
            project_id = column["project_id"]
        
        workspace_path = config.get("system.workspace_root")
        if project_id:
            project = await asyncio.to_thread(self.db.projects.get_by_id, project_id)
            if project and project.get("workspace_path"):
                workspace_path = project["workspace_path"]

        engine = SessionEngine(card_id, provider_id, workspace_path)
        engine.acp_session_id = card.get("acp_session_id")
        
        await engine.start()
        self.engines[card_id] = engine
        return engine

    async def _process_engine_request(self, card_id, method, params, request_id, on_output):
        task_key = f"{card_id}_{request_id}"
        try:
            engine = await self._get_or_create_engine(card_id)
            
            async def forward_notification(n):
                # Ensure card_id is present for client routing
                if "params" in n:
                    n["params"]["card_id"] = card_id
                await on_output(n)

            result = await engine.process_prompt(method, params, on_notification=forward_notification)
            
            # Update DB if session ID changed
            if engine.acp_session_id != params.get("acp_session_id"):
                await asyncio.to_thread(self.db.cards.update_card_session_id, card_id, engine.acp_session_id)
                
            # Final stop signal
            await on_output({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"card_id": card_id, "update": {"sessionUpdate": "stop"}}
            })
            
        except Exception as e:
            logger.error(f"Engine process error: {e}")
            await on_output({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(e)}})
        finally:
            self._active_tasks.pop(task_key, None)

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
        
        # Also clear session_id in DB to force a fresh session next time
        await asyncio.to_thread(self.db.cards.update_card_session_id, card_id, None)
        
        return {"message": "Session reset successfully. A new session will be created on next message.", "card_id": card_id}

    async def shutdown(self):
        """Stop all engines and tasks."""
        logger.info("Shutting down dispatcher...")
        for task in self._active_tasks.values():
            task.cancel()
        
        stop_tasks = [eng.stop() for eng in self.engines.values()]
        if stop_tasks:
            await asyncio.gather(*stop_tasks, return_exceptions=True)
        self.engines.clear()
        logger.info("Dispatcher shutdown complete.")
