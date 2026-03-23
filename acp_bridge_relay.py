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

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger("BridgeRelay")

class UnifiedBridge:
    def __init__(self, user_id, relay_url, acp_command, token=None, session_key=None):
        self.user_id = user_id
        self.relay_url = f"{relay_url.rstrip('/')}/relay/mac/{user_id}"
        self.token = token or os.getenv("RELAY_TOKEN", "default_secret")
        
        self.acp = ACPClient(command=acp_command, name="LocalGemini")
        self.local_discovery = LocalDiscovery(user_id)
        
        # ECDH pair for initial handshake
        self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
        
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
            local_server,
            self.maintain_relay_connection(),
            self.health_check_loop()
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
                    self.relay_url, ping_interval=30, ping_timeout=10, extra_headers=headers
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
        """Broadcast output from ACP process."""
        plaintext_str = json.dumps(data)
        
        # 1. Local clients receive plaintext (Performance/Simplicity)
        for client in list(self.local_clients):
            try: await client.send(plaintext_str)
            except Exception: self.local_clients.discard(client)

        # 2. Cloud Relay ONLY receives E2EE messages
        if self.relay_ws and not self.relay_ws.closed:
            if self.e2ee.is_ready:
                try:
                    encrypted_env = self.e2ee.wrap_json_rpc(data)
                    await self.relay_ws.send(encrypted_env)
                except Exception as e:
                    logger.error(f"E2EE Wrap error: {e}")
            else:
                # Security boundary: Drop messages if session key not yet negotiated
                logger.warning("Relay connected but E2EE not paired. Dropping ACP output for privacy.")

    async def handle_pairing(self, data):
        peer_public = data.get("params", {}).get("publicKey")
        if not peer_public: return {"error": "Missing publicKey"}
        
        try:
            shared_secret = E2EEManager.derive_shared_secret(self.private_key, peer_public)
            self.e2ee.setup_session(shared_secret) # Securely transition to paired state
            logger.info("ECDH Pairing Successful. Session key derived.")
            return {"result": {"publicKey": self.public_key_hex, "status": "paired"}}
        except Exception as e:
            logger.error(f"Pairing failed: {e}")
            return {"error": "Pairing calculation error"}

    async def forward_to_acp(self, message, source_ws):
        try:
            data = json.loads(message)
            
            # Handle Pairing (Plaintext)
            if data.get("method") == "pairing/exchange":
                response = await self.handle_pairing(data)
                response["id"] = data.get("id")
                response["jsonrpc"] = "2.0"
                await source_ws.send(json.dumps(response))
                return

            # Handle E2EE Envelope
            if data.get("method") == "e2ee/envelope":
                if not self.e2ee.is_ready:
                    logger.warning("Received E2EE envelope but session not ready.")
                    return
                try:
                    data = self.e2ee.unwrap_json_rpc(message)
                except Exception as e:
                    logger.error(f"Failed to decrypt message: {e}")
                    return

            # Final forward to ACP engine
            if self.acp.process and self.acp.process.returncode is None:
                self.acp.process.stdin.write((json.dumps(data) + "\n").encode())
                await self.acp.process.stdin.drain()
        except Exception as e:
            logger.error(f"Forwarding error: {e}")

    async def health_check_loop(self):
        while self.running:
            if self.acp.process and self.acp.process.returncode is not None:
                logger.critical("ACP Process died!")
            await asyncio.sleep(10)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", default="test_user")
    parser.add_argument("--relay-url", default="ws://localhost:8766")
    parser.add_argument("--command", default="gemini --acp")
    args = parser.parse_args()
    
    bridge = UnifiedBridge(args.user_id, args.relay_url, args.command.split())
    try: asyncio.run(bridge.start())
    except KeyboardInterrupt: pass
