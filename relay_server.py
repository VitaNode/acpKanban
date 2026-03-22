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

async def handle_relay_logic(websocket, role, user_id):
    """Handle core forwarding for Path 2."""
    if user_id not in relays:
        relays[user_id] = {"mac": None, "app": None}
    
    # Pre-empt existing connections of the same role
    old_ws = relays[user_id].get(role)
    if old_ws and not old_ws.closed:
        logger.warning(f"Closing existing connection for {user_id}/{role}")
        await old_ws.close(1001, "Replaced by newer connection")

    relays[user_id][role] = websocket
    logger.info(f"User {user_id}: {role} connected.")

    try:
        async for message in websocket:
            other_role = "app" if role == "mac" else "mac"
            other_ws = relays[user_id].get(other_role)
            
            if other_ws and not other_ws.closed:
                try:
                    await other_ws.send(message)
                except Exception as e:
                    logger.error(f"Forward error from {role} to {other_role}: {e}")
            else:
                logger.debug(f"User {user_id}: {role} message dropped ({other_role} offline)")
                
    except websockets.exceptions.ConnectionClosed:
        logger.info(f"User {user_id}: {role} disconnected.")
    finally:
        if relays.get(user_id) and relays[user_id].get(role) == websocket:
            relays[user_id][role] = None
        if relays.get(user_id) and not relays[user_id]["mac"] and not relays[user_id]["app"]:
            del relays[user_id]

async def handler(websocket, path):
    """Unified entry point with Authentication."""
    client_addr = websocket.remote_address
    
    # 1. Basic Token Authentication
    # Note: websockets doesn't expose headers directly in the handler's args, 
    # but we can access them via websocket.request_headers
    auth_header = websocket.request_headers.get("Authorization")
    expected = f"Bearer {RELAY_TOKEN}"
    
    if auth_header != expected:
        logger.warning(f"Auth failed for {client_addr} on {path}")
        await websocket.close(1008, "Invalid Token")
        return

    # 2. Path routing
    if path == "/direct" or path == "/":
        logger.info(f"Routing {client_addr} to Direct Mode (Path 3)")
        from acp_bridge_ws import handler as direct_handler
        await direct_handler(websocket)
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
        ping_interval=30,
        ping_timeout=10
    ):
        logger.info(f"Relay Server (Authenticated) started on ws://{host}:{port}")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
