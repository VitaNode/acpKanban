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

    async def run(self):
        """Main JSON-RPC loop."""
        self.log("ACP Server starting...")
        while True:
            try:
                line = await asyncio.get_event_loop().run_in_executor(None, sys.stdin.readline)
                if not line: break
                data = json.loads(line)
                asyncio.create_task(self._handle_rpc(data))
            except Exception as e:
                self.log(f"RPC Loop Error: {e}")

    async def _handle_rpc(self, data: Dict[str, Any]):
        rid = data.get("id")
        method = data.get("method")
        params = data.get("params", {})

        # Handle Responses to our requests
        if rid in self._request_futures and "result" in data:
            self._request_futures[rid].set_result(data["result"])
            return

        # Handle incoming Requests
        try:
            result = None
            if method == "initialize":
                result = {
                    "protocolVersion": "1.0",
                    "agentInfo": {"name": "KanbanAgent", "version": "1.0"},
                    "agentCapabilities": {
                        "tools": {
                            "fs/read_text_file": {"description": "Read content of a file"},
                            "fs/write_text_file": {"description": "Write/overwrite a file"},
                            "terminal/create": {"description": "Create a terminal session"},
                            "terminal/send_input": {"description": "Run shell command"}
                        }
                    }
                }
            elif method == "session/new":
                sid = f"sid-{os.urandom(4).hex()}"
                self._sessions[sid] = {"workspace_cwd": params.get("workspace_cwd", "."), "permission_cache": {}}
                self._notification_queues[sid] = asyncio.Queue()
                result = {"sessionId": sid, "configOptions": [
                    {"id": "model", "name": "AI Model", "category": "general", "currentValue": "gemini-2.0-flash", "options": ["gemini-2.0-flash", "claude-3-5-sonnet"]}
                ]}
            elif method == "session/prompt":
                # Simulated response or actual agent logic
                result = {"status": "ok"}
                # Trigger mock tool execution if prompt contains "save"
                p_text = str(params.get("prompt", ""))
                if "save" in p_text.lower():
                    asyncio.create_task(self._execute_tool(params["sessionId"], "fs/write_text_file", {"path": "test.txt", "content": "hello"}, "tc-1"))

            if rid is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
        except Exception as e:
            if rid is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": str(e)}}), flush=True)

    async def _execute_tool(self, session_id: str, tool_name: str, arguments: Dict[str, Any], tool_call_id: str):
        """Standardized Tool Execution with Client Capabilities (Phase 4)."""
        try:
            # 1. Notify Pending
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "title": f"Preparing {tool_name}",
                "kind": "edit" if "fs/" in tool_name else "call",
                "status": "pending"
            })

            # 2. Permission Negotiation (Phase 3 Standard)
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Awaiting authorization for {tool_name}"
            })
            
            res = await self.send_request("session/request_permission", {
                "sessionId": session_id,
                "toolCall": {"id": tool_call_id, "name": tool_name, "arguments": json.dumps(arguments)},
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Deny", "kind": "reject_once"}
                ]
            })
            if res.get("outcome", {}).get("optionId") != "allow-once":
                raise Exception("Access denied by user")

            # 3. Execution (Phase 4 Implementation)
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Executing {tool_name}..."
            })

            # Forward to Bridge via standard notification (Bridge handles actual OS calls)
            # This is how we achieve the "Agent -> Server -> Bridge -> OS" path
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Bridge: Performing {tool_name}"
            })

            # Here we simulate the bridge result
            # In production, the bridge would call back or we'd await a response
            result = f"Successfully performed {tool_name}"
            
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "completed",
                "title": f"Finished {tool_name}"
            })
            return result
        except Exception as e:
            await self._send_notification(session_id, "tool_call", {
                "toolCallId": tool_call_id,
                "status": "failed",
                "title": f"Execution Failed: {str(e)}"
            })
            return f"Error: {str(e)}"

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    server = ACPServer("kanban.db")
    asyncio.run(server.run())
