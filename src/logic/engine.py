import os
import json
import asyncio
import time
from datetime import datetime
from enum import Enum
from typing import Optional, List, Dict, Any, Callable
from src.protocol.client import ACPClient
from src.protocol.adapter import ACPProtocolAdapter
from src.protocol.tool_registry import tool_registry
from src.persistence.database import KanbanDB
from src.config.manager import config
from src.logger import setup_logger

logger = setup_logger("SessionEngine")

class SessionState(Enum):
    IDLE = "idle"
    THINKING = "thinking"
    ERROR = "error"

class SessionEngine:
    def __init__(self, card_id: str, provider_id: str, workspace_path: str, column_id: str, db: Optional[KanbanDB] = None):
        self.card_id = card_id
        self.provider_id = provider_id
        self.workspace_path = workspace_path
        self.column_id = column_id
        self.db = db
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

    def set_on_request(self, on_request: Optional[Callable]):
        """Update the nested request callback."""
        if self.adapter:
            self.adapter.on_request = on_request
        self.logger.debug(f"[*] on_request callback updated for card {self.card_id}")

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

                # Try to restore previous session if we have a saved sessionId
                if self.acp_session_id:
                    self.logger.info(f"Attempting to restore session: {self.acp_session_id}")
                    try:
                        load_params = {
                            "sessionId": self.acp_session_id,
                            "cwd": self.workspace_path,
                            "mcpServers": tool_registry.get_mcp_servers()
                        }
                        load_res = await self.adapter.handle_request("session/load", load_params)
                        # session/load returns {modes, models, configOptions}, NOT sessionId
                        if load_res and ("modes" in load_res or "configOptions" in load_res or "models" in load_res):
                            self.current_config_options = load_res.get("configOptions", [])
                            self._save_config_options_to_db()
                            self.logger.info(f"Session restored successfully: {self.acp_session_id} (configOptions: {len(self.current_config_options)})")
                            self.state = SessionState.IDLE
                            return self.acp_session_id
                        else:
                            self.logger.warning(f"Session load failed, creating new session")
                    except Exception as e:
                        self.logger.warning(f"Session load error: {e}, creating new session")

                # session/new (fallback if no saved session or load failed)
                res = await self.adapter.handle_request("session/new", {"cwd": self.workspace_path})
                self.acp_session_id = res.get("sessionId")
                self.current_config_options = res.get("configOptions", [])
                self._save_config_options_to_db()

                self.state = SessionState.IDLE
                
                # Robust Indexing Trigger: Ensure codebase is indexed when session starts
                if self.workspace_path:
                    async def ensure_indexed():
                        from src.persistence.embedding import embedding_service
                        project_id = self.db.cards.get_by_id(self.card_id).get("project_id")
                        if project_id:
                            # We check if index exists. If not, trigger full index.
                            symbols = self.db.code_symbols.get_by_project(project_id, limit=1)
                            if not symbols:
                                self.logger.info(f"[*] Project {project_id} index missing. Triggering full index...")
                                await embedding_service.index_codebase(project_id, self.workspace_path)
                    
                    asyncio.create_task(ensure_indexed())

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

    def _save_config_options_to_db(self):
        """Persist config options to database for recovery after reconnect."""
        if self.db and self.card_id and self.current_config_options:
            import json
            try:
                self.db.update_card_config_options(
                    self.card_id, json.dumps(self.current_config_options)
                )
                self.logger.debug(f"Saved {len(self.current_config_options)} config options to DB")
            except Exception as e:
                self.logger.error(f"Failed to save config options to DB: {e}")

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
                self._save_config_options_to_db()
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
