import asyncio
import json
import logging
import uuid
import argparse
import sys
import os
import base64
import websockets
import httpx
from typing import Dict, Any, Optional, Callable, Set
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

from src.orchestration.dispatcher import MessageDispatcher
from src.persistence.database import KanbanDB
from src.transport.bus import bus
from src.logger import setup_logger

class UnifiedBridge:
    def __init__(self, user_id, relay_url, token=None, session_key=None, workspace_cwd=None):
        self.logger = setup_logger(f"Bridge[{user_id[:8]}]")
        self.user_id = user_id
        self.relay_url = relay_url
        self.token = token
        self.db = KanbanDB()
        self._pending_ui_requests: Dict[str, asyncio.Future] = {}
        self.dispatcher = MessageDispatcher(self.db, ui_requests=self._pending_ui_requests)
        self._local_clients: Set[websockets.WebSocketServerProtocol] = set()
        self._client_e2ee_secrets: Dict[websockets.WebSocketServerProtocol, bytes] = {}
        
        # Generate Bridge X25519 Key Pair for E2EE
        self._bridge_private_key = X25519PrivateKey.generate()
        self._bridge_public_key_hex = self._bridge_private_key.public_key().public_bytes(
            encoding=Encoding.Raw,
            format=PublicFormat.Raw
        ).hex()
        
        # HTTP client for proxying requests to local API
        self._proxy_client = httpx.AsyncClient(
            base_url="http://localhost:8000",
            timeout=30.0
        )
        # Card Session WebSocket Map: card_id -> WebSocketConnection
        self._card_sessions: Dict[str, websockets.WebSocketClientProtocol] = {}

    async def start(self, run_forever=True):
        """Starts both local and relay servers."""
        self.logger.info(f"Bridge starting for user {self.user_id}...")

        # 1. Start Relay Connection (if URL provided)
        if self.relay_url:
            asyncio.create_task(self._run_relay_loop())

        # 2. Start Local WebSocket Server (port 8766) for direct tool access
        self._server = await websockets.serve(
            self._handle_local_client,
            "0.0.0.0",
            8766,
            ping_interval=20,
            ping_timeout=20,
        )
        self.logger.info(f"Local tool bridge started on ws://0.0.0.0:8766 (PubKey: {self._bridge_public_key_hex[:16]}...)")
        
        if run_forever:
            # Keep the server running
            try:
                await asyncio.Future()  # Run forever
            except asyncio.CancelledError:
                await self.stop()

    async def stop(self):
        """Stop the local websocket server."""
        if hasattr(self, '_server'):
            self._server.close()
            await self._server.wait_closed()
            self.logger.info("Local tool bridge stopped")
        
        # Close proxy client
        await self._proxy_client.aclose()
        self.logger.info("Proxy client closed")

    async def _handle_local_client(self, websocket):
        """Handle incoming WebSocket connections from Flutter or local tools."""
        self._local_clients.add(websocket)
        self.logger.info(f"Client connected: {websocket.remote_address}")
        try:
            async for message in websocket:
                try:
                    data = json.loads(message)
                    self.logger.debug(f"Received: {data.get('method', 'N/A')} (id: {data.get('id')})")

                    # Handle E2EE pairing request
                    if data.get('method') == 'pairing/exchange':
                        await self._handle_pairing_exchange(websocket, data)
                        continue

                    # Handle E2EE encrypted messages
                    if data.get('method') == 'e2ee/envelope':
                        secret = self._client_e2ee_secrets.get(websocket)
                        if not secret:
                            self.logger.warning("Received encrypted message but no shared secret (pairing not done)")
                            continue

                        # Decrypt
                        inner_data = self._decrypt_message(secret, data.get('params', {}))
                        if inner_data:
                            self.logger.debug(f"Decrypted: {inner_data.get('method', 'N/A')} (id: {inner_data.get('id')})")
                            # Process RPC and send encrypted response
                            request_id = inner_data.get('id')
                            
                            async def encrypted_output(n):
                                self._send_response(websocket, n, secret)
                            
                            result = await self.handle_rpc(inner_data, encrypted_output)
                            
                            # If handle_rpc returned a result (for request-response), send it back
                            if result and request_id is not None:
                                # Check if it's an error
                                if isinstance(result, dict) and "error" in result:
                                    response = {
                                        "jsonrpc": "2.0",
                                        "id": request_id,
                                        "error": result["error"]
                                    }
                                else:
                                    response = {
                                        "jsonrpc": "2.0",
                                        "id": request_id,
                                        "result": result
                                    }
                                self._send_response(websocket, response, secret)
                            continue
                        else:
                            self.logger.error("Decryption failed")
                            continue

                    # Handle unencrypted RPC
                    await self.handle_rpc(data, lambda n: self._send_response(websocket, n, None))
                except json.JSONDecodeError:
                    self.logger.warning(f"Invalid JSON: {message[:100]}")
                except Exception as e:
                    self.logger.error(f"RPC handling error: {e}", exc_info=True)
        except websockets.exceptions.ConnectionClosed:
            self.logger.info(f"Client disconnected: {websocket.remote_address}")
        except Exception as e:
            self.logger.error(f"Client error: {e}", exc_info=True)
        finally:
            self._local_clients.discard(websocket)
            self._client_e2ee_secrets.pop(websocket, None)
            self.logger.info(f"Client removed: {websocket.remote_address}")

    async def _handle_pairing_exchange(self, websocket, data):
        """Handle E2EE pairing/exchange request with real crypto."""
        request_id = data.get('id')
        params = data.get('params', {})
        client_public_key_hex = params.get('publicKey')
        
        if not client_public_key_hex:
            self.logger.error("Pairing request missing publicKey")
            return
        
        self.logger.info(f"Pairing request from {websocket.remote_address}, client public key: {client_public_key_hex[:20]}...")
        
        try:
            # Derive shared secret (ECDH)
            client_public_key_bytes = bytes.fromhex(client_public_key_hex)
            client_public_key = X25519PublicKey.from_public_bytes(client_public_key_bytes)
            shared_secret = self._bridge_private_key.exchange(client_public_key)
            
            # Store secret for this websocket
            self._client_e2ee_secrets[websocket] = shared_secret
            
            # Send response with Bridge public key
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "publicKey": self._bridge_public_key_hex
                }
            }
            
            # Send unencrypted (pairing response is plaintext)
            await websocket.send(json.dumps(response))
            
            self.logger.info("Pairing response sent (unencrypted)")
            
        except Exception as e:
            self.logger.error(f"Pairing exchange failed: {e}", exc_info=True)
            await websocket.send(json.dumps({
                "jsonrpc": "2.0", "id": request_id,
                "error": {"code": -32603, "message": f"Pairing failed: {str(e)}"}
            }))

    def _decrypt_message(self, shared_secret: bytes, envelope: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Decrypt an E2EE envelope (Flutter-compatible format).
        
        Flutter format: {"payload": "<base64(Nonce 12B + Ciphertext + Tag 16B)>"}
        """
        try:
            payload_b64 = envelope.get('payload')
            if not payload_b64:
                self.logger.error("Missing 'payload' in envelope")
                return None
            
            # Decode base64 payload
            payload = base64.b64decode(payload_b64)
            
            # Parse Flutter format: Nonce (12B) + Ciphertext + Tag (16B)
            nonce = payload[:12]
            tag = payload[-16:]
            ciphertext = payload[12:-16]
            
            # Derive key using HKDF (same as Flutter)
            hkdf = HKDF(
                algorithm=hashes.SHA256(),
                length=32,
                salt=None,
                info=b'mybot-e2ee-x25519-context',
            )
            key = hkdf.derive(shared_secret)
            
            # Decrypt
            aesgcm = AESGCM(key)
            plaintext = aesgcm.decrypt(nonce, ciphertext + tag, None)
            
            return json.loads(plaintext.decode('utf-8'))
        except Exception as e:
            self.logger.error(f"Decryption failed: {e}")
            return None

    def _send_response(self, websocket, data: Any, shared_secret: Optional[bytes]):
        """Send response, encrypting if shared secret exists (Flutter-compatible format)."""
        if shared_secret and isinstance(data, dict):
            try:
                # Derive key using HKDF (same as Flutter)
                hkdf = HKDF(
                    algorithm=hashes.SHA256(),
                    length=32,
                    salt=None,
                    info=b'mybot-e2ee-x25519-context',
                )
                key = hkdf.derive(shared_secret)
                
                # Encrypt
                aesgcm = AESGCM(key)
                nonce = os.urandom(12)
                plaintext = json.dumps(data).encode('utf-8')
                ct_with_tag = aesgcm.encrypt(nonce, plaintext, None)
                
                # Flutter format: base64(Nonce + Ciphertext + Tag)
                payload = base64.b64encode(nonce + ct_with_tag).decode('utf-8')
                data = {
                    "method": "e2ee/envelope",
                    "params": {"payload": payload}
                }
            except Exception as e:
                self.logger.error(f"Encryption failed: {e}")
        
        future = websocket.send(json.dumps(data))
        asyncio.ensure_future(future)

    async def _run_relay_loop(self):
        headers = {"X-User-ID": self.user_id}
        if self.token: headers["Authorization"] = f"Bearer {self.token}"

        # Build full relay URL: ws://host:port/relay/mac/user_id
        base_url = self.relay_url.rstrip("/")
        full_url = f"{base_url}/relay/mac/{self.user_id}"

        while True:
            try:
                # websockets >= 13.0 uses additional_headers instead of extra_headers
                connect_kwargs = {"additional_headers": headers}
                # Fallback for older versions
                try:
                    async with websockets.connect(full_url, **connect_kwargs) as ws:
                        await self._handle_relay_connection(ws)
                except TypeError:
                    # Old version fallback
                    connect_kwargs = {"extra_headers": headers}
                    async with websockets.connect(full_url, **connect_kwargs) as ws:
                        await self._handle_relay_connection(ws)
            except Exception as e:
                self.logger.error(f"Relay error: {e}. Retrying in 5s...")
                await asyncio.sleep(5)

    async def _handle_relay_connection(self, ws):
        """Handle an established relay connection."""
        self.logger.info("Connected to Relay Server")
        
        async def relay_send(msg_dict):
            # If we have an established secret, wrap in E2EE envelope
            secret = getattr(self, "_relay_e2ee_secret", None)
            
            # Check if this is a pairing response (should always be plaintext)
            is_pairing_res = "result" in msg_dict and isinstance(msg_dict["result"], dict) and "publicKey" in msg_dict["result"]
            is_pairing_req = msg_dict.get("method") == "pairing/exchange"
            
            if secret and not is_pairing_req and not is_pairing_res:
                from src.transport.e2ee import encrypt_message
                payload = encrypt_message(json.dumps(msg_dict), secret)
                wrapped = {
                    "jsonrpc": "2.0",
                    "method": "e2ee/envelope",
                    "params": {"payload": payload}
                }
                await ws.send(json.dumps(wrapped))
            else:
                await ws.send(json.dumps(msg_dict))

        async for message in ws:
            try:
                data = json.loads(message)
                # handle_rpc will now handle decryption and dispatching
                await self.handle_rpc(data, relay_send)
            except Exception as e:
                self.logger.error(f"Error handling relay message: {e}")

    async def on_ui_response(self, request_id: str, result: Any) -> bool:
        """Phase 3.2: Standardized UI Response Resolver."""
        future = self._pending_ui_requests.pop(request_id, None)
        if future and not future.done():
            future.set_result(result)
            return True
        return False

    async def handle_rpc(self, data: Dict[str, Any], send_output: Callable):
        # Wrap the output to await it correctly
        async def safe_send(msg):
            try: await send_output(msg)
            except Exception as e:
                self.logger.error(f"Failed to send output: {e}")

        method = data.get("method")
        params = data.get("params", {})
        request_id = data.get("id")

        # 1. Handle Response (Result/Error) from UI
        if request_id and ("result" in data or "error" in data):
            future = self._pending_ui_requests.pop(str(request_id), None)
            if future and not future.done():
                future.set_result(data.get("result") if "result" in data else data.get("error"))
            return

        # 2. Handle E2EE Envelope
        if method == "e2ee/envelope":
            payload = params.get("payload")
            # We need to know which client sent this to find the right secret.
            # For Relay, there's only one "client" (the App). 
            # We'll use a special marker or store the last secret.
            secret = getattr(self, "_relay_e2ee_secret", None)
            if not secret:
                self.logger.error("Received E2EE envelope but no relay secret established")
                return

            from src.transport.e2ee import decrypt_message
            try:
                decrypted_str = decrypt_message(payload, secret)
                decrypted_data = json.loads(decrypted_str)
                # Re-route decrypted content
                await self.handle_rpc(decrypted_data, send_output)
                return
            except Exception as e:
                self.logger.error(f"Failed to decrypt relay message: {e}")
                return

        # 2. Handle Pairing (ECDH)
        if method == "pairing/exchange":
            client_pub_hex = params.get("publicKey")
            if not client_pub_hex:
                await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Missing publicKey"}})
                return

            from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
            from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
            
            client_pub = X25519PublicKey.from_public_bytes(bytes.fromhex(client_pub_hex))
            shared_secret = self._bridge_private_key.exchange(client_pub)
            
            # Store secret for this connection (Relay mode uses a single secret for now)
            self._relay_e2ee_secret = shared_secret
            
            await safe_send({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"publicKey": self._bridge_public_key_hex}
            })
            self.logger.info(f"Relay E2EE Pairing established with client")
            return

        # 3. Handle Initialize
        if method == "initialize":
            await safe_send({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": 0,
                    "capabilities": {
                        "tools": {"supported": True},
                        "resources": {"supported": True}
                    }
                }
            })
            return

        # 4. Handle API Proxying
        if method == "http/proxy":
            path = params.get("path")
            http_method = params.get("method", "GET").upper()
            body = params.get("body")
            headers = params.get("headers", {})

            self.logger.debug(f"Proxying {http_method} {path}")
            try:
                response = await self._proxy_client.request(
                    method=http_method,
                    url=path,
                    json=body,
                    headers=headers
                )
                
                # Check if it's JSON
                try:
                    resp_data = response.json()
                except:
                    resp_data = response.text

                await safe_send({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "statusCode": response.status_code,
                        "body": resp_data if isinstance(resp_data, str) else json.dumps(resp_data)
                    }
                })
            except Exception as e:
                self.logger.error(f"Proxy error: {e}")
                await safe_send({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": 500, "message": f"Proxy error: {str(e)}"}
                })
            return

        if method == "session/ws_proxy":
            action = params.get("action")
            card_id = params.get("card_id")
            if not card_id:
                await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Missing card_id"}})
                return

            if action == "connect":
                ws_url = f"ws://127.0.0.1:8000/api/ws/session/{card_id}"
                self.logger.info(f"Connecting proxy WS to {ws_url}")
                try:
                    # Clean up old session if exists
                    if card_id in self._card_sessions:
                        await self._card_sessions[card_id].close()
                    
                    ws = await websockets.connect(ws_url)
                    self._card_sessions[card_id] = ws
                    
                    # Spawn listener for this card session
                    async def ws_listener():
                        try:
                            async for message in ws:
                                # Relay back to mobile via ACP Notification
                                notification = {
                                    "jsonrpc": "2.0",
                                    "method": "session/ws_event",
                                    "params": {
                                        "card_id": card_id,
                                        "payload": message
                                    }
                                }
                                await safe_send(notification)
                        except Exception as e:
                            self.logger.warning(f"WS Proxy Listener error for {card_id}: {e}")
                        finally:
                            self._card_sessions.pop(card_id, None)
                            self.logger.info(f"WS Proxy session closed for {card_id}")
                    
                    asyncio.create_task(ws_listener())
                    await safe_send({"jsonrpc": "2.0", "id": request_id, "result": {"success": True}})
                except Exception as e:
                    self.logger.error(f"WS Proxy Connect error: {e}")
                    await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 500, "message": str(e)}})
                return

            if action == "send":
                data = params.get("data")
                ws = self._card_sessions.get(card_id)
                if ws:
                    try:
                        await ws.send(json.dumps(data) if isinstance(data, dict) else data)
                        await safe_send({"jsonrpc": "2.0", "id": request_id, "result": {"success": True}})
                    except Exception as e:
                        await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 500, "message": str(e)}})
                else:
                    await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 404, "message": "Session not connected"}})
                return

            if action == "disconnect":
                ws = self._card_sessions.pop(card_id, None)
                if ws:
                    await ws.close()
                await safe_send({"jsonrpc": "2.0", "id": request_id, "result": {"success": True}})
                return

        # 5. Handle system-level RPCs
        if method == "system/config/get":
            config_str = self.db.get_setting("system_config", "{}")
            try:
                config = json.loads(config_str)
            except:
                config = {}
            await safe_send({"jsonrpc": "2.0", "id": request_id, "result": config})
            return

        if method == "projects/list":
            projects = self.db.get_projects()
            await safe_send({"jsonrpc": "2.0", "id": request_id, "result": projects})
            return

        if method == "provider/list":
            # Proxy to local API or read config directly
            try:
                from api.providers import get_providers
                res = await get_providers()
                await safe_send({"jsonrpc": "2.0", "id": request_id, "result": res})
            except Exception as e:
                self.logger.error(f"Error in provider/list: {e}")
                await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 500, "message": str(e)}})
            return

        if method == "kanban/progress/get":
            pid = params.get("project_id")
            if not pid:
                # Use current project if not specified
                pid = self.db.get_setting("current_project_id")
            
            if pid:
                progress = self.db.get_project_progress(pid)
                await safe_send({"jsonrpc": "2.0", "id": request_id, "result": progress})
            else:
                await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 404, "message": "No active project"}})
            return

        if method == "projects/status":
            # This handles getAllProjectStatuses for iPhone UI
            try:
                projects = self.db.get_projects()
                status = []
                for p in projects:
                    status.append({
                        "id": p["id"],
                        "name": p["name"],
                        "status": "ready" # Simple status for now
                    })
                await safe_send({"jsonrpc": "2.0", "id": request_id, "result": status})
            except Exception as e:
                self.logger.error(f"Error getting project status: {e}")
                await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 500, "message": str(e)}})
            return

        if method == "projects/switch":
            pid = params.get("project_id")
            # Logic from api/projects.py: just mark as current
            self.db.set_setting("current_project_id", pid)
            # Phase: Global Optimization - Pre-warm providers
            asyncio.create_task(self.dispatcher.pre_warm_providers(pid))
            await safe_send({"jsonrpc": "2.0", "id": request_id, "result": {"success": True, "project_id": pid}})
            return

        if method == "cards/create":
            # Direct DB creation
            card = self.db.create_card(
                column_id=params.get("column_id"),
                title=params.get("title"),
                description=params.get("description", ""),
                position=params.get("position", 0)
            )
            await safe_send({"jsonrpc": "2.0", "id": request_id, "result": card})
            return

        if method == "cards/move":
            card_id = params.get("card_id")
            column_id = params.get("column_id")
            position = params.get("position")
            success = self.db.move_card(card_id, column_id, position)
            await safe_send({"jsonrpc": "2.0", "id": request_id, "result": {"success": success}})
            return

        if method == "projects/get":
            pid = params.get("project_id")
            project = self.db.get_project(pid)
            if project:
                # 1. Fetch Columns
                raw_cols = self.db.get_columns(pid)
                full_columns = []
                for c in raw_cols:
                    # Normalize ID
                    if 'column_id' in c and 'id' not in c:
                        c['id'] = c['column_id']
                    
                    # 2. Fetch Cards for each column (Flutter expects this in project/get)
                    cards = self.db.get_cards_by_column(c['id'])
                    # Normalize Card IDs too
                    for card in cards:
                        if 'card_id' in card and 'id' not in card:
                            card['id'] = card['card_id']
                        # Ensure column_id is present
                        if 'column_id' not in card:
                            card['column_id'] = c['id']
                    
                    c['cards'] = cards
                    full_columns.append(c)
                
                project["columns"] = full_columns
                await safe_send({"jsonrpc": "2.0", "id": request_id, "result": project})
            else:
                await safe_send({"jsonrpc": "2.0", "id": request_id, "error": {"code": 404, "message": "Project not found"}})
            return

        if method == "cards/list":
            cid = params.get("column_id")
            # Corrected method name: get_cards -> get_cards_by_column
            raw_cards = self.db.get_cards_by_column(cid)
            normalized_cards = []
            for c in raw_cards:
                if 'card_id' in c and 'id' not in c:
                    c['id'] = c['card_id']
                normalized_cards.append(c)
            await safe_send({"jsonrpc": "2.0", "id": request_id, "result": normalized_cards})
            return

        async def on_ui_request(method, params):
            rid = params.get("id") or str(uuid.uuid4())
            fut = asyncio.get_event_loop().create_future()
            self._pending_ui_requests[rid] = fut
            await safe_send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            try:
                # Support long-cycle async: 24h timeout
                return await asyncio.wait_for(fut, timeout=3600.0 * 24)
            except asyncio.TimeoutError:
                self._pending_ui_requests.pop(rid, None)
                return {"error": {"code": -32000, "message": "UI Request Timeout"}}

        # 6. Dispatch to Core Logic (with error boundary)
        try:
            result = await self.dispatcher.dispatch(data, on_ui_request)
            
            # If dispatcher returned an error, send it back to the client
            if result and "error" in result:
                request_id = data.get("id")
                if request_id is not None:
                    error_response = {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": result["error"]
                    }
                    await safe_send(error_response)
                    self.logger.warning(f"Sent error to client: {result['error']}")
            
            return result
        except Exception as e:
            self.logger.error(f"Fatal error in dispatcher for {method}: {e}", exc_info=True)
            if request_id is not None:
                await safe_send({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32603, "message": f"Bridge internal error: {str(e)}"}
                })
            return {"error": {"code": -32603, "message": str(e)}}

    async def shutdown(self):
        await self.dispatcher.shutdown()

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--relay-url")
    parser.add_argument("--token")
    parser.add_argument("--workspace-cwd")
    args, unknown = parser.parse_known_args()

    bridge = UnifiedBridge(args.user_id, args.relay_url, token=args.token, workspace_cwd=args.workspace_cwd)
    try:
        await bridge.start()
    except KeyboardInterrupt:
        await bridge.shutdown()

if __name__ == "__main__":
    asyncio.run(main())
