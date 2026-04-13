import os
import json
import asyncio
import time
from datetime import datetime
from enum import Enum
from typing import Optional, List, Dict, Any, Callable
from openai import OpenAI
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
    """
    Manages the lifecycle and state machine of a single ACP session for a card.
    """
    def __init__(self, card_id: str, provider_id: str, workspace_path: str, column_id: str):
        self.card_id = card_id
        self.provider_id = provider_id
        self.workspace_path = workspace_path
        self.column_id = column_id # HIGH-2: Track starting column

        self.logger = setup_logger(f"SessionEngine[{card_id[:8]}]")
        self.state = SessionState.IDLE
        self.last_active = time.time()

        self.acp_client: Optional[ACPClient] = None
        self.adapter: Optional[ACPProtocolAdapter] = None
        self.acp_session_id: Optional[str] = None
        
        # Phase 3: Column-level strategies
        self.column_prompt_template: Optional[str] = None
        self.column_approval_mode: Optional[str] = None

        self._lock = asyncio.Lock()
        self._stop_event = asyncio.Event()

    @property
    def is_alive(self) -> bool:
        return (
            self.acp_client is not None
            and self.acp_client.process is not None
            and self.acp_client.process.returncode is None
        )

    async def start(self, fallback_command=None, on_request: Optional[Callable] = None):
        """Initialize ACP process and adapter."""
        async with self._lock:
            if self.is_alive:
                return

            try:
                provider_cfg = self._get_provider_config(self.provider_id)
                command = list(provider_cfg["command"])
                supports_yolo = provider_cfg.get("supports_yolo", False)
            except ValueError:
                if fallback_command:
                    command = list(fallback_command)
                    supports_yolo = False
                else:
                    raise

            # Auto-yolo for Gemini
            if supports_yolo and self.provider_id == "gemini":
                if "--approval-mode=yolo" not in command:
                    command.extend(["--approval-mode", "yolo"])

            self.acp_client = ACPClient(command=command, name=f"ACP-{self.provider_id}")
            await self.acp_client.start()

            self.adapter = ACPProtocolAdapter(
                self.acp_client, 
                workspace_cwd=self.workspace_path, 
                provider_id=self.provider_id,
                on_request=on_request # Link nested requests
            )
            self.state = SessionState.IDLE
            self.logger.info(f"Started session engine with provider {self.provider_id}")

    def _get_provider_config(self, provider_id: str) -> dict:
        for p in config.providers:
            if p["id"] == provider_id:
                return p
        raise ValueError(f"Provider '{provider_id}' not found")

    async def stop(self):
        """Gracefully stop the session."""
        async with self._lock:
            if self.acp_client:
                await self.acp_client.stop()
            self.state = SessionState.IDLE
            self.logger.info("Session engine stopped")

    async def process_prompt(self, method: str, params: Dict[str, Any], on_notification: Callable):
        """Execute a prompt request through the adapter with lock protection."""
        async with self._lock:
            if self.state != SessionState.IDLE:
                raise RuntimeError(f"Engine is busy (state={self.state})")

            self.state = SessionState.THINKING
            self.last_active = time.time()

            try:
                # Prepare params with session recovery info and strategy
                params_with_recovery = dict(params)
                params_with_recovery["acp_session_id"] = self.acp_session_id
                params_with_recovery["workspace_path"] = self.workspace_path
                
                # HIGH-3: Pass column strategy to Brain
                params_with_recovery["approval_mode"] = self.column_approval_mode

                result = await self.adapter.handle_request(
                    method, params_with_recovery, on_notification=on_notification
                )

                # Update internal session ID if it changed
                if isinstance(result, dict) and "session_id" in result:
                    self.acp_session_id = result["session_id"]

                return result
            except Exception as e:
                self.state = SessionState.ERROR
                self.logger.error(f"Error processing prompt: {e}")
                raise
            finally:
                if self.state != SessionState.ERROR:
                    self.state = SessionState.IDLE

class SummaryService:
    """
    Unified summary service that delegates to api.tasks for robustness.
    Ensures both summaries and embeddings are generated consistently.
    """
    def __init__(self, db: KanbanDB):
        self.db = db

    async def generate_and_save_summary(self, card_id: str):
        """
        Triggers the unified summary task in a thread.
        """
        # HIGH-NEW: Move import here to break circular dependency with api package
        from api.tasks import generate_card_summary_task
        
        # Run the robust task from api.tasks in a worker thread
        await asyncio.to_thread(generate_card_summary_task, card_id)
        logger.info(f"SummaryService triggered unified task for card {card_id}")

