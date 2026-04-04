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
from typing import Optional, Dict, Any, Callable


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
        self._card_sessions = {}
        self._history = {}
        self._current_card_id: Optional[str] = None
        self._persist_session_callback: Optional[Callable] = None

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
        acp_session_id: str = None,
    ) -> Dict[str, Any]:
        """
        Convert chat/message to session/prompt and forward to ACP CLI.
        Uses a unique sessionId per card_id to ensure session isolation.
        Sends only the raw user message — no system prompt, no card context.

        Args:
            message: The user message to send
            card_id: Card identifier for session tracking
            workspace_path: Working directory for the session
            acp_session_id: Previously saved session ID (from DB), may be None
        """
        self.log(f"Processing chat_message: {message[:50]}... (card_id: {card_id})")

        # Use 'default' if card_id is missing
        sid_key = card_id or "default"

        # 1. Get or restore sessionId for this card
        session_id = self._card_sessions.get(sid_key)

        if not session_id:
            if acp_session_id:
                self.log(f"Attempting to load saved session: {acp_session_id}")
                session_id, error_reason = await self._load_session(
                    session_id=acp_session_id,
                    workspace_path=workspace_path,
                    card_id=sid_key,
                )
                if session_id:
                    self.log(f"Session loaded: {session_id}")
                elif error_reason == "workspace_mismatch":
                    self.log(f"Workspace mismatch, clearing old session data")
                    self._card_sessions.pop(sid_key, None)
                    self._history.pop(sid_key, None)
                else:
                    self.log(f"Load failed ({error_reason}), creating new session")

            if not session_id:
                self.log(f"Creating new session for card: {sid_key}")

                async def on_session_created(new_session_id: str):
                    self.log(f"Immediately persisting session_id: {new_session_id}")
                    if self._persist_session_callback:
                        await self._persist_session_callback(sid_key, new_session_id)

                session_id = await self._create_session(
                    workspace_path=workspace_path,
                    card_id=sid_key,
                    on_session_created=on_session_created,
                )
                self.log(f"Session created: {session_id}")

            self._card_sessions[sid_key] = session_id

        # 2. Setup notification listener - queue created BEFORE prompt
        listener_id = str(uuid.uuid4())
        queue = self.acp.listen(listener_id)
        collected_text = []

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

        # Wait briefly for prompt_task to actually send the request
        # before we start collecting notifications
        await asyncio.sleep(0.1)

        # Clear any stale notifications from session/load history replay
        while not queue.empty():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                break

        # 4. Collect notifications AFTER session/prompt was sent
        # Only extracts text content from content-bearing updates.
        # Metadata updates (session_info_update, available_commands_update) are ignored
        # because they don't have a 'content' field with 'text'.
        async def collect_notifications():
            while True:
                try:
                    # Increased timeout from 0.1 to 0.5 to reduce CPU load when idle
                    data = await asyncio.wait_for(queue.get(), timeout=0.5)
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

        return {"message": final_message, "session_id": session_id}

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
        self,
        workspace_path: str = None,
        card_id: str = None,
        on_session_created: Callable[[str], Any] = None,
    ) -> str:
        project_cwd = workspace_path or self._workspace_cwd

        params = {
            "cwd": project_cwd,
            "mcpServers": [],
        }

        if card_id:
            params["_meta"] = {"sessionKey": f"agent:main:kanban:{card_id}"}

        response = await self.acp.request("session/new", params)

        if "error" in response:
            raise Exception(f"Session creation failed: {response['error']}")

        session_id = response.get("result", {}).get("sessionId")

        if on_session_created:
            await on_session_created(session_id)

        self._workspace_cwd = project_cwd
        return session_id

    async def _load_session(
        self, session_id: str, workspace_path: str = None, card_id: str = None
    ) -> tuple[Optional[str], str]:
        """
        Try to load an existing session via session/load.
        Returns (session_id, error_reason) tuple.
        error_reason is empty string on success.
        """
        project_cwd = workspace_path or self._workspace_cwd

        try:
            response = await self.acp.request(
                "session/load",
                {
                    "sessionId": session_id,
                    "cwd": project_cwd,
                    "mcpServers": [],
                },
            )

            if "error" in response:
                error_msg = str(response.get("error", {}))
                if "workspace" in error_msg.lower() or "cwd" in error_msg.lower():
                    self.log(
                        f"Session load failed: workspace mismatch for {session_id}"
                    )
                    return None, "workspace_mismatch"
                self.log(f"Session load error: {error_msg}")
                return None, "session_not_found"

            return session_id, ""
        except Exception as e:
            self.log(f"Session load exception: {e}")
            return None, str(e)

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
            params: Method parameters (may include card_id, acp_session_id, workspace_path)

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
                acp_session_id=params.get("acp_session_id"),
            )
        elif method == "health":
            return await self.health(params)
        else:
            response = await self.acp.request(method, params)
            if "error" in response:
                return {"error": response["error"]}
            return response.get("result", {})

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
