import json
import uuid
import asyncio
import time
from typing import Dict, Any, List, Optional, Callable
from pathlib import Path
from .tool_registry import tool_registry

class ACPProtocolAdapter:
    """
    Protocol adapter that converts custom chat/message format to standard ACP session/prompt.
    """

    def __init__(
        self,
        acp_client,
        provider_id: str = None,
        workspace_cwd: str = None,
        on_request: Optional[Callable[[str, Dict[str, Any]], Any]] = None,
    ):
        self.acp = acp_client
        self.provider_id = provider_id
        self._workspace_cwd = workspace_cwd
        self._card_sessions = {}
        self.on_request = on_request

    def log(self, message: str):
        # Using print for visibility in bridge logs
        print(f"[Adapter] {message}", flush=True)

    def _build_prompt_item(self, content: str) -> Dict[str, Any]:
        """
        Build prompt item.
        Include both 'text' and 'content' for broad compatibility.
        """
        return {
            "type": "text", 
            "text": content,
            "content": content
        }

    async def initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle initialize request with full official capabilities.
        """
        if "workspace_path" in params:
            self._workspace_cwd = params["workspace_path"]
        elif "cwd" in params:
            self._workspace_cwd = params["cwd"]

        acp_params = {
            "capabilities": params.get("capabilities", {}),
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
        raw_prompt: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        """
        Convert chat/message to session/prompt and forward to ACP CLI.
        """
        self.log(f"Processing chat_message: {message[:50]}... (card_id: {card_id}, session_id: {acp_session_id})")

        sid_key = card_id or "default"
        session_id = acp_session_id or self._card_sessions.get(sid_key)

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

        # 1. Start listening BEFORE sending the request to avoid missing early notifications
        listener_id = str(uuid.uuid4())
        queue = self.acp.listen(listener_id)
        collected_text = []
        stop_event = asyncio.Event()

        async def collect_notifications():
            while not stop_event.is_set() or not queue.empty():
                try:
                    # Use a short timeout to check stop_event frequently
                    data = await asyncio.wait_for(queue.get(), timeout=0.1)

                    # Handle Server-to-Client Requests
                    if "method" in data and "id" in data:
                        self.log(f"[*] Nested request from brain: {data['method']} (id: {data['id']})")
                        if self.on_request:
                            async def handle_and_respond(req_id, method, params):
                                try:
                                    self.log(f"[*] Dispatching nested request to handler: {method}")
                                    result = await self.on_request(method, params)
                                    self.log(f"[*] Nested request handler returned: {result}")
                                    await self.acp.respond(req_id, result=result)
                                except Exception as re:
                                    self.log(f"[*] Nested request handler error: {re}")
                                    await self.acp.respond(req_id, error={"code": -32000, "message": str(re)})
                            asyncio.create_task(handle_and_respond(data["id"], data["method"], data.get("params", {})))
                        else:
                            self.log("[!] No on_request handler set for nested request")
                        continue

                    if on_notification:
                        await on_notification(data)

                    # Standard ACP updates
                    if data.get("method") == "session/update":
                        update = data.get("params", {}).get("update", {})
                        content = update.get("content", {})
                        if isinstance(content, dict) and "text" in content:
                            collected_text.append(content["text"])
                        # Support standardized content_block_delta
                        elif update.get("sessionUpdate") == "content_block_delta":
                            delta = update.get("delta", {})
                            if isinstance(delta, dict) and "text" in delta:
                                collected_text.append(delta["text"])
                    
                    # Custom Qwen Code slash command response
                    elif data.get("method") == "_qwencode/slash_command":
                        msg = data.get("params", {}).get("message", "")
                        if msg:
                            collected_text.append(msg)
                except asyncio.TimeoutError:
                    continue
                except Exception as e:
                    self.log(f"Notification error: {e}")
                    break

        # 2. Run collection in background
        collector_task = asyncio.create_task(collect_notifications())

        try:
            # 3. Send request and wait for JSON-RPC response
            # Use raw_prompt if provided, otherwise build from message
            prompt_payload = raw_prompt if raw_prompt else [self._build_prompt_item(message)]
            
            # Ensure every block has both 'text' and 'content' for broad compatibility
            # Skip empty content to prevent AI engine errors
            filtered_payload = []
            for block in prompt_payload:
                if block.get("type") == "text":
                    txt = block.get("text") or block.get("content") or ""
                    if txt.strip():
                        block["text"] = txt
                        block["content"] = txt
                        filtered_payload.append(block)
                else:
                    filtered_payload.append(block)

            if not filtered_payload:
                return {"error": {"code": -32602, "message": "Empty prompt content"}}

            response = await self.acp.request(
                "session/prompt",
                {
                    "sessionId": session_id,
                    "prompt": filtered_payload,
                },
            )
            
            # Allow some extra time for final notifications to arrive
            await asyncio.sleep(0.5)
            
        except Exception as e:
            stop_event.set()
            await collector_task
            return {"error": {"code": -32603, "message": f"Prompt failed: {str(e)}"}}
        finally:
            stop_event.set()
            await collector_task

        # Return collected text as result if successful
        return {"result": {"text": "".join(collected_text), "session_id": session_id}}

    async def _create_session(
        self, workspace_path: str = None, card_id: str = None
    ) -> str:
        project_cwd = workspace_path or self._workspace_cwd
        params = {
            "cwd": project_cwd,
        }
        
        # Add mcpServers to session/new params
        if self.provider_id and "openclaw" in self.provider_id.lower():
            self.log("OpenClaw detected: Skipping per-session mcpServers")
        else:
            params["mcpServers"] = tool_registry.get_mcp_servers()

        response = await self.acp.request("session/new", params)
        if "error" in response:
            raise Exception(f"Session creation failed: {response['error']}")
        
        session_id = response.get("result", {}).get("sessionId")
        return session_id

    async def _load_session(
        self, session_id: str, workspace_path: str = None, card_id: str = None
    ) -> tuple[Optional[str], str]:
        project_cwd = workspace_path or self._workspace_cwd
        try:
            params = {
                "sessionId": session_id,
                "cwd": project_cwd,
            }

            if self.provider_id and "openclaw" in self.provider_id.lower():
                pass
            else:
                params["mcpServers"] = tool_registry.get_mcp_servers()

            response = await self.acp.request("session/load", params)
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
        elif method == "session/new":
            # Add mcpServers to session/new params
            if self.provider_id and "openclaw" in self.provider_id.lower():
                self.log("OpenClaw detected: Skipping per-session mcpServers")
            else:
                params["mcpServers"] = tool_registry.get_mcp_servers()
            response = await self.acp.request("session/new", params)
            if "error" in response:
                raise Exception(f"Session creation failed: {response['error']}")
            session_id = response.get("result", {}).get("sessionId")
            self._workspace_cwd = params.get("cwd", self._workspace_cwd)
            return response.get("result", {})
        
        # Unified handling for prompt-like methods that generate notifications/requests
        elif method in ("chat/message", "session/prompt"):
            # Normalize params for chat_message
            prompt_text = params.get("message")
            if not prompt_text and "prompt" in params:
                # Convert list of content blocks to string for chat_message logic
                prompt_blocks = params["prompt"]
                if isinstance(prompt_blocks, list):
                    prompt_text = " ".join([b.get("text", "") for b in prompt_blocks if b.get("type") == "text"])
            
            # Map sessionId from standard ACP params to acp_session_id
            session_id = params.get("acp_session_id") or params.get("sessionId")
            
            return await self.chat_message(
                prompt_text or "",
                card_id=params.get("card_id"),
                workspace_path=params.get("workspace_path"),
                acp_session_id=session_id,
                on_notification=on_notification,
                raw_prompt=params.get("prompt")
            )
            
        elif method.startswith("fs/") or method.startswith("terminal/"):
            if self.on_request:
                result = await self.on_request(method, params)
                if result is not None:
                    # Note: acp.respond handles JSON-RPC wrapping
                    await self.acp.respond(params.get("_request_id"), result=result)
            return {"status": "delegated"}
        else:
            # For session/load or other direct methods, we also want to inject mcpServers if it is an initialization-like call
            if method == "session/load":
                 if self.provider_id and "openclaw" in self.provider_id.lower():
                    pass
                 else:
                    params["mcpServers"] = tool_registry.get_mcp_servers()

            response = await self.acp.request(method, params)
            if "result" in response:
                return response["result"]
            return response
