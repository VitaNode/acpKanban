import asyncio
import websockets
import os
import json
import logging
import sys
from datetime import datetime

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger("RelayServer")

# Configuration
RELAY_TOKEN = os.getenv("RELAY_TOKEN", "default_secret")

# Map to store active relay pairs: { user_id: {"mac": websocket, "app": websocket} }
relays = {}

async def process_request(path, request_headers):
    """Intercept unauthorized requests during handshake."""
    auth_header = request_headers.get("Authorization")
    expected = f"Bearer {RELAY_TOKEN}"
    if auth_header != expected:
        logger.warning(f"Handshake Auth failed for path: {path}")
        # Return a 401 Unauthorized response
        return (401, [], b"Unauthorized\n")
    return None

async def handle_relay_logic(websocket, role, user_id):
    if user_id not in relays:
        relays[user_id] = {"mac": None, "app": None}
    
    old_ws = relays[user_id].get(role)
    if old_ws and not old_ws.closed:
        await old_ws.close(1001, "Replaced")

    relays[user_id][role] = websocket
    logger.info(f"User {user_id}: {role} connected.")

    try:
        async for message in websocket:
            other_role = "app" if role == "mac" else "mac"
            other_ws = relays[user_id].get(other_role)
            if other_ws and not other_ws.closed:
                try:
                    await asyncio.wait_for(other_ws.send(message), timeout=5.0)
                except Exception as e:
                    logger.error(f"Forward error: {e}")
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if relays.get(user_id) and relays[user_id].get(role) == websocket:
            relays[user_id][role] = None

async def handler(websocket, path):
    """Main handler, authentication already checked by process_request."""
    client_addr = websocket.remote_address
    
    if path == "/direct" or path == "/":
        logger.info(f"Routing {client_addr} to Direct Mode")
        import acp_bridge_ws
        await acp_bridge_ws.handler(websocket)
        return

    parts = path.strip("/").split("/")
    if len(parts) == 3 and parts[0] == "relay":
        role, user_id = parts[1], parts[2]
        if role in ["mac", "app"]:
            await handle_relay_logic(websocket, role, user_id)
        else:
            await websocket.close(1003, "Invalid Role")
    else:
        await websocket.close(1003, "Invalid Path")

async def main():
    port = int(os.getenv("RELAY_PORT", 8766))
    host = os.getenv("RELAY_HOST", "0.0.0.0")
    
    async with websockets.serve(
        handler, 
        host, 
        port,
        process_request=process_request, # Add handshake auth
        ping_interval=30,
        ping_timeout=10
    ):
        logger.info(f"Relay Server (Secure Handshake) started on ws://{host}:{port}")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
