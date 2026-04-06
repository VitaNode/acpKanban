import json
import uuid
import asyncio
import sys
from pathlib import Path
from typing import Optional, Dict, Any, Callable
from config_manager import config
from tool_registry import tool_registry


class ACPProtocolAdapter:
    """
    Protocol adapter that converts custom chat/message format to standard ACP session/prompt.
    """

    def __init__(self, acp_client, workspace_cwd: Optional[str] = None):
        """
        Initialize the adapter.
        """
        self.acp = acp_client
        self._workspace_cwd = workspace_cwd or str(Path.home())
        self._card_sessions = {}
        self._history = {}
        self._current_card_id: Optional[str] = None

    def log(self, message: str):
        """Log a message."""
        print(f"[Adapter] {message}", flush=True)

    def _build_prompt_item(self, content: str) -> Dict[str, Any]:
        """
        Build prompt item.
        """
        return {"type": "text", "text": content}

    async def initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle initialize request with full official capabilities.
        """
        if "workspace_path" in params:
            self._workspace_cwd = params["workspace_path"]
        elif "cwd" in params:
            self._workspace_cwd = params["cwd"]

        self.log(f"Initializing with workspace: {self._workspace_cwd}")

        # Official ACP initialize format
        acp_params = {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {
                    "readTextFile": True,
                    "writeTextFile": True
                },
                "terminal": True
            },
            "clientInfo": {
                "name": "Kanban-Bridge",
                "title": "Agent Kanban Bridge",
                "version": "1.0.0"
            }
        }

        response = await self.acp.request("initialize", acp_params)
        return response.get("result", {})

    async def chat_message(
        self,
        message: str,
        card_id: str = None,
        workspace_path: str = None,
        acp_session_id: str = None,
        on_notification: Optional[Callable[[Dict[str, Any]], Any]] = None,
    ) -> Dict[str, Any]:
        """
        Convert chat/message to session/prompt and forward to ACP CLI.
        """
        self.log(f"Processing chat_message: {message[:50]}... (card_id: {card_id})")

        sid_key = card_id or "default"
        session_id = self._card_sessions.get(sid_key)

        if not session_id:
            if acp_session_id:
                self.log(f"Attempting to load saved session: {acp_session_id}")
                session_id, error_reason = await self._load_session(
                    acp_session_id, workspace_path=workspace_path, card_id=sid_key
                )
                if session_id:
                    self.log(f"Session loaded successfully: {session_id}")
                else:
                    self.log(f"Session load failed ({error_reason}), will create new")

            if not session_id:
                self.log(f"Creating new session for card: {sid_key}")
                session_id = await self._create_session(
                    workspace_path=workspace_path,
                    card_id=sid_key,
                )
                self.log(f"Session created: {session_id}")

            self._card_sessions[sid_key] = session_id

        # 2. Setup notification listener
        listener_id = str(uuid.uuid4())
        queue = self.acp.listen(listener_id)
        collected_text = []

        # 3. Send request
        prompt_task = asyncio.create_task(
            self.acp.request(
                "session/prompt",
                {
                    "sessionId": session_id,
                    "prompt": [self._build_prompt_item(message)],
                },
            )
        )

        await asyncio.sleep(0.1)

        # Clear stale
        while not queue.empty():
            try: queue.get_nowait()
            except asyncio.QueueEmpty: break

        # 4. Collect notifications
        async def collect_notifications():
            while True:
                try:
                    data = await asyncio.wait_for(queue.get(), timeout=0.5)
                    if on_notification:
                        await on_notification(data)

                    if data.get("method") == "session/update":
                        update = data.get("params", {}).get("update", {})
                        content = update.get("content", {})
                        if isinstance(content, dict) and "text" in content:
                            collected_text.append(content["text"])
                except asyncio.TimeoutError:
                    if prompt_task.done(): break
                except Exception: break

        await collect_notifications()
        self.acp.stop_listening(listener_id)

        try:
            response = await prompt_task
        except Exception as e:
            return {"error": {"code": -32603, "message": f"Prompt failed: {str(e)}"}}

        if "error" in response:
            return {"error": response["error"]}

        result = response.get("result", {})
        final_message = "".join(collected_text).strip()
        if isinstance(result, dict) and "text" in result:
            final_message = result["text"] or final_message

        return {"message": final_message, "session_id": session_id}

    async def _create_session(
        self,
        workspace_path: str = None,
        card_id: str = None,
    ) -> str:
        project_cwd = workspace_path or self._workspace_cwd

        # Official format: mcpServers from tool_registry (already string 'command' and list 'args')
        mcp_servers = tool_registry.get_mcp_servers()

        params = {
            "cwd": project_cwd,
            "mcpServers": mcp_servers,
        }

        if card_id:
            params["_meta"] = {"sessionKey": f"agent:main:kanban:{card_id}"}

        response = await self.acp.request("session/new", params)
        if "error" in response:
            raise Exception(f"Session creation failed: {response['error']}")

        session_id = response.get("result", {}).get("sessionId")
        self._workspace_cwd = project_cwd
        return session_id

    async def _load_session(
        self, session_id: str, workspace_path: str = None, card_id: str = None
    ) -> tuple[Optional[str], str]:
        project_cwd = workspace_path or self._workspace_cwd
        try:
            response = await self.acp.request(
                "session/load",
                {
                    "sessionId": session_id,
                    "cwd": project_cwd,
                    "mcpServers": tool_registry.get_mcp_servers(),
                },
            )
            if "error" in response:
                return None, str(response.get("error", {}))
            return session_id, ""
        except Exception as e:
            return None, str(e)

    async def handle_request(
        self, method: str, params: Dict[str, Any], on_notification: Optional[Callable[[Dict[str, Any]], Any]] = None
    ) -> Dict[str, Any]:
        if method == "initialize":
            return await self.initialize(params)
        elif method == "chat/message" or (method == "session/prompt" and "message" in params):
            return await self.chat_message(
                params.get("message", ""),
                card_id=params.get("card_id"),
                workspace_path=params.get("workspace_path"),
                acp_session_id=params.get("acp_session_id"),
                on_notification=on_notification,
            )
        else:
            response = await self.acp.request(method, params)
            if "error" in response: return {"error": response["error"]}
            return response.get("result", {})
