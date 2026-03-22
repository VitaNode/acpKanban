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

# Map to store active relay pairs: { user_id: {"mac": websocket, "app": websocket} }
relays = {}

async def handle_relay_logic(websocket, role, user_id):
    """Handle the core message forwarding for Path 2."""
    if user_id not in relays:
        relays[user_id] = {"mac": None, "app": None}
    
    # Check if a connection already exists for this role
    old_ws = relays[user_id].get(role)
    if old_ws and not old_ws.closed:
        logger.warning(f"Closing existing connection for User {user_id} Role {role}")
        await old_ws.close(1001, "Newer connection established")

    relays[user_id][role] = websocket
    logger.info(f"User {user_id}: {role} connected. Total relays active: {len(relays)}")

    try:
        async for message in websocket:
            # Route message to the other side
            other_role = "app" if role == "mac" else "mac"
            other_ws = relays[user_id].get(other_role)
            
            if other_ws and not other_ws.closed:
                try:
                    await other_ws.send(message)
                except Exception as e:
                    logger.error(f"Failed to forward message from {role} to {other_role} for User {user_id}: {e}")
            else:
                # Optionally log if the other side is missing
                logger.debug(f"User {user_id}: message from {role} dropped, {other_role} not connected.")
                
    except websockets.exceptions.ConnectionClosed:
        logger.info(f"User {user_id}: {role} connection closed.")
    except Exception as e:
        logger.error(f"Error in relay logic for User {user_id} {role}: {e}")
    finally:
        # Only clear if it's the current websocket
        if relays.get(user_id) and relays[user_id].get(role) == websocket:
            relays[user_id][role] = None
        
        # Clean up empty user entries
        if relays.get(user_id) and not relays[user_id]["mac"] and not relays[user_id]["app"]:
            del relays[user_id]

async def handler(websocket, path):
    """Unified entry point for Path 2 and Path 3."""
    client_addr = websocket.remote_address
    logger.info(f"New connection from {client_addr} on path: {path}")

    # Path 3: Direct Mode (Cloud ACP Server)
    if path == "/direct" or path == "/":
        logger.info(f"Routing {client_addr} to Direct Mode (Path 3)")
        from acp_bridge_ws import handler as direct_handler
        await direct_handler(websocket)
        return

    # Path 2: Relay Mode
    # Expected format: /relay/mac/user123 or /relay/app/user123
    parts = path.strip("/").split("/")
    if len(parts) == 3 and parts[0] == "relay":
        role = parts[1]
        user_id = parts[2]
        
        if role not in ["mac", "app"]:
            logger.warning(f"Invalid role: {role} from {client_addr}")
            await websocket.close(1003, "Invalid Role (must be 'mac' or 'app')")
            return
            
        await handle_relay_logic(websocket, role, user_id)
    else:
        logger.warning(f"Invalid path: {path} from {client_addr}")
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
        logger.info(f"Unified Relay Server started on ws://{host}:{port}")
        logger.info(f" - Path 3 (Direct): ws://{host}:{port}/direct")
        logger.info(f" - Path 2 (App):    ws://{host}:{port}/relay/app/{{user_id}}")
        logger.info(f" - Path 2 (Mac):    ws://{host}:{port}/relay/mac/{{user_id}}")
        await asyncio.Future()  # run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Server shutting down.")
