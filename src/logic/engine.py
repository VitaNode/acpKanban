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
        # Use local snapshots to avoid race conditions between checks
        client = self.acp_client
        if client is None:
            return False
        
        proc = client.process
        if proc is None:
            return False
            
        return proc.returncode is None

    def set_on_request(self, on_request: Optional[Callable]):
        """Update the nested request callback."""
        if self.adapter:
            self.adapter.on_request = on_request
        self.logger.debug(f"[*] on_request callback updated for card {self.card_id}")

    async def start(self, fallback_command=None, on_request: Optional[Callable] = None, is_quiet: bool = False):
        async with self._lock:
            if self.is_alive: 
                # If already alive, just return current session info if quiet
                if is_quiet:
                    return {
                        "sessionId": self.acp_session_id,
                        "configOptions": self.current_config_options
                    }
                return self.acp_session_id
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
                            self.current_config_options = self._normalize_session_config(load_res)
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
                self.current_config_options = self._normalize_session_config(res)
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

                return {
                    "sessionId": self.acp_session_id,
                    "configOptions": self.current_config_options
                }
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

    def _normalize_session_config(self, res: Dict[str, Any]) -> List[Dict[str, Any]]:
        """
        Normalize ACP session/new or session/load result to a flat configOptions list.
        Handles both legacy configOptions and explicit modes/models.
        Deduplicates by preferring explicit modes/models over configOptions items.
        """
        raw_options = res.get("configOptions", [])
        
        # Deduplicate: remove any existing items with category 'mode' or 'model' (or corresponding IDs)
        # to prevent duplicates when explicit 'modes' or 'models' are also present.
        options = [
            opt for opt in raw_options 
            if opt.get("category") not in ("mode", "model") and opt.get("id") not in ("mode", "model")
        ]
        
        # Handle explicit modes
        if "modes" in res:
            modes = res["modes"]
            available = modes.get("availableModes", [])
            if available:
                options.insert(0, { # Put mode at the beginning
                    "id": "mode",
                    "name": "Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": modes.get("currentModeId"),
                    "options": [{"value": m.get("id"), "name": m.get("name"), "description": m.get("description")} for m in available]
                })

        # Handle explicit models
        if "models" in res:
            models = res["models"]
            available = models.get("availableModels", [])
            if available:
                options.insert(1 if "modes" in res else 0, { # Put model after mode
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": models.get("currentModelId"),
                    "options": [{"value": m.get("modelId"), "name": m.get("name"), "description": m.get("description")} for m in available]
                })
        
        # If we removed them from raw_options but res didn't have top-level modes/models, 
        # add them back (this handles engines that only use configOptions)
        if "modes" not in res:
            mode_opts = [opt for opt in raw_options if opt.get("category") == "mode" or opt.get("id") == "mode"]
            if mode_opts: options.extend(mode_opts)
            
        if "models" not in res:
            model_opts = [opt for opt in raw_options if opt.get("category") == "model" or opt.get("id") == "model"]
            if model_opts: options.extend(model_opts)
        
        return options

    async def set_config_option(self, config_id: str, value: Any):
        """Phase 5.2: Set agent config at runtime. Also handles mode/model via ACP specialized methods."""
        if not self.adapter or not self.acp_session_id: return None
        try:
            # ACP Standard: Modes and Models have dedicated methods if returned explicitly
            method = "session/set_config_option"
            params = {"sessionId": self.acp_session_id}
            
            if config_id == "mode":
                method = "session/set_mode"
                params["modeId"] = value
            elif config_id == "model":
                method = "session/set_model"
                params["modelId"] = value
            else:
                params["configId"] = config_id
                params["value"] = value
            
            res = await self.adapter.handle_request(method, params)
            
            # Update our local state with the new config state returned by agent
            if res:
                self.current_config_options = self._normalize_session_config(res)
                self._save_config_options_to_db()
            return self.current_config_options
        except Exception as e:
            self.logger.error(f"Failed to set config ({config_id}={value}): {e}")
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
