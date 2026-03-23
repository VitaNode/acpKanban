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
        
        self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
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
        
        local_port = 8766
        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", local_port)
        logger.info(f"Local Server listening on ws://0.0.0.0:{local_port}")

        await asyncio.gather(local_server, self.maintain_relay_connection(), self.health_check_loop())

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
                async with websockets.connect(self.relay_url, extra_headers=headers) as ws:
                    self.relay_ws = ws
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, ws)
                    finally:
                        self.relay_ws = None
            except Exception as e:
                await asyncio.sleep(5)

    async def on_acp_message(self, data):
        encrypted_env = self.e2ee.wrap_json_rpc(data)
        plaintext_str = json.dumps(data)
        for client in list(self.local_clients):
            try: await client.send(plaintext_str)
            except Exception: self.local_clients.discard(client)
        if self.relay_ws and not self.relay_ws.closed:
            try: await self.relay_ws.send(encrypted_env)
            except Exception: pass

    async def handle_pairing(self, data):
        peer_public = data.get("params", {}).get("publicKey")
        if not peer_public: return {"error": "Missing publicKey"}
        shared_secret = E2EEManager.derive_shared_secret(self.private_key, peer_public)
        self.e2ee = E2EEManager(session_key_hex=shared_secret)
        return {"result": {"publicKey": self.public_key_hex, "status": "paired"}}

    async def forward_to_acp(self, message, source_ws):
        try:
            data = json.loads(message)
            if data.get("method") == "pairing/exchange":
                response = await self.handle_pairing(data)
                response["id"] = data.get("id")
                response["jsonrpc"] = "2.0"
                await source_ws.send(json.dumps(response))
                return

            if data.get("method") == "e2ee/envelope":
                try:
                    data = self.e2ee.unwrap_json_rpc(message)
                except Exception as e:
                    return

            self.acp.process.stdin.write((json.dumps(data) + "\n").encode())
            await self.acp.process.stdin.drain()
        except Exception as e:
            pass

    async def health_check_loop(self):
        while self.running:
            await asyncio.sleep(10)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", default="test_user")
    parser.add_argument("--relay-url", default="ws://localhost:8766")
    parser.add_argument("--command", default="gemini --acp")
    args = parser.parse_args()
    bridge = UnifiedBridge(args.user_id, args.relay_url, args.command.split())
    asyncio.run(bridge.start())
