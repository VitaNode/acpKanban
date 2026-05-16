import asyncio
import websockets
import os
import json
import logging
import sys
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

from src.logger import setup_logger

logger = setup_logger("RelayServer")

# Configuration - Must be provided via .env or shell environment
RELAY_TOKEN = os.getenv("RELAY_TOKEN")

if not RELAY_TOKEN:
    logger.warning("RELAY_TOKEN not set in environment! Relay will be unauthorized.")

# Map to store active relay pairs: { user_id: {"mac": websocket, "app": websocket} }
relays = {}

async def process_request(websocket, request):
    """Intercept unauthorized requests during handshake (websockets 14.0+ API)."""
    path = request.path
    headers = request.headers
    
    # 1. Try Authorization Header
    auth_header = headers.get("Authorization")
    
    # 2. Try Query Parameter (for Web/Browser compatibility)
    query_token = None
    if "?" in path:
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(path)
        params = parse_qs(parsed.query)
        query_token = params.get("token", [None])[0]

    expected = f"Bearer {RELAY_TOKEN}"
    if auth_header != expected and query_token != RELAY_TOKEN:
        logger.warning(f"Handshake Auth failed for path: {path}")
        return (401, [], b"Unauthorized\n")
    
    logger.debug(f"Handshake path authenticated: {path}")
    return None

def is_alive(ws):
    """Check if a websocket connection is still alive (compat for v16+)."""
    if ws is None: return False
    # In v16 asyncio API, check the state
    return ws.state == websockets.protocol.State.OPEN

async def handle_relay_logic(websocket, role, user_id):
    if user_id not in relays:
        relays[user_id] = {"mac": None, "app": None}
    
    old_ws = relays[user_id].get(role)
    if is_alive(old_ws):
        await old_ws.close(1001, "Replaced")

    relays[user_id][role] = websocket
    logger.info(f"User {user_id}: {role} connected.")

    try:
        async for message in websocket:
            other_role = "app" if role == "mac" else "mac"
            other_ws = relays[user_id].get(other_role)
            
            if is_alive(other_ws):
                try:
                    await asyncio.wait_for(other_ws.send(message), timeout=5.0)
                except Exception as e:
                    logger.error(f"Forward error from {role} to {other_role}: {e}")
            else:
                logger.debug(f"User {user_id}: {role} message dropped ({other_role} offline)")
                
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if relays.get(user_id) and relays[user_id].get(role) == websocket:
            relays[user_id][role] = None

async def handler(websocket):
    """Main handler (websockets 14.0+ API)."""
    path = websocket.request.path
    client_addr = websocket.remote_address
    
    if path.startswith("/direct") or path == "/":
        logger.info(f"Routing {client_addr} to Direct Mode")
        import acp_bridge_ws
        await acp_bridge_ws.handler(websocket)
        return

    # Strip query params for routing
    base_path = path.split("?")[0]
    parts = base_path.strip("/").split("/")
    
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
        process_request=process_request,
        ping_interval=30,
        ping_timeout=10
    ):
        logger.info(f"Relay Server (v16 asyncio) started on ws://{host}:{port}")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
