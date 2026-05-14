import os
import sys
import json
import asyncio
import logging
from typing import Dict, Any, List, Optional
from datetime import datetime

class ACPServer:
    def __init__(self, db_path: str = "acp.db"):
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
        if rid in self._request_futures and ("result" in data or "error" in data):
            self._request_futures[rid].set_result(data.get("result") or data.get("error"))
            return

        # Handle incoming Requests
        try:
            result = None
            if method == "initialize":
                self._anchored_cwd = params.get("cwd")
                result = {
                    "protocolVersion": 1,
                    "agentInfo": {"name": "MockAgent", "version": "1.0", "title": "Mock ACP Agent"},
                    "authMethods": ["none"],
                    "agentCapabilities": {
                        "tools": {"supported": True},
                        "resources": {"supported": True}
                    }
                }
            elif method == "session/new":
                new_cwd = params.get("cwd", ".")
                # Ensure path is absolute for comparison
                abs_new_cwd = os.path.abspath(new_cwd)
                if hasattr(self, "_anchored_cwd") and self._anchored_cwd:
                    abs_anchored = os.path.abspath(self._anchored_cwd)
                    if not abs_new_cwd.startswith(abs_anchored):
                        if rid is not None:
                            print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32001, "message": "Workspace anchoring security violation"}}), flush=True)
                        return
                
                sid = f"sid-{os.urandom(4).hex()}"
                self._sessions[sid] = {"cwd": abs_new_cwd}
                self._notification_queues[sid] = asyncio.Queue()
                
                # Start notification sender for this session
                async def notif_sender(s_id):
                    q = self._notification_queues[s_id]
                    while s_id in self._sessions:
                        n = await q.get()
                        print(json.dumps(n), flush=True)
                
                asyncio.create_task(notif_sender(sid))
                
                result = {"sessionId": sid, "configOptions": []}
            elif method == "session/load":
                sid = params.get("sessionId")
                if sid in self._sessions:
                    result = None # ACP Standard: return null if session already in memory/active
                else:
                    result = None # Mock simplification
            elif method == "session/cancel":
                result = {"status": "cancelled"}
            elif method == "session/prompt":
                result = {"status": "ok", "stopReason": "completed"}
                # Trigger mock tool execution if prompt contains "test"
                p_text = str(params.get("prompt", ""))
                if "test" in p_text.lower():
                    sid = params.get("sessionId")
                    asyncio.create_task(self._execute_tool(sid, "test/tool", {"arg": 1}, "tc-1"))
            elif method == "test/request_permission":
                # Special method for TestACPPermission
                sid = params.get("sessionId")
                res = await self.send_request("session/request_permission", {
                    "sessionId": sid,
                    "toolCall": {"id": "test-call", "name": "test-tool"},
                    "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]
                })
                # Check for old boolean 'allow' or new outcome structure
                is_allowed = False
                if isinstance(res, dict):
                    if "allow" in res: is_allowed = res["allow"]
                    elif "outcome" in res: is_allowed = res["outcome"].get("optionId") == "allow"
                
                result = {"toolResult": "Success" if is_allowed else "Permission denied"}

            if rid is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
        except Exception as e:
            if rid is not None:
                print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": str(e)}}), flush=True)

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
            res_obj = await self.send_request("session/request_permission", {
                "sessionId": session_id,
                "toolCall": {"id": tool_call_id, "name": tool_name, "arguments": json.dumps(arguments)},
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Deny", "kind": "reject_once"}
                ]
            })
            
            # Extract outcome or legacy allow boolean
            is_allowed = False
            if isinstance(res_obj, dict):
                if "outcome" in res_obj:
                    is_allowed = res_obj["outcome"].get("optionId") == "allow-once"
                elif "allow" in res_obj:
                    is_allowed = res_obj["allow"]
            
            if not is_allowed:
                self.log(f"Permission denied for {tool_name}")
                await self._send_notification(session_id, "tool_call_update", {
                    "toolCallId": tool_call_id,
                    "status": "failed",
                    "title": f"Permission denied for {tool_name}"
                })
                return

            await self._send_notification(session_id, "tool_call_update", {
                "toolCallId": tool_call_id,
                "status": "in_progress",
                "title": f"Executing {tool_name}..."
            })

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

if __name__ == "__main__":
    server = ACPServer()
    asyncio.run(server.run())
