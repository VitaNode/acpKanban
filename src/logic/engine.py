import os
import json
import asyncio
import time
from datetime import datetime
from enum import Enum
from typing import Optional, List, Dict, Any, Callable
from src.protocol.client import ACPClient
from src.protocol.adapter import ACPProtocolAdapter
from src.persistence.database import KanbanDB
from src.config.manager import config
from src.logger import setup_logger

logger = setup_logger("SessionEngine")

class SessionState(Enum):
    IDLE = "idle"
    THINKING = "thinking"
    ERROR = "error"

class SessionEngine:
    def __init__(self, card_id: str, provider_id: str, workspace_path: str, column_id: str):
        self.card_id = card_id
        self.provider_id = provider_id
        self.workspace_path = workspace_path
        self.column_id = column_id
        self.logger = setup_logger(f"SessionEngine[{card_id[:8]}]")
        self.state = SessionState.IDLE
        self.last_active = time.time()
        self.acp_client: Optional[ACPClient] = None
        self.adapter: Optional[ACPProtocolAdapter] = None
        self.acp_session_id: Optional[str] = None
        self.column_prompt_template: Optional[str] = None
        self.column_approval_mode: Optional[str] = None
        self.current_config_options = [] # Phase 5.2: Store runtime options
        self._lock = asyncio.Lock()

    @property
    def is_alive(self) -> bool:
        return self.acp_client is not None and self.acp_client.process is not None and self.acp_client.process.returncode is None

    async def start(self, fallback_command=None, on_request: Optional[Callable] = None):
        async with self._lock:
            if self.is_alive: return
            try:
                # Use the property helper from ConfigManager
                providers = config.providers
                cfg = next((p for p in providers if isinstance(p, dict) and p.get("id") == self.provider_id), None)
                if not cfg: raise ValueError(f"Provider {self.provider_id} not found in {len(providers)} providers")
                
                self.acp_client = ACPClient(cfg["command"], self.workspace_path)
                await self.acp_client.start()
                self.adapter = ACPProtocolAdapter(self.acp_client, workspace_cwd=self.workspace_path, provider_id=self.provider_id, on_request=on_request)
                
                # session/new
                res = await self.adapter.handle_request("session/new", {"cwd": self.workspace_path})
                self.acp_session_id = res.get("sessionId")
                self.current_config_options = res.get("configOptions", [])
                
                self.state = SessionState.IDLE
                return self.acp_session_id
            except Exception as e:
                self.state = SessionState.ERROR
                raise

    async def stop(self):
        async with self._lock:
            if self.acp_client:
                await self.acp_client.stop()
                self.acp_client = None
                self.adapter = None

    async def set_config_option(self, config_id: str, value: Any):
        """Phase 5.2: Set agent config at runtime."""
        if not self.adapter or not self.acp_session_id: return None
        try:
            res = await self.adapter.handle_request("session/set_config_option", {
                "sessionId": self.acp_session_id,
                "configId": config_id,
                "value": value
            })
            if "configOptions" in res:
                self.current_config_options = res["configOptions"]
            return self.current_config_options
        except Exception as e:
            self.logger.error(f"Failed to set config: {e}")
            return None

    async def process_prompt(self, method: str, params: Dict, on_notification: Optional[Callable] = None):
        if not self.is_alive: await self.start()
        self.last_active = time.time()
        self.state = SessionState.THINKING
        try:
            if self.acp_session_id: params["sessionId"] = self.acp_session_id
            res = await self.adapter.handle_request(method, params, on_notification=on_notification)
            if isinstance(res, dict) and "session_id" in res: self.acp_session_id = res["session_id"]
            return res
        finally:
            if self.state != SessionState.ERROR: self.state = SessionState.IDLE

class SummaryService:
    def __init__(self, db: KanbanDB): self.db = db
    async def generate_and_save_summary(self, card_id: str):
        from api.tasks import generate_card_summary_task
        await generate_card_summary_task(card_id)
    async def summarize_move(self, card_id: str, from_col: str, to_col: str):
        await self.generate_and_save_summary(card_id)
        obj = await asyncio.to_thread(self.db.summaries.get_by_card_id, card_id)
        if obj:
            wrapped = f"Transition: {from_col} -> {to_col}\nProgress: {obj['summary']}"
            await asyncio.to_thread(self.db.update_card_summary, card_id, wrapped)
