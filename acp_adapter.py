"""
ACP Protocol Adapter

Converts custom protocol (chat/message) to standard ACP protocol (session/prompt).

This allows Flutter App to use the same protocol for both:
- Path 2: Mobile → Relay → acp_bridge_relay → gemini --acp
- Path 3: Mobile → acp_server.py → LLM API

Usage:
    adapter = ACPProtocolAdapter(acp_client)
    result = await adapter.handle_request("chat/message", {"message": "Hello"})
"""

import json
import uuid
import asyncio
from pathlib import Path
from typing import Optional, Dict, Any


class ACPProtocolAdapter:
    """
    Protocol adapter that converts custom chat/message format to standard ACP session/prompt.

    This enables Flutter App to work with both Path 2 (gemini --acp / qwen --acp) and Path 3 (acp_server.py)
    without any code changes on the Flutter side.
    """

    def __init__(self, acp_client, workspace_cwd: Optional[str] = None):
        """
        Initialize the adapter.

        Args:
            acp_client: ACPClient instance for communicating with ACP CLI
            workspace_cwd: Working directory for the ACP session (optional)
        """
        self.acp = acp_client
        self._workspace_cwd = workspace_cwd or str(Path.home())
        # Mapping: {card_id: sessionId} - One session per card for isolation
        self._card_sessions = {}
        self._history = {}  # {card_id: [message_history]}
        self._current_card_id: Optional[str] = None

    def log(self, message: str):
        """Log a message."""
        print(f"[Adapter] {message}", flush=True)

    def _build_prompt_item(self, content: str) -> Dict[str, Any]:
        """
        Build prompt item - same format for both gemini and qwen.
        """
        return {"type": "text", "text": content}

    async def initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle initialize request.
        """
        # Prioritize workspace_path (from project) over cwd
        if "workspace_path" in params:
            self._workspace_cwd = params["workspace_path"]
        elif "cwd" in params:
            self._workspace_cwd = params["cwd"]

        self.log(f"Initializing with workspace: {self._workspace_cwd}")

        acp_params = {
            "protocolVersion": 1,
            "clientInfo": params.get(
                "clientInfo", {"name": "Kanban-Bridge", "version": "1.0.0"}
            ),
        }

        response = await self.acp.request("initialize", acp_params)
        return response.get("result", {})

    async def chat_message(
        self,
        message: str,
        card_id: str = None,
        workspace_path: str = None,
    ) -> Dict[str, Any]:
        """
        Convert chat/message to session/prompt and forward to ACP CLI.
        Uses a unique sessionId per card_id to ensure session isolation.
        Sends only the raw user message — no system prompt, no card context.
        """
        self.log(f"Processing chat_message: {message[:50]}... (card_id: {card_id})")

        # Use 'default' if card_id is missing
        sid_key = card_id or "default"

        # 1. Get or create sessionId for this card
        if sid_key not in self._card_sessions:
            self.log(f"Creating new session for card: {sid_key}")
            session_id = await self._create_session(
                workspace_path=workspace_path, card_id=sid_key
            )
            self._card_sessions[sid_key] = session_id
            self.log(f"Session created: {session_id}")

        session_id = self._card_sessions[sid_key]

        # 2. Setup notification listener
        listener_id = str(uuid.uuid4())
        queue = self.acp.listen(listener_id)
        collected_text = []

        async def collect_notifications():
            while True:
                try:
                    data = await asyncio.wait_for(queue.get(), timeout=0.1)
                    if data.get("method") == "session/update":
                        update = data.get("params", {}).get("update", {})
                        content = update.get("content", {})
                        if isinstance(content, dict) and "text" in content:
                            collected_text.append(content["text"])
                        elif isinstance(content, list):
                            for item in content:
                                if (
                                    isinstance(item, dict)
                                    and item.get("type") == "text"
                                ):
                                    collected_text.append(item.get("text", ""))
                                elif (
                                    isinstance(item, dict)
                                    and item.get("type") == "content"
                                ):
                                    c = item.get("content", {})
                                    if isinstance(c, dict) and c.get("type") == "text":
                                        collected_text.append(c.get("text", ""))
                except asyncio.TimeoutError:
                    if prompt_task.done():
                        break
                except Exception:
                    break

        # 3. Send request with only the user message
        prompt_task = asyncio.create_task(
            self.acp.request(
                "session/prompt",
                {
                    "sessionId": session_id,
                    "prompt": [self._build_prompt_item(message)],
                },
            )
        )

        # 5. Run notification collection
        await collect_notifications()
        self.acp.stop_listening(listener_id)

        try:
            response = await prompt_task
        except Exception as e:
            return {"error": {"code": -32603, "message": f"Prompt failed: {str(e)}"}}

        if "error" in response:
            return {"error": response["error"]}

        # 6. Finalize response
        result = response.get("result", {})
        final_message = "".join(collected_text).strip()
        if isinstance(result, dict) and "text" in result:
            final_message = result["text"] or final_message

        # Optional: Save to local history cache
        if sid_key not in self._history:
            self._history[sid_key] = []
        self._history[sid_key].append({"role": "user", "content": message})
        self._history[sid_key].append({"role": "assistant", "content": final_message})

        return {"message": final_message}

    async def health(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Forward health check to gemini --acp.

        Args:
            params: Health check parameters (usually empty)

        Returns:
            Health status from gemini --acp
        """
        response = await self.acp.request("health", params)
        return response.get("result", {"status": "healthy"})

    async def _create_session(
        self, workspace_path: str = None, card_id: str = None
    ) -> str:
        project_cwd = workspace_path or self._workspace_cwd

        params = {
            "cwd": project_cwd,
            "mcpServers": [],
        }

        # OpenClaw requires _meta.sessionKey to bind the ACP session
        # Gemini CLI and others ignore this field safely
        if card_id:
            params["_meta"] = {"sessionKey": f"agent:main:kanban:{card_id}"}

        response = await self.acp.request("session/new", params)

        if "error" in response:
            raise Exception(f"Session creation failed: {response['error']}")

        session_id = response.get("result", {}).get("sessionId")
        self._workspace_cwd = project_cwd
        return session_id

    def set_workspace(self, workspace_path: str):
        """
        Set the workspace path for the session.

        Args:
            workspace_path: The project workspace directory path
        """
        self._workspace_cwd = workspace_path
        self.log(f"Workspace set to: {workspace_path}")

    async def handle_request(
        self, method: str, params: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Unified entry point - routes requests to appropriate handler.

        Args:
            method: RPC method name (e.g., "chat/message", "initialize")
            params: Method parameters (may include card_id for session isolation)

        Returns:
            Response result dictionary
        """
        if method == "initialize":
            return await self.initialize(params)
        elif method == "chat/message" or (
            method == "session/prompt" and "message" in params
        ):
            return await self.chat_message(
                params.get("message", ""),
                card_id=params.get("card_id"),
                workspace_path=params.get("workspace_path"),
            )
        elif method == "health":
            return await self.health(params)
        elif method == "session/get_id":
            return self.get_session_info(params.get("card_id"))
        else:
            # Standard ACP method or unknown - forward directly and wait for response
            response = await self.acp.request(method, params)
            if "error" in response:
                # Return error dict, caller should check for this
                return {"error": response["error"]}
            return response.get("result", {})

    def get_session_id(self, card_id: str = "default") -> Optional[str]:
        """Get sessionId for a specific card."""
        return self._card_sessions.get(card_id)

    def get_session_info(self, card_id: str = None) -> Dict[str, Any]:
        """Get session info for a card, including sessionId and status."""
        sid = self._card_sessions.get(card_id) if card_id else None
        return {
            "card_id": card_id,
            "session_id": sid,
            "has_session": sid is not None,
        }

    def reset_session(self, card_id: str = None):
        """Reset session ID to force creation of new session. If card_id is provided, only reset that card."""
        if card_id:
            self._card_sessions.pop(card_id, None)
            self._history.pop(card_id, None)
            self.log(f"Reset session for card: {card_id}")
        else:
            self._card_sessions.clear()
            self._history.clear()
            self.log("Reset all sessions")
