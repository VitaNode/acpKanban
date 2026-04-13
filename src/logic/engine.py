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
    Generates concise summaries of card activities for context hand-off.
    Used during column moves and card completion.
    """
    def __init__(self, db: KanbanDB):
        self.db = db
        self.api_key = os.getenv("KANBAN_API_KEY")
        self.base_url = os.getenv("KANBAN_BASE_URL", "https://api.openai.com/v1")
        self.model_id = os.getenv("KANBAN_MODEL_ID", "gpt-4o-mini")
        
        self.client = OpenAI(
            api_key=self.api_key,
            base_url=self.base_url
        )

    async def generate_and_save_summary(self, card_id: str) -> Optional[str]:
        """
        Retrieves card history, generates a summary, and saves it to DB.
        """
        # 1. Load history (sync repository call in thread)
        history = await asyncio.to_thread(self.db.sessions.get_history, card_id, limit=100)
        if not history:
            return None

        formatted_history = []
        for msg in history:
            role = msg["role"]
            content = msg["content"]
            if role == "system": continue
            formatted_history.append(f"{role.upper()}: {content[:500]}")

        history_text = "\n".join(formatted_history)
        
        try:
            prompt = (
                "Summarize the technical progress and current status of this task. "
                "Be concise (max 200 words). Focus on results."
            )
            
            response = await asyncio.to_thread(
                self.client.chat.completions.create,
                model=self.model_id,
                messages=[
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": f"History:\n{history_text}"}
                ],
                max_tokens=300
            )
            
            summary = response.choices[0].message.content
            await asyncio.to_thread(self.db.summaries.upsert, card_id, summary)
            # Update last_summary on the card
            with self.db.get_connection() as conn:
                conn.execute("UPDATE cards SET last_summary = ?, updated_at = ? WHERE id = ?", (summary, datetime.now().isoformat(), card_id))
            
            return summary
        except Exception as e:
            logger.error(f"Summary failed: {e}")
            return None
