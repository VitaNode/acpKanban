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
        self._session_id: Optional[str] = None
        self._sessions = {}  # {card_id: [message_history]}
        self._current_card_id: Optional[str] = None

    def log(self, message: str):
        """Log a message."""
        print(f"[Adapter] {message}", flush=True)

    def _build_prompt_item(self, content: str) -> Dict[str, Any]:
        """
        Build prompt item - same format for both gemini and qwen.

        Both gemini --acp and qwen --acp expect:
            {"type": "text", "text": "content"}

        Args:
            content: User's message content

        Returns:
            Prompt item in standard ACP format
        """
        return {"type": "text", "text": content}

    async def initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle initialize request - adds protocolVersion for gemini --acp compatibility.

        Args:
            params: Initialize parameters from Flutter App

        Returns:
            Initialize response from gemini --acp
        """
        # Update workspace if provided
        if "cwd" in params:
            self._workspace_cwd = params["cwd"]

        # Add protocolVersion for standard ACP compliance
        acp_params = {
            "protocolVersion": 1,
            "clientInfo": params.get(
                "clientInfo", {"name": "Unknown", "version": "1.0.0"}
            ),
        }

        response = await self.acp.request("initialize", acp_params)
        return response.get("result", {})

    async def chat_message(
        self,
        message: str,
        card_id: str = None,
        card_title: str = None,
        card_description: str = None,
    ) -> Dict[str, Any]:
        """
        Convert chat/message to session/prompt and forward to ACP CLI.
        """
        self.log(f"Processing chat_message: {message[:50]}... (card_id: {card_id})")
        self._current_card_id = card_id

        # Ensure session exists
        if not self._session_id:
            self.log("Creating new session...")
            await self._create_session()
            self.log(f"Session created: {self._session_id}")

        # Build minimal prompt: card title + description + user message only
        prompt_parts = []
        if card_title:
            prompt_parts.append(f"Card: {card_title}")
        if card_description:
            prompt_parts.append(f"Description: {card_description}")
        prompt_parts.append(f"User: {message}")
        user_prompt = "\n".join(prompt_parts)

        # 1. Setup notification listener
        listener_id = str(uuid.uuid4())
        queue = self.acp.listen(listener_id)
        collected_text = []

        async def collect_notifications():
            while True:
                try:
                    # Non-blocking check for notifications
                    data = await asyncio.wait_for(queue.get(), timeout=0.1)
                    if data.get("method") == "session/update":
                        update = data.get("params", {}).get("update", {})

                        # Capture text content from updates
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

        # 2. Send request with minimal prompt (no system prompt, no history)
        prompt_task = asyncio.create_task(
            self.acp.request(
                "session/prompt",
                {
                    "sessionId": self._session_id,
                    "prompt": [self._build_prompt_item(user_prompt)],
                },
            )
        )

        # 3. Run notification collection while waiting
        await collect_notifications()

        # 4. Cleanup listener
        self.acp.stop_listening(listener_id)

        try:
            response = await prompt_task
        except Exception as e:
            return {"error": {"code": -32603, "message": f"Prompt failed: {str(e)}"}}

        # Handle errors from ACP
        if "error" in response:
            return {"error": response["error"]}

        # Extract result
        result = response.get("result", {})
        final_message = "".join(collected_text).strip()

        # If the result itself contains text (rare in standard ACP), prioritize or append it
        if isinstance(result, dict) and "text" in result:
            final_message = result["text"] or final_message

        # Save messages to session cache for isolation
        if card_id:
            if card_id not in self._sessions:
                self._sessions[card_id] = []
            self._sessions[card_id].append({"role": "user", "content": message})
            self._sessions[card_id].append(
                {"role": "assistant", "content": final_message}
            )

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

    async def _create_session(self, workspace_path: str = None) -> str:
        """
        Create a new ACP session with gemini --acp.

        Args:
            workspace_path: The project workspace directory. If not provided,
                          uses the default workspace_cwd from initialization.
        """
        project_cwd = workspace_path or self._workspace_cwd

        response = await self.acp.request(
            "session/new", {"cwd": project_cwd, "mcpServers": []}
        )

        if "error" in response:
            raise Exception(f"Session creation failed: {response['error']}")

        self._session_id = response.get("result", {}).get("sessionId")
        self._workspace_cwd = project_cwd
        return self._session_id

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
            # Handle both custom chat/message and simplified session/prompt
            # Pass card_id, card_title, card_description for context
            return await self.chat_message(
                params.get("message", ""),
                card_id=params.get("card_id"),
                card_title=params.get("card_title"),
                card_description=params.get("card_description"),
            )
        elif method == "health":
            return await self.health(params)
        else:
            # Standard ACP method or unknown - forward directly and wait for response
            response = await self.acp.request(method, params)
            if "error" in response:
                # Return error dict, caller should check for this
                return {"error": response["error"]}
            return response.get("result", {})

    def get_session_id(self) -> Optional[str]:
        """Get current session ID (for debugging)."""
        return self._session_id

    def reset_session(self):
        """Reset session ID to force creation of new session."""
        self._session_id = None
