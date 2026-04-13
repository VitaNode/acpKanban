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
        self._loop = asyncio.get_event_loop()

    def log(self, msg: str): 
        sys.stderr.write(f"[{datetime.now().isoformat()}] {msg}\n")
        sys.stderr.flush()

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
        future = self._loop.create_future()
        self._request_futures[rid] = future
        print(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}), flush=True)
        try:
            return await asyncio.wait_for(future, timeout=60.0)
        finally:
            self._request_futures.pop(rid, None)

    async def _execute_tool(self, session_id: str, tool_name: str, arguments: Dict[str, Any], tool_call_id: str):
        """Standardized Tool Execution (ACP 1.0 Compliant)."""
        try:
            # 1. Initial Call: sessionUpdate = "tool_call"
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "tool": tool_name,
                "title": f"Preparing {tool_name}",
                "kind": "edit" if "fs/" in tool_name else "call",
                "status": "pending"
            })

            # 2. Status Updates: sessionUpdate = "tool_call_update"
            await self._send_notification(session_id, "tool_call_update", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Requesting permission for {tool_name}"
            })
            
            # Permission check logic...
            res = await self.send_request("session/request_permission", {
                "sessionId": session_id,
                "toolCall": {"id": tool_call_id, "name": tool_name, "arguments": json.dumps(arguments)},
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Deny", "kind": "reject_once"}
                ]
            })
            if res.get("outcome", {}).get("optionId") != "allow-once":
                raise Exception("Denied")

            await self._send_notification(session_id, "tool_call_update", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Executing {tool_name}..."
            })

            # TODO: Actual execution logic here
            
            await self._send_notification(session_id, "tool_call_update", {
                "toolCallId": tool_call_id,
                "status": "completed",
                "title": f"Success: {tool_name}"
            })
        except Exception as e:
            await self._send_notification(session_id, "tool_call_update", {
                "toolCallId": tool_call_id,
                "status": "failed",
                "title": f"Failed: {str(e)}"
            })
