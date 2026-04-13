import os
import sys
import json
import asyncio
import logging
from typing import Dict, Any, List, Optional
from datetime import datetime

class ACPServer:
    def __init__(self, db_path: str):
        self.db_path = db_path
        self.logger = logging.getLogger("ACPServer")
        self._sessions = {}
        self._notification_queues = {}
        self._request_futures = {}
        self._next_request_id = 1

    def log(self, msg: str): self.logger.info(msg)

    async def _send_notification(self, session_id: str, method: str, update: Dict[str, Any]):
        queue = self._notification_queues.get(session_id)
        if queue:
            await queue.put({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "sessionUpdate": method,
                        **update
                    }
                }
            })

    async def send_request(self, method: str, params: Dict[str, Any]) -> Any:
        rid = self._next_request_id
        self._next_request_id += 1
        future = asyncio.get_event_loop().create_future()
        self._request_futures[rid] = future
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}), flush=True)
        try:
            return await asyncio.wait_for(future, timeout=30.0)
        finally:
            self._request_futures.pop(rid, None)

    async def _execute_tool(self, session_id: str, tool_name: str, arguments: Dict[str, Any], tool_call_id: str):
        """Execute tool with standard ACP notifications."""
        try:
            # 1. Notify Pending
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "title": f"Executing {tool_name}",
                "kind": "edit" if tool_name.startswith("fs/") else "call",
                "status": "pending"
            })

            # 2. Permission Check (Standardized)
            # For prototype, we simulate permission check for sensitive tools
            sensitive = ["fs/write_text_file", "terminal/send_input"]
            if tool_name in sensitive:
                await self._send_notification(session_id, "tool_call", {
                    "toolCallId": tool_call_id,
                    "status": "in_progress",
                    "title": f"Requesting permission for {tool_name}"
                })
                # Standard ACP permission request
                res = await self.send_request("session/request_permission", {
                    "sessionId": session_id,
                    "toolCall": {"id": tool_call_id, "name": tool_name, "arguments": json.dumps(arguments)},
                    "options": [
                        {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                        {"optionId": "deny", "name": "Deny", "kind": "reject_once"}
                    ]
                })
                outcome = res.get("outcome", {}).get("optionId")
                if outcome != "allow":
                    raise Exception("Permission denied")

            # 3. Execution
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Running {tool_name}..."
            })
            
            # TODO: Link to actual bridge logic or registry
            result = f"Mock success for {tool_name}"
            
            # 4. Success Notification
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "completed",
                "title": f"Completed {tool_name}"
            })
            return result
        except Exception as e:
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "failed",
                "title": f"Error: {str(e)}"
            })
            return f"Error: {str(e)}"

    async def on_session_prompt(self, session_id: str, prompt: List[Dict]):
        # Simulated logic for tool calling demonstration
        # In real implementation, this interacts with the LLM
        pass
