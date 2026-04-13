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
    """Manages the status of local and relay connections (P2-1 FIX)."""
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
        self.on_output_callback = on_output # Callback for streaming
        
        self.process = None
        self.output = ""
        self.truncated = False
        self.exit_code = None
        self.signal = None
        self._read_task = None

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
            logger.info(f"Terminal {self.terminal_id} started: {self.command}")
        except Exception as e:
            self.exit_code = -1
            self.output = f"Failed to start process: {str(e)}"
            if self.on_output_callback:
                asyncio.create_task(self.on_output_callback(self.output))
            logger.error(f"Terminal start failed: {e}")

    async def _read_output(self):
        try:
            while True:
                line = await self.process.stdout.readline()
                if not line:
                    break
                
                text = line.decode('utf-8', errors='replace')
                self.output += text
                
                # Proactive stream
                if self.on_output_callback:
                    asyncio.create_task(self.on_output_callback(text))
                
                # Truncate if limit exceeded
                if len(self.output) > self.output_limit:
                    self.output = self.output[-self.output_limit:]
                    self.truncated = True
            
            self.exit_code = await self.process.wait()
        except Exception as e:
            err_msg = f"\n[Error reading output: {e}]"
            self.output += err_msg
            if self.on_output_callback:
                asyncio.create_task(self.on_output_callback(err_msg))
        finally:
            logger.info(f"Terminal {self.terminal_id} exited with {self.exit_code}")

    async def kill(self):
        if self.process and self.process.returncode is None:
            try:
                self.process.terminate()
                await self.process.wait()
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

        # ECDH pair for initial handshake
        saved_keys = E2EEManager.load_key_pair(self.user_id)
        if saved_keys:
            self.private_key, self.public_key_hex = saved_keys
            logger.info(f"Loaded existing ECDH key pair for user: {self.user_id}")
        else:
            self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
            E2EEManager.save_key_pair(self.user_id, self.private_key, self.public_key_hex)
            logger.info(f"Generated new ECDH key pair for user: {self.user_id}")

        self.e2ee = E2EEManager(session_key_hex=session_key)
        
        # N3: Track requests sent to Flutter App
        self._pending_app_responses: Dict[str, asyncio.Future] = {}
        
        # Phase 4.1: Client Capabilities state
        self._terminals: Dict[str, TerminalProcess] = {}

    async def stop(self):
        """Gracefully stop the bridge and all child processes."""
        if not self.state.running:
            return
        
        logger.info("Graceful shutdown initiated...")
        self.state.running = False
        self.local_discovery.stop_broadcast()
        
        # Phase 4.1: Kill all terminals
        for term in list(self._terminals.values()):
            await term.kill()
        self._terminals.clear()
        
        # 1. Stop all engines and tasks via dispatcher
        await self.dispatcher.shutdown()

        # 2. Close relay connection
        if self.state.relay_ws:
            await self.state.relay_ws.close()
            self.state.relay_ws = None

        # 3. Close database connections
        await self.db.close_all_async()
        
        logger.info("Graceful shutdown complete.")

    async def start(self):
        logger.info(f"Starting Unified Bridge for User: {self.user_id}")
        logger.info(f"Pairing Public Key: {self.public_key_hex}")
        logger.info(f"Workspace: {self._workspace_cwd}")

        # Register signal handlers
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, lambda: asyncio.create_task(self.stop()))
            except NotImplementedError:
                pass

        self.local_discovery.start_broadcast()

        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", 8766)
        logger.info("Local Server listening on ws://0.0.0.0:8766")

        try:
            await asyncio.gather(
                local_server, 
                self.maintain_relay_connection(), 
                self.health_check_loop()
            )
        except asyncio.CancelledError:
            logger.info("Bridge tasks cancelled.")
        finally:
            await self.stop()

    async def handle_local_client(self, websocket, path=None):
        addr = websocket.remote_address
        logger.info(f"New local client connected: {addr}")
        self.state.add_local(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, websocket)
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Local client {addr} disconnected.")
        finally:
            self.state.remove_local(websocket)

    async def maintain_relay_connection(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        while self.state.running:
            try:
                async with websockets.connect(
                    self.relay_url,
                    ping_interval=30,
                    ping_timeout=10,
                    extra_headers=headers,
                ) as ws:
                    logger.info("Connected to Cloud Relay.")
                    self.state.relay_ws = ws
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, ws)
                    finally:
                        self.state.relay_ws = None
            except Exception:
                if self.state.running:
                    await asyncio.sleep(5)

    async def forward_to_acp(self, message, source_ws):
        """
        Forward message to Dispatcher.
        """
        if not self.state.running:
            return

        addr = (
            source_ws.remote_address
            if hasattr(source_ws, "remote_address")
            else "relay"
        )
        try:
            # Handle Response from App (N3: Link closure)
            try:
                raw_data = json.loads(message)
                if "id" in raw_data and ("result" in raw_data or "error" in raw_data) and "method" not in raw_data:
                    resp_id = raw_data["id"]
                    if resp_id in self._pending_app_responses:
                        logger.info(f"Received Response from App for internal request {resp_id}")
                        future = self._pending_app_responses.pop(resp_id)
                        if "error" in raw_data:
                            future.set_exception(Exception(raw_data["error"].get("message", "App error")))
                        else:
                            future.set_result(raw_data.get("result"))
                        return
            except: pass

            data = json.loads(message)
            req_id = data.get("id")
            set_request_id(req_id if isinstance(req_id, str) else None)
            
            original_was_e2ee = data.get("method") == "e2ee/envelope"

            # Handle Pairing
            if data.get("method") == "pairing/exchange":
                response = await self.handle_pairing(data)
                response["id"] = data.get("id")
                response["jsonrpc"] = "2.0"
                await source_ws.send(json.dumps(response))
                return

            # Handle E2EE Envelope
            if original_was_e2ee:
                if not self.e2ee.is_ready:
                    logger.warning(f"Received E2EE envelope from {addr} but session not ready.")
                    return
                try:
                    data = self.e2ee.unwrap_json_rpc(message)
                except Exception as e:
                    logger.error(f"Failed to decrypt E2EE message from {addr}: {e}")
                    return

            # --- ROUTE TO DISPATCHER ---
            async def on_output(output_data, is_request=False):
                if not is_request:
                    await self._send_acp_response(None, output_data, source_ws, original_was_e2ee, is_raw=True)
                else:
                    method = output_data.get("method")
                    params = output_data.get("params", {})
                    
                    # Phase 4.1: Handle FS and Terminal methods locally
                    if method.startswith("fs/"):
                        return await self._handle_fs_method(method, params, source_ws, original_was_e2ee)
                    elif method.startswith("terminal/"):
                        return await self._handle_terminal_method(method, params)

                    # Send Request to App and WAIT for response
                    internal_req_id = output_data.get("id") or str(uuid.uuid4())
                    output_data["id"] = internal_req_id
                    
                    future = asyncio.get_running_loop().create_future()
                    self._pending_app_responses[internal_req_id] = future
                    
                    logger.info(f"Sending Nested Request to App: {output_data.get('method')} (id: {internal_req_id})")
                    await self._send_acp_response(None, output_data, source_ws, original_was_e2ee, is_raw=True)
                    
                    try:
                        return await asyncio.wait_for(future, timeout=60.0) 
                    except asyncio.TimeoutError:
                        self._pending_app_responses.pop(internal_req_id, None)
                        return {"allow": False, "error": "Timeout waiting for user approval"}

            response = await self.dispatcher.dispatch(data, on_output=on_output)
            
            if response:
                await self._send_acp_response(data.get("id"), response, source_ws, original_was_e2ee)

        except json.JSONDecodeError:
            logger.warning(f"Received non-JSON message from {addr}")
        except Exception as e:
            logger.error(f"Error in forward_to_acp: {e}")

    async def _send_acp_response(self, request_id, result, source_ws, was_e2ee, is_raw=False):
        """Send response back to the client."""
        if is_raw:
            response = result
        else:
            response = {"jsonrpc": "2.0", "id": request_id}
            if isinstance(result, dict) and "error" in result:
                response["error"] = result["error"]
            else:
                response["result"] = result

        # 1. Local clients receive plaintext or E2EE depending on how they connected
        # Notifications are broadcast to all local clients
        if is_raw:
            payload = json.dumps(response)
            for client in list(self.state.local_clients):
                try:
                    await client.send(payload)
                except Exception:
                    self.state.remove_local(client)

        # 2. Specific response goes back to source
        else:
            try:
                # Responses are ALWAYS sent back in the format they arrived (E2EE if source was E2EE)
                final_resp = response
                if was_e2ee and self.e2ee.is_ready:
                    final_resp = self.e2ee.wrap_json_rpc(response)
                await source_ws.send(json.dumps(final_resp))
            except Exception as e:
                logger.debug(f"Failed to send response back to client: {e}")

        # 3. Forward to Relay if it's a notification and relay is connected
        if is_raw and self.state.is_relay_connected and self.e2ee.is_ready:
            try:
                encrypted_env = self.e2ee.wrap_json_rpc(response)
                await self.state.relay_ws.send(json.dumps(encrypted_env))
            except Exception as e:
                logger.error(f"Relay send error: {e}")

    async def handle_pairing(self, data):
...
        except Exception as e:
            logger.error(f"Pairing failed: {e}")
            return {"error": "Pairing calculation error"}

    def _is_safe_path(self, path: Path) -> bool:
        """Checks if the path is within the allowed workspace."""
        try:
            workspace_root = Path(self._workspace_cwd).resolve()
            return workspace_root in path.parents or workspace_root == path
        except:
            return False

    async def _handle_fs_method(self, method, params, source_ws, was_e2ee):
        path_str = params.get("path")
        if not path_str:
            return {"error": "Missing path"}
        
        # Security: Normalize and resolve
        try:
            abs_path = Path(path_str).resolve()
            if not self._is_safe_path(abs_path):
                return {"error": f"Security Error: Path {path_str} is outside of workspace."}
        except Exception as e:
            return {"error": f"Invalid path: {e}"}

        if method == "fs/read_text_file":
            try:
                line_start = params.get("line", 1)
                limit = params.get("limit")
                
                if not abs_path.exists():
                    return {"error": f"File not found: {path_str}"}

                with open(abs_path, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                    
                start_idx = max(0, line_start - 1)
                if limit:
                    lines = lines[start_idx : start_idx + limit]
                else:
                    lines = lines[start_idx:]
                    
                return {"content": "".join(lines)}
            except Exception as e:
                return {"error": f"Read failed: {e}"}

        elif method == "fs/write_text_file":
            try:
                new_content = params.get("content", "")
                old_content = ""
                file_existed = abs_path.exists()
                
                # 1. Read old content for diff if file exists
                if file_existed:
                    try:
                        with open(abs_path, 'r', encoding='utf-8') as f:
                            old_content = f.read()
                    except: pass

                # 2. Perform the write
                abs_path.parent.mkdir(parents=True, exist_ok=True)
                with open(abs_path, 'w', encoding='utf-8') as f:
                    f.write(new_content)

                # 3. Generate Diff and notify UI
                if old_content != new_content:
                    diff = "".join(difflib.unified_diff(
                        old_content.splitlines(keepends=True),
                        new_content.splitlines(keepends=True),
                        fromfile=f"a/{abs_path.name}",
                        tofile=f"b/{abs_path.name}"
                    ))
                    
                    # Send an out-of-band notification to the UI to render the diff
                    # We link this to the current card via metadata if available
                    diff_notification = {
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": params.get("sessionId"),
                            "update": {
                                "sessionUpdate": "tool_call",
                                "kind": "info",
                                "title": f"Edited {abs_path.name}",
                                "content": [
                                    {"type": "text", "text": f"Modified file: `{abs_path.relative_to(self._workspace_cwd)}`"},
                                    {"type": "text", "text": f"```diff\n{diff}\n```"}
                                ]
                            }
                        }
                    }
                    await self._send_acp_response(None, diff_notification, source_ws, was_e2ee, is_raw=True)

                return None
            except Exception as e:
                return {"error": f"Write failed: {e}"}
        
        return {"error": f"Method {method} not implemented"}

    async def _handle_terminal_method(self, method, params, source_ws, was_e2ee):
        if method == "terminal/create":
            terminal_id = f"term_{uuid.uuid4().hex[:8]}"
            session_id = params.get("sessionId")
            
            # Streaming callback
            async def stream_handler(chunk):
                # Send terminal update notification
                notif = {
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {
                            "sessionUpdate": "tool_call",
                            "kind": "execute",
                            "title": "Terminal Output",
                            "status": "in_progress",
                            "content": [
                                {"type": "text", "text": f"Terminal `{terminal_id}` output:"},
                                {"type": "text", "text": f"```\n{chunk}\n```"}
                            ]
                        }
                    }
                }
                await self._send_acp_response(None, notif, source_ws, was_e2ee, is_raw=True)

            command = params.get("command")
            args = params.get("args", [])
            cwd = params.get("cwd") or self._workspace_cwd
            env = params.get("env", [])
            limit = params.get("outputByteLimit", 1048576)
            
            term = TerminalProcess(terminal_id, command, args, cwd, env, limit, on_output=stream_handler)
            await term.start()
            self._terminals[terminal_id] = term
            return {"terminalId": terminal_id}

        terminal_id = params.get("terminalId")
        term = self._terminals.get(terminal_id)
        if not term:
            return {"error": f"Terminal {terminal_id} not found"}

        if method == "terminal/output":
            result = {
                "output": term.output,
                "truncated": term.truncated
            }
            if term.exit_code is not None:
                result["exitStatus"] = {"exitCode": term.exit_code, "signal": term.signal}
            return result

        elif method == "terminal/wait_for_exit":
            while term.exit_code is None:
                await asyncio.sleep(0.5)
            return {"exitCode": term.exit_code, "signal": term.signal}

        elif method == "terminal/kill":
            await term.kill()
            return None

        elif method == "terminal/release":
            await term.kill()
            self._terminals.pop(terminal_id, None)
            return None

        return {"error": f"Method {method} not implemented"}

    async def health_check_loop(self):
        while self.state.running:
            await asyncio.sleep(30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", default=None)
    parser.add_argument("--relay-url", default=None)
    parser.add_argument("--token", help="Relay Auth Token")
    parser.add_argument("--e2ee-key", help="Hex Key for E2EE Session")
    parser.add_argument("--workspace-cwd", help="Default workspace path")
    args = parser.parse_args()

    bridge = UnifiedBridge(
        args.user_id,
        args.relay_url,
        token=args.token,
        session_key=args.e2ee_key,
        workspace_cwd=args.workspace_cwd
    )

    try:
        asyncio.run(bridge.start())
    except (KeyboardInterrupt, SystemExit):
        pass
    except Exception as e:
        logger.critical(f"Bridge crashed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
