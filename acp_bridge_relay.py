import asyncio
import websockets
import os
import json
import logging
import sys
import argparse
from acp_client import ACPClient
from mdns_discovery import LocalDiscovery
from e2ee import E2EEManager
from acp_adapter import ACPProtocolAdapter

# Set up logging
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("BridgeRelay")


class UnifiedBridge:
    def __init__(
        self,
        user_id,
        relay_url,
        acp_command,
        token=None,
        session_key=None,
        workspace_cwd=None,
    ):
        self.user_id = user_id
        self.relay_url = f"{relay_url.rstrip('/')}/relay/mac/{user_id}"
        self.token = token or os.getenv("RELAY_TOKEN", "default_secret")

        self.acp = ACPClient(command=acp_command, name="LocalGemini")
        self.local_discovery = LocalDiscovery(user_id)

        # Protocol adapter for Flutter App compatibility
        self.adapter = ACPProtocolAdapter(self.acp, workspace_cwd=workspace_cwd)

        # ECDH pair for initial handshake (load from storage or generate new)
        saved_keys = E2EEManager.load_key_pair(user_id)
        if saved_keys:
            self.private_key, self.public_key_hex = saved_keys
            logger.info(f"Loaded existing ECDH key pair for user: {user_id}")
        else:
            self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
            E2EEManager.save_key_pair(user_id, self.private_key, self.public_key_hex)
            logger.info(f"Generated new ECDH key pair for user: {user_id}")

        # Session key manager (Starts NOT ready)
        self.e2ee = E2EEManager(session_key_hex=session_key)

        self.local_clients = set()
        self.relay_ws = None
        self.running = True

    async def start(self):
        logger.info(f"Starting Unified Bridge for User: {self.user_id}")
        logger.info(f"Pairing Public Key: {self.public_key_hex}")

        self.local_discovery.start_broadcast()
        self.acp.add_handler(self.on_acp_message)
        await self.acp.start()

        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", 8766)
        logger.info("Local Server listening on ws://0.0.0.0:8766")

        await asyncio.gather(
            local_server, self.maintain_relay_connection(), self.health_check_loop()
        )

    async def handle_local_client(self, websocket, path=None):
        addr = websocket.remote_address
        logger.info(f"New local client connected: {addr}")
        self.local_clients.add(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, websocket)
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Local client {addr} disconnected.")
        finally:
            self.local_clients.discard(websocket)

    async def maintain_relay_connection(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        while self.running:
            try:
                async with websockets.connect(
                    self.relay_url,
                    ping_interval=30,
                    ping_timeout=10,
                    extra_headers=headers,
                ) as ws:
                    logger.info("Connected to Cloud Relay.")
                    self.relay_ws = ws
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, ws)
                    finally:
                        self.relay_ws = None
            except Exception as e:
                await asyncio.sleep(5)

    async def on_acp_message(self, data):
        """
        Broadcast output from ACP process.

        Only forwards important notifications, filters out verbose thought chunks.
        """
        # Filter: Only forward notifications, not responses
        # Responses have 'id' but no 'method'
        # Notifications have 'method'
        if "method" not in data:
            return  # This is a response, not a notification

        # Filter verbose notifications
        if data.get("method") == "session/update":
            update_type = data.get("params", {}).get("update", {}).get("sessionUpdate")
            # Skip thought chunks - they're too verbose for mobile
            if update_type in ["agent_thought_chunk"]:
                return  # Skip

        plaintext_str = json.dumps(data)

        # 1. Local clients receive plaintext (Performance/Simplicity)
        for client in list(self.local_clients):
            try:
                await client.send(plaintext_str)
            except Exception:
                self.local_clients.discard(client)

        # 2. Cloud Relay receives E2EE encrypted messages
        if self.relay_ws and not self.relay_ws.closed:
            if self.e2ee.is_ready:
                try:
                    # wrap_json_rpc now returns dict, so json.dumps here
                    encrypted_env = json.dumps(self.e2ee.wrap_json_rpc(data))
                    await self.relay_ws.send(encrypted_env)
                    logger.debug(
                        f"-> Sent E2EE notification to relay: {data.get('method')}"
                    )
                except Exception as e:
                    logger.error(f"E2EE Wrap error for notification: {e}")
            else:
                # Security boundary: Drop messages if session key not yet negotiated
                logger.debug(
                    "Relay connected but E2EE not paired. Dropping ACP notification."
                )

    async def handle_pairing(self, data):
        peer_public = data.get("params", {}).get("publicKey")
        if not peer_public:
            return {"error": "Missing publicKey"}

        try:
            shared_secret = E2EEManager.derive_shared_secret(
                self.private_key, peer_public
            )
            self.e2ee.setup_session(
                shared_secret
            )  # Securely transition to paired state
            logger.info("ECDH Pairing Successful. Session key derived.")
            return {"result": {"publicKey": self.public_key_hex, "status": "paired"}}
        except Exception as e:
            logger.error(f"Pairing failed: {e}")
            return {"error": "Pairing calculation error"}

    async def forward_to_acp(self, message, source_ws):
        """
        Forward message to ACP CLI or handle via adapter.

        Smart encryption: if request was E2EE encrypted, response is also encrypted.
        """
        addr = (
            source_ws.remote_address
            if hasattr(source_ws, "remote_address")
            else "relay"
        )
        try:
            data = json.loads(message)
            original_was_e2ee = data.get("method") == "e2ee/envelope"

            # Handle Pairing (Plaintext)
            if data.get("method") == "pairing/exchange":
                response = await self.handle_pairing(data)
                response["id"] = data.get("id")
                response["jsonrpc"] = "2.0"
                await source_ws.send(json.dumps(response))
                return

            # Handle E2EE Envelope - decrypt and continue processing
            if original_was_e2ee:
                if not self.e2ee.is_ready:
                    logger.warning(
                        f"Received E2EE envelope from {addr} but session not ready. Dropping."
                    )
                    return
                try:
                    data = self.e2ee.unwrap_json_rpc(message)
                    logger.debug(f"Decrypted E2EE from {addr}: {data.get('method')}")
                    # CRITICAL: Overwrite 'message' with decrypted string so rest of logic works
                    message = json.dumps(data)
                except Exception as e:
                    logger.error(f"Failed to decrypt E2EE message from {addr}: {e}")
                    return

            # Extract fields from (potentially decrypted) data
            method = data.get("method")
            params = data.get("params", {})
            request_id = data.get("id")

            # 3. Route to Protocol Adapter
            # The adapter handles conversion for simple clients (Flutter)
            # AND it maintains the request-response cycle via acp.request()
            try:
                # Handle everything that has an 'id' as a request through the adapter
                if request_id is not None:
                    response_result = await self.adapter.handle_request(method, params)

                    # Build response envelope
                    response = {"jsonrpc": "2.0", "id": request_id}

                    # If adapter returned an error dict, use it
                    if isinstance(response_result, dict) and "error" in response_result:
                        response["error"] = response_result["error"]
                    else:
                        response["result"] = response_result

                    # Smart encryption: if request was E2EE, encrypt response
                    if original_was_e2ee and self.e2ee.is_ready:
                        response = self.e2ee.wrap_json_rpc(response)
                        await source_ws.send(json.dumps(response))
                    else:
                        await source_ws.send(json.dumps(response))

                    logger.info(f"-> Handled {method}: {request_id}")
                    return

            except Exception as e:
                logger.error(f"Adapter error for {method}: {e}")
                if request_id is not None:
                    error_response = {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32603, "message": str(e)},
                    }
                    if original_was_e2ee and self.e2ee.is_ready:
                        error_response = self.e2ee.wrap_json_rpc(error_response)
                        await source_ws.send(json.dumps(error_response))
                    else:
                        await source_ws.send(json.dumps(error_response))
                return

            # Handle notifications (no ID) - forward raw to stdin
            if self.acp.process and self.acp.process.returncode is None:
                payload = (json.dumps(data) + "\n").encode()
                self.acp.process.stdin.write(payload)
                await self.acp.process.stdin.drain()
                logger.info(f"-> Forwarded notification to ACP: {method}")
            else:
                logger.error(f"ACP Process not running. Cannot forward.")
        except json.JSONDecodeError:
            logger.warning(f"Received non-JSON message from {addr}: {message[:50]}...")
        except Exception as e:
            logger.error(f"Unexpected error in forward_to_acp from {addr}: {e}")

    async def health_check_loop(self):
        while self.running:
            if self.acp.process and self.acp.process.returncode is not None:
                logger.critical("ACP Process died!")
            await asyncio.sleep(10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", default="test_user")
    parser.add_argument("--relay-url", default="wss://mybot.siliconpulse.cc")
    parser.add_argument("--command", default="gemini --acp")
    parser.add_argument("--token", help="Relay Auth Token")
    parser.add_argument(
        "--e2ee-key", help="32-byte Hex Key for E2EE Session (Optional, for pre-paired)"
    )
    parser.add_argument("--workspace-cwd", help="Default workspace path")
    args = parser.parse_args()

    # Initialize with token and session_key if provided
    bridge = UnifiedBridge(
        args.user_id,
        args.relay_url,
        args.command.split(),
        token=args.token,
        session_key=args.e2ee_key,
        workspace_cwd=args.workspace_cwd,
    )
    try:
        asyncio.run(bridge.start())
    except KeyboardInterrupt:
        pass
