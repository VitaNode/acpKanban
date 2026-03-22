import asyncio
import websockets
import os
import json
import logging
import sys
import argparse
from acp_client import ACPClient

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger("BridgeRelay")

class UnifiedBridge:
    def __init__(self, user_id, relay_url, acp_command):
        self.user_id = user_id
        self.relay_url = f"{relay_url.rstrip('/')}/relay/mac/{user_id}"
        self.acp = ACPClient(command=acp_command, name="LocalGemini")
        self.clients = set() # Store all active WebSocket connections (local + relay)
        self.running = True

    async def start(self):
        logger.info(f"Starting Unified Bridge for User: {self.user_id}")
        
        # 1. Register handler for raw ACP messages before starting
        self.acp.add_handler(self.broadcast_raw_message)

        # 2. Start Local ACP Process
        await self.acp.start()
        
        # 3. Start Local WebSocket Server (for Path 1 / Intranet)
        local_port = 8766
        local_server = websockets.serve(self.handle_client, "0.0.0.0", local_port)
        logger.info(f"Local Server listening on ws://0.0.0.0:{local_port}")

        # 4. Tasks for Relay maintenance
        await asyncio.gather(
            local_server,
            self.maintain_relay_connection()
        )

    async def broadcast_raw_message(self, data):
        """Callback for ACPClient to broadcast any received message to all clients."""
        if not self.clients:
            return
            
        message = json.dumps(data)
        logger.debug(f"Broadcasting to {len(self.clients)} clients: {message[:100]}...")
        
        disconnected = set()
        for client in list(self.clients):
            try:
                await client.send(message)
            except Exception:
                disconnected.add(client)
        
        for d in disconnected:
            self.clients.discard(d)

    async def handle_client(self, websocket, path=None):
        """Handle incoming local connections."""
        addr = websocket.remote_address
        logger.info(f"New local client connected: {addr}")
        self.clients.add(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, source=f"local:{addr}")
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Local client {addr} disconnected.")
        finally:
            self.clients.discard(websocket)

    async def maintain_relay_connection(self):
        """Maintain persistent connection to the cloud relay."""
        while self.running:
            try:
                logger.info(f"Connecting to Cloud Relay: {self.relay_url}")
                async with websockets.connect(self.relay_url, ping_interval=30, ping_timeout=10) as ws:
                    logger.info("Successfully connected to Cloud Relay.")
                    self.clients.add(ws)
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, source="cloud_relay")
                    finally:
                        self.clients.discard(ws)
            except Exception as e:
                logger.error(f"Relay connection error: {e}. Retrying in 5s...")
                await asyncio.sleep(5)

    async def forward_to_acp(self, message, source):
        """Forward JSON-RPC message from any client to local ACP stdin."""
        if not self.acp.process or self.acp.process.returncode is not None:
            logger.error("ACP Process is not running. Cannot forward message.")
            return

        try:
            # Basic validation
            json.loads(message)
            logger.debug(f"Forwarding from {source}: {message[:100]}...")
            self.acp.process.stdin.write(message.encode() + b"\n")
            await self.acp.process.stdin.drain()
        except json.JSONDecodeError:
            logger.warning(f"Received non-JSON from {source}: {message}")
        except Exception as e:
            logger.error(f"Error forwarding message: {e}")

    async def stop(self):
        self.running = False
        await self.acp.stop()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MyBot Unified Bridge (Local + Relay)")
    parser.add_argument("--user-id", default=os.getenv("USER_ID", "default_user"), help="User ID for relay")
    parser.add_argument("--relay-url", default=os.getenv("RELAY_URL", "ws://localhost:8766"), help="Cloud relay URL")
    parser.add_argument("--command", default="gemini --acp", help="Command to start ACP process")
    
    args = parser.parse_args()
    cmd = args.command.split()
    
    bridge = UnifiedBridge(args.user_id, args.relay_url, cmd)
    try:
        asyncio.run(bridge.start())
    except KeyboardInterrupt:
        logger.info("Bridge shutting down.")
