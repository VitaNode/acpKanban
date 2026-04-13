import asyncio
import json
import logging
import uuid
from typing import Dict, Any, Optional, Callable
from src.orchestration.dispatcher import MessageDispatcher
from src.persistence.database import KanbanDB
from src.transport.bus import bus
from src.logger import setup_logger

class UnifiedBridge:
    def __init__(self, user_id, relay_url, token=None, session_key=None, workspace_cwd=None):
        self.logger = setup_logger(f"Bridge[{user_id[:8]}]")
        self.db = KanbanDB()
        self.dispatcher = MessageDispatcher(self.db)
        self._pending_ui_requests: Dict[str, asyncio.Future] = {}

    async def start(self):
        self.logger.info("Bridge started")

    async def on_ui_response(self, request_id: str, result: Any):
        """Phase 3.2: Standardized UI Response Resolver."""
        self.logger.info(f"UI Response received for {request_id}")
        future = self._pending_ui_requests.pop(request_id, None)
        if future and not future.done():
            future.set_result(result)

    async def handle_rpc(self, data: Dict[str, Any], send_notification: Callable):
        # This is where we wrap UI requests to capture them
        async def on_ui_request(method, params):
            rid = str(uuid.uuid4())
            fut = asyncio.get_event_loop().create_future()
            self._pending_ui_requests[rid] = fut
            await send_notification({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            try:
                return await asyncio.wait_for(fut, timeout=60.0)
            except asyncio.TimeoutError:
                self._pending_ui_requests.pop(rid, None)
                return {"error": {"code": -32000, "message": "UI Request Timeout"}}

        return await self.dispatcher.dispatch(data, on_ui_request)

    async def shutdown(self):
        await self.dispatcher.shutdown()
