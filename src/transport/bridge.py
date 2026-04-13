import asyncio
import json
import logging
import uuid
import argparse
import sys
import os
import base64
import websockets
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
        self.dispatcher = MessageDispatcher(self.db)
        self._pending_ui_requests: Dict[str, asyncio.Future] = {}
        self._local_clients: Set[websockets.WebSocketServerProtocol] = set()
        self._client_e2ee_secrets: Dict[websockets.WebSocketServerProtocol, bytes] = {}
        
        # Generate Bridge X25519 Key Pair for E2EE
        self._bridge_private_key = X25519PrivateKey.generate()
        self._bridge_public_key_hex = self._bridge_private_key.public_key().public_bytes(
            encoding=Encoding.Raw,
            format=PublicFormat.Raw
        ).hex()

    async def start(self):
        """Starts both local and relay servers."""
        self.logger.info(f"Bridge starting for user {self.user_id}...")

        # 1. Start Relay Connection (if URL provided)
        if self.relay_url:
            asyncio.create_task(self._run_relay_loop())

        # 2. Start Local WebSocket Server (port 8766) for direct tool access
        server = await websockets.serve(
            self._handle_local_client,
            "0.0.0.0",
            8766,
            ping_interval=20,
            ping_timeout=20,
        )
        self.logger.info(f"Local tool bridge started on ws://0.0.0.0:8766 (PubKey: {self._bridge_public_key_hex[:16]}...)")
        
        # Keep the server running
        try:
            await asyncio.Future()  # Run forever
        except asyncio.CancelledError:
            server.close()
            await server.wait_closed()

    async def _handle_local_client(self, websocket):
        """Handle incoming WebSocket connections from Flutter or local tools."""
        self._local_clients.add(websocket)
        self.logger.info(f"Client connected: {websocket.remote_address}")
        try:
            async for message in websocket:
                try:
                    data = json.loads(message)
                    self.logger.info(f"Received: {data.get('method', 'N/A')} (id: {data.get('id')})")

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
                            self.logger.info(f"Decrypted: {inner_data.get('method', 'N/A')} (id: {inner_data.get('id')})")
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

        while True:
            try:
                # websockets >= 13.0 uses additional_headers instead of extra_headers
                connect_kwargs = {"additional_headers": headers}
                # Fallback for older versions
                try:
                    async with websockets.connect(self.relay_url, **connect_kwargs) as ws:
                        await self._handle_relay_connection(ws)
                except TypeError:
                    # Old version fallback
                    connect_kwargs = {"extra_headers": headers}
                    async with websockets.connect(self.relay_url, **connect_kwargs) as ws:
                        await self._handle_relay_connection(ws)
            except Exception as e:
                self.logger.error(f"Relay error: {e}. Retrying in 5s...")
                await asyncio.sleep(5)

    async def _handle_relay_connection(self, ws):
        """Handle an established relay connection."""
        self.logger.info("Connected to Relay Server")
        async for message in ws:
            data = json.loads(message)
            asyncio.create_task(self.handle_rpc(data, lambda n: ws.send(json.dumps(n))))

    async def on_ui_response(self, request_id: str, result: Any):
        """Phase 3.2: Standardized UI Response Resolver."""
        future = self._pending_ui_requests.pop(request_id, None)
        if future and not future.done():
            future.set_result(result)

    async def handle_rpc(self, data: Dict[str, Any], send_output: Callable):
        # Wrap the output to await it correctly
        async def safe_send(msg):
            try: await send_output(msg)
            except Exception as e:
                self.logger.error(f"Failed to send output: {e}")

        async def on_ui_request(method, params):
            rid = str(uuid.uuid4())
            fut = asyncio.get_event_loop().create_future()
            self._pending_ui_requests[rid] = fut
            await safe_send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            try:
                return await asyncio.wait_for(fut, timeout=60.0)
            except asyncio.TimeoutError:
                self._pending_ui_requests.pop(rid, None)
                return {"error": {"code": -32000, "message": "UI Request Timeout"}}

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
