import asyncio
import websockets
import os
import json
import logging
import sys
import argparse
import time
import signal
import uuid
import difflib
from typing import Dict, Any, Optional, List, Callable
from datetime import datetime
from pathlib import Path

from src.transport.mdns import LocalDiscovery
from src.transport.e2ee import E2EEManager
from src.config.manager import config
from src.orchestration.dispatcher import MessageDispatcher
from src.persistence.database import KanbanDB
from src.logger import setup_logger, set_request_id

# Set up structured logger
logger = setup_logger("BridgeRelay")

class ConnectionState:
    """Manages the status of local and relay connections."""
    def __init__(self):
        self.local_clients = set()
        self.relay_ws = None
        self.running = True

    def add_local(self, ws):
        self.local_clients.add(ws)

    def remove_local(self, ws):
        self.local_clients.discard(ws)

    @property
    def is_relay_connected(self) -> bool:
        return self.relay_ws is not None and not self.relay_ws.closed

class TerminalProcess:
    def __init__(self, terminal_id, command, args, cwd, env=None, output_limit=1048576, on_output=None):
        self.terminal_id = terminal_id
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.output_limit = output_limit
        self.on_output_callback = on_output
        
        self.process = None
        self.output = ""
        self.truncated = False
        self.exit_code = None
        self.signal = None
        self._read_task = None
        self._queue = asyncio.Queue() # HIGH-1: Buffer queue
        self._stream_task = None

    async def start(self):
        full_env = os.environ.copy()
        if self.env:
            for e in self.env:
                full_env[e['name']] = str(e['value'])

        try:
            self.process = await asyncio.create_subprocess_exec(
                self.command,
                *self.args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=self.cwd,
                env=full_env
            )
            self._read_task = asyncio.create_task(self._read_output())
            self._stream_task = asyncio.create_task(self._process_queue())
            logger.info(f"Terminal {self.terminal_id} started: {self.command}")
        except Exception as e:
            self.exit_code = -1
            self.output = f"Failed to start process: {str(e)}"
            await self._queue.put(self.output)
            logger.error(f"Terminal start failed: {e}")

    async def _read_output(self):
        try:
            while True:
                line = await self.process.stdout.readline()
                if not line:
                    break
                
                text = line.decode('utf-8', errors='replace')
                self.output += text
                
                # HIGH-1: Put into queue for serial consumption
                await self._queue.put(text)
                
                if len(self.output) > self.output_limit:
                    self.output = self.output[-self.output_limit:]
                    self.truncated = True
            
            self.exit_code = await self.process.wait()
            await self._queue.put(None) # EOF
        except Exception as e:
            err = f"\n[Error reading output: {e}]"
            self.output += err
            await self._queue.put(err)
        finally:
            logger.info(f"Terminal {self.terminal_id} exited with {self.exit_code}")

    async def _process_queue(self):
        """HIGH-1: Consume output chunks sequentially."""
        while True:
            chunk = await self._queue.get()
            if chunk is None: break
            if self.on_output_callback:
                try:
                    await self.on_output_callback(chunk)
                except Exception as e:
                    logger.error(f"Stream error: {e}")
            self._queue.task_done()

    async def kill(self):
        if self._stream_task:
            self._stream_task.cancel()
        if self.process and self.process.returncode is None:
            try:
                self.process.terminate()
                # LOW-1: Wait with timeout
                try:
                    await asyncio.wait_for(self.process.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    try:
                        self.process.kill()
                        await self.process.wait()
                    except: pass
            except: pass

class UnifiedBridge:
    def __init__(
        self,
        user_id=None,
        relay_url=None,
        token=None,
        session_key=None,
        workspace_cwd=None,
        fallback_command=None,
    ):
        self.user_id = user_id or config.user_id
        self.relay_url = f"{(relay_url or config.relay_url).rstrip('/')}/relay/mac/{self.user_id}"
        self.token = token or config.get("relay.token")
        self._workspace_cwd = workspace_cwd or config.get("system.workspace_root")
        self._fallback_command = fallback_command

        self.db = KanbanDB()
        self.dispatcher = MessageDispatcher(self.db)
        self.local_discovery = LocalDiscovery(self.user_id)
        self.state = ConnectionState()

        # ECDH pair
        saved_keys = E2EEManager.load_key_pair(self.user_id)
        if saved_keys:
            self.private_key, self.public_key_hex = saved_keys
        else:
            self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
            E2EEManager.save_key_pair(self.user_id, self.private_key, self.public_key_hex)

        self.e2ee = E2EEManager(session_key_hex=session_key)
        self._pending_app_responses: Dict[str, asyncio.Future] = {}
        self._terminals: Dict[str, TerminalProcess] = {}

    async def stop(self):
        if not self.state.running: return
        self.state.running = False
        self.local_discovery.stop_broadcast()
        for term in list(self._terminals.values()):
            await term.kill()
        self._terminals.clear()
        await self.dispatcher.shutdown()
        if self.state.relay_ws:
            await self.state.relay_ws.close()
        await self.db.close_all_async()

    async def start(self):
        logger.info(f"Starting Unified Bridge. Workspace: {self._workspace_cwd}")
        self.local_discovery.start_broadcast()
        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", 8766)
        try:
            await asyncio.gather(local_server, self.maintain_relay_connection(), self.health_check_loop())
        except asyncio.CancelledError: pass
        finally: await self.stop()

    async def handle_local_client(self, websocket, path=None):
        self.state.add_local(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, websocket)
        finally:
            self.state.remove_local(websocket)

    async def maintain_relay_connection(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        while self.state.running:
            try:
                async with websockets.connect(self.relay_url, extra_headers=headers) as ws:
                    self.state.relay_ws = ws
                    async for message in ws:
                        await self.forward_to_acp(message, ws)
            except:
                if self.state.running: await asyncio.sleep(5)

    async def forward_to_acp(self, message, source_ws):
        if not self.state.running: return
        try:
            raw_data = json.loads(message)
            # Response handling
            if "id" in raw_data and "method" not in raw_data:
                resp_id = raw_data["id"]
                if resp_id in self._pending_app_responses:
                    future = self._pending_app_responses.pop(resp_id)
                    if "error" in raw_data:
                        future.set_exception(Exception(raw_data["error"].get("message")))
                    else:
                        future.set_result(raw_data.get("result"))
                    return

            data = raw_data
            original_was_e2ee = data.get("method") == "e2ee/envelope"
            if original_was_e2ee and self.e2ee.is_ready:
                data = self.e2ee.unwrap_json_rpc(message)

            if data.get("method") == "pairing/exchange":
                res = await self.handle_pairing(data)
                res["id"] = data.get("id")
                await source_ws.send(json.dumps(res))
                return

            async def on_output(output_data, is_request=False):
                if not is_request:
                    await self._send_acp_response(None, output_data, source_ws, original_was_e2ee, is_raw=True)
                else:
                    method = output_data.get("method")
                    params = output_data.get("params", {})
                    # HIGH-2 & HIGH-3: Pass ws context correctly
                    if method.startswith("fs/"):
                        return await self._handle_fs_method(method, params, source_ws, original_was_e2ee)
                    elif method.startswith("terminal/"):
                        return await self._handle_terminal_method(method, params, source_ws, original_was_e2ee)

                    internal_req_id = output_data.get("id") or str(uuid.uuid4())
                    output_data["id"] = internal_req_id
                    future = asyncio.get_running_loop().create_future()
                    self._pending_app_responses[internal_req_id] = future
                    await self._send_acp_response(None, output_data, source_ws, original_was_e2ee, is_raw=True)
                    try:
                        return await asyncio.wait_for(future, timeout=60.0)
                    except:
                        self._pending_app_responses.pop(internal_req_id, None)
                        return {"allow": False}

            response = await self.dispatcher.dispatch(data, on_output=on_output)
            if response:
                await self._send_acp_response(data.get("id"), response, source_ws, original_was_e2ee)
        except Exception as e:
            logger.error(f"forward_to_acp error: {e}")

    def _is_safe_path(self, path: Path) -> bool:
        try:
            workspace_root = Path(self._workspace_cwd).resolve()
            return workspace_root in path.resolve().parents or workspace_root == path.resolve()
        except: return False

    async def _handle_fs_method(self, method, params, source_ws, was_e2ee):
        path_str = params.get("path")
        if not path_str: return {"error": "Missing path"}
        try:
            abs_path = Path(path_str).resolve()
            if not self._is_safe_path(abs_path):
                return {"error": "Security Error: Path outside workspace"}
        except: return {"error": "Invalid path"}

        if method == "fs/read_text_file":
            try:
                line_start = params.get("line", 1)
                limit = params.get("limit")
                with open(abs_path, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                start = max(0, line_start - 1)
                result_lines = lines[start : start + limit] if limit else lines[start:]
                return {"content": "".join(result_lines)}
            except Exception as e: return {"error": str(e)}

        elif method == "fs/write_text_file":
            try:
                new_content = params.get("content", "")
                old_content = ""
                if abs_path.exists():
                    try:
                        with open(abs_path, 'r', encoding='utf-8') as f: old_content = f.read()
                    except: pass
                abs_path.parent.mkdir(parents=True, exist_ok=True)
                with open(abs_path, 'w', encoding='utf-8') as f: f.write(new_content)
                
                if old_content != new_content:
                    diff = "".join(difflib.unified_diff(old_content.splitlines(True), new_content.splitlines(True)))
                    if len(diff) > 5000: diff = diff[:5000] + "\n... (truncated)"
                    diff_id = f"diff_{abs_path.name}_{uuid.uuid4().hex[:4]}"
                    notif = {
                        "jsonrpc": "2.0", "method": "session/update",
                        "params": {
                            "sessionId": params.get("sessionId"),
                            "update": {
                                "sessionUpdate": "tool_call", "toolCallId": diff_id, "kind": "info",
                                "title": f"Edited {abs_path.name}",
                                "content": [{"type": "text", "text": f"Modified: `{abs_path.name}`\n```diff\n{diff}\n```"}]
                            }
                        }
                    }
                    await self._send_acp_response(None, notif, source_ws, was_e2ee, is_raw=True)
                return {} # HIGH-2: Result object
            except Exception as e: return {"error": str(e)}
        return {"error": "Unknown method"}

    async def _handle_terminal_method(self, method, params, source_ws, was_e2ee):
        if method == "terminal/create":
            term_id = f"term_{uuid.uuid4().hex[:8]}"
            sess_id = params.get("sessionId")
            tool_id = f"call_{term_id}"
            async def stream_handler(chunk):
                notif = {
                    "jsonrpc": "2.0", "method": "session/update",
                    "params": {
                        "sessionId": sess_id,
                        "update": {
                            "sessionUpdate": "tool_call", "toolCallId": tool_id, "status": "in_progress",
                            "content": [{"type": "text", "text": chunk}]
                        }
                    }
                }
                await self._send_acp_response(None, notif, source_ws, was_e2ee, is_raw=True)
            term = TerminalProcess(term_id, params.get("command"), params.get("args", []), 
                                   params.get("cwd") or self._workspace_cwd, params.get("env"), 
                                   params.get("outputByteLimit"), on_output=stream_handler)
            await term.start()
            self._terminals[term_id] = term
            return {"terminalId": term_id}

        term = self._terminals.get(params.get("terminalId"))
        if not term: return {"error": "Not found"}
        if method == "terminal/output":
            res = {"output": term.output, "truncated": term.truncated}
            if term.exit_code is not None: res["exitStatus"] = {"exitCode": term.exit_code}
            return res
        elif method == "terminal/wait_for_exit":
            while term.exit_code is None: await asyncio.sleep(0.5)
            return {"exitCode": term.exit_code}
        elif method == "terminal/kill" or method == "terminal/release":
            await term.kill()
            if method == "terminal/release": self._terminals.pop(term.terminal_id, None)
            return {}
        return {"error": "Unknown"}

    async def _send_acp_response(self, request_id, result, source_ws, was_e2ee, is_raw=False):
        response = result if is_raw else {"jsonrpc": "2.0", "id": request_id, "result": result}
        if is_raw:
            payload = json.dumps(response)
            for c in list(self.state.local_clients):
                try: await c.send(payload)
                except: self.state.remove_local(c)
        else:
            if was_e2ee and self.e2ee.is_ready: response = self.e2ee.wrap_json_rpc(response)
            try: await source_ws.send(json.dumps(response))
            except: pass
        if is_raw and self.state.is_relay_connected and self.e2ee.is_ready:
            try: await self.state.relay_ws.send(json.dumps(self.e2ee.wrap_json_rpc(response)))
            except: pass

    async def handle_pairing(self, data):
        pub = data.get("params", {}).get("publicKey")
        if not pub: return {"error": "No pubkey"}
        try:
            self.e2ee.setup_session(E2EEManager.derive_shared_secret(self.private_key, pub))
            return {"result": {"publicKey": self.public_key_hex, "status": "paired"}}
        except: return {"error": "Pairing error"}

    async def health_check_loop(self):
        while self.state.running: await asyncio.sleep(30)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--user-id"); p.add_argument("--relay-url"); p.add_argument("--token"); p.add_argument("--e2ee-key"); p.add_argument("--workspace-cwd")
    args = p.parse_args()
    b = UnifiedBridge(args.user_id, args.relay_url, token=args.token, session_key=args.e2ee_key, workspace_cwd=args.workspace_cwd)
    try: asyncio.run(b.start())
    except: pass

if __name__ == "__main__": main()
