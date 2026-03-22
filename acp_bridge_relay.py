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
    def __init__(self, user_id, relay_url, acp_command, token=None, e2ee_key=None):
        self.user_id = user_id
        self.relay_url = f"{relay_url.rstrip('/')}/relay/mac/{user_id}"
        self.token = token or os.getenv("RELAY_TOKEN", "default_secret")
        
        self.acp = ACPClient(command=acp_command, name="LocalGemini")
        self.local_discovery = LocalDiscovery(user_id)
        self.e2ee = E2EEManager(key_hex=e2ee_key)
        
        self.local_clients = set()  # Only local intranet clients
        self.relay_ws = None        # Cloud relay websocket
        self.running = True

    async def start(self):
        logger.info(f"Starting Unified Bridge for User: {self.user_id}")
        
        # 1. Start mDNS Broadcast
        self.local_discovery.start_broadcast()

        # 2. Register handler for raw ACP messages
        self.acp.add_handler(self.on_acp_message)

        # 3. Start Local ACP Process
        await self.acp.start()
        
        # 4. Start Local WebSocket Server
        local_port = 8766
        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", local_port)
        logger.info(f"Local Server listening on ws://0.0.0.0:{local_port}")

        # 5. Parallel tasks
        await asyncio.gather(
            local_server,
            self.maintain_relay_connection(),
            self.health_check_loop()
        )

    async def handle_local_client(self, websocket, path=None):
        """Handle incoming local connections (usually plaintext or E2EE)."""
        addr = websocket.remote_address
        logger.info(f"New local client connected: {addr}")
        self.local_clients.add(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, source=f"local:{addr}")
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Local client {addr} disconnected.")
        finally:
            self.local_clients.discard(websocket)

    async def maintain_relay_connection(self):
        """Maintain persistent connection to the cloud relay (Authenticated)."""
        headers = {"Authorization": f"Bearer {self.token}"}
        
        while self.running:
            try:
                logger.info(f"Connecting to Cloud Relay: {self.relay_url}")
                async with websockets.connect(
                    self.relay_url, 
                    ping_interval=30, 
                    ping_timeout=10,
                    extra_headers=headers
                ) as ws:
                    logger.info("Successfully connected to Cloud Relay.")
                    self.relay_ws = ws
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, source="cloud_relay")
                    finally:
                        self.relay_ws = None
            except Exception as e:
                logger.error(f"Relay connection error: {e}. Retrying in 5s...")
                await asyncio.sleep(5)

    async def on_acp_message(self, data):
        """Callback for ACPClient to broadcast any received message to all clients."""
        # 1. Prepare encrypted envelope for cloud relay
        # (Cloud MUST be E2EE for privacy)
        encrypted_msg = self.e2ee.wrap_json_rpc(data)
        
        # 2. For local clients, we could send plaintext for performance, 
        # but E2EE is safer. Let's send BOTH or just E2EE. 
        # Here we choose to send E2EE to everyone for consistency.
        plaintext_msg = json.dumps(data)

        # 1. Send to all local clients (Prefer plaintext for local if app expects it, 
        # but let's try to support both)
        if self.local_clients:
            disconnected_local = set()
            for client in list(self.local_clients):
                try:
                    # For now, let's send plaintext to local for easier debugging 
                    # unless E2EE is strictly required.
                    await client.send(plaintext_msg)
                except Exception:
                    disconnected_local.add(client)
            for d in disconnected_local:
                self.local_clients.discard(d)

        # 2. Send to cloud relay (Always E2EE)
        if self.relay_ws and not self.relay_ws.closed:
            try:
                await self.relay_ws.send(encrypted_msg)
            except Exception as e:
                logger.error(f"Failed to send to relay: {e}")

    async def forward_to_acp(self, message, source):
        """Unwrap E2EE if necessary and forward to local ACP stdin."""
        if not self.acp.process or self.acp.process.returncode is not None:
            return

        try:
            # 1. Try to unwrap if it's an E2EE envelope
            data = json.loads(message)
            if data.get("method") == "e2ee/envelope":
                data = self.e2ee.unwrap_json_rpc(message)
                logger.debug(f"Unwrapped E2EE from {source}")

            # 2. Forward final JSON to ACP
            self.acp.process.stdin.write((json.dumps(data) + "\n").encode())
            await self.acp.process.stdin.drain()
        except Exception as e:
            logger.error(f"Error forwarding from {source}: {e}")

    async def health_check_loop(self):
        """Monitor ACP process health."""
        while self.running:
            if self.acp.process and self.acp.process.returncode is not None:
                logger.critical(f"ACP process crashed! Restarting...")
                # Automatic restart logic could be added here
            await asyncio.sleep(10)

    async def stop(self):
        self.running = False
        self.local_discovery.stop_broadcast()
        await self.acp.stop()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MyBot Unified Bridge (E2EE Enabled)")
    parser.add_argument("--user-id", default=os.getenv("USER_ID", "default_user"))
    parser.add_argument("--relay-url", default=os.getenv("RELAY_URL", "ws://localhost:8766"))
    parser.add_argument("--command", default="gemini --acp")
    parser.add_argument("--token", help="Relay Auth Token")
    parser.add_argument("--e2ee-key", help="32-byte Hex Key for E2EE")
    
    args = parser.parse_args()
    cmd = args.command.split()
    
    bridge = UnifiedBridge(args.user_id, args.relay_url, cmd, token=args.token, e2ee_key=args.e2ee_key)
    try:
        asyncio.run(bridge.start())
    except KeyboardInterrupt:
        logger.info("Bridge shutting down.")
