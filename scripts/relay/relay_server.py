import asyncio
import websockets
import os
import json
import logging
import sys
from datetime import datetime
from typing import Optional, Dict
from urllib.parse import urlparse, parse_qs

# Standalone Relay Server for Cloud Deployment
# No internal project dependencies (like src.logger)

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger("RelayServer")

class HandshakeNoiseFilter(logging.Filter):
    """Filter out noisy tracebacks from websockets handshake failures (probes/scanners)."""
    def filter(self, record):
        if record.levelno <= logging.ERROR and record.name == "websockets.server":
            msg = record.getMessage()
            # Suppress HEAD request errors (common from curl -I or health checks)
            if "unsupported HTTP method" in msg and "HEAD" in msg:
                return False
            # Suppress abrupt closures before handshake completes
            if "opening handshake failed" in msg and "ConnectionClosedError" in msg:
                return False
            # Suppress generic invalid message errors from scanners
            if "did not receive a valid HTTP request" in msg:
                return False
        return True

# Apply noise filter
ws_logger = logging.getLogger("websockets.server")
ws_logger.addFilter(HandshakeNoiseFilter())
# Also set these to ERROR to avoid redundant non-stacktrace warnings
logging.getLogger("websockets.protocol").setLevel(logging.ERROR)

class RelayServer:
    def __init__(self, host: str = "0.0.0.0", port: int = 8766, token: Optional[str] = None):
        self.host = host
        self.port = port
        self.token = token or os.getenv("RELAY_TOKEN")
        # Map to store active relay pairs: { user_id: {"mac": websocket, "app": websocket} }
        self.relays: Dict[str, Dict[str, Optional[websockets.WebSocketServerProtocol]]] = {}

        if not self.token:
            logger.warning("RELAY_TOKEN not set! Relay will be unauthorized.")

    async def process_request(self, websocket, request):
        """Intercept unauthorized requests during handshake."""
        path = request.path
        headers = request.headers
        
        # Get real client IP if behind proxy
        # In process_request, request.headers is already available
        raw_addr = getattr(websocket, "remote_address", "unknown")
        remote_ip = raw_addr[0] if isinstance(raw_addr, tuple) else raw_addr
        remote_addr = headers.get("X-Forwarded-For", remote_ip)
        
        # 1. Try Authorization Header
        auth_header = headers.get("Authorization")
        
        # 2. Try Query Parameter
        query_token = None
        if "?" in path:
            parsed = urlparse(path)
            params = parse_qs(parsed.query)
            query_token = params.get("token", [None])[0]

        expected = f"Bearer {self.token}"
        if self.token and auth_header != expected and query_token != self.token:
            logger.warning(f"Handshake Auth failed for path: {path} from {remote_addr}")
            
            # websockets 14.0+ (asyncio) expects a Response object, not a tuple
            if hasattr(websocket, "respond"):
                from http import HTTPStatus
                return websocket.respond(HTTPStatus.UNAUTHORIZED, "Unauthorized\n")
            
            # Legacy fallback for older websockets versions
            return (401, [("Content-Type", "text/plain")], b"Unauthorized\n")
        
        return None

    def is_alive(self, ws):
        """Check if a websocket connection is still alive."""
        return ws is not None and ws.state == websockets.protocol.State.OPEN

    async def _handle_relay_logic(self, websocket, role, user_id):
        if user_id not in self.relays:
            self.relays[user_id] = {"mac": None, "app": None}
        
        # Get real client IP (Compatible with websockets <13.0 and >=13.0)
        headers = getattr(websocket, "request_headers", None)
        if headers is None and hasattr(websocket, "request"):
            headers = getattr(websocket.request, "headers", None)
        
        # remote_address can be (ip, port) tuple or string
        raw_addr = getattr(websocket, "remote_address", "unknown")
        remote_ip = raw_addr[0] if isinstance(raw_addr, tuple) else raw_addr
        
        if headers and "X-Forwarded-For" in headers:
            remote_addr = headers["X-Forwarded-For"]
        else:
            remote_addr = remote_ip
        
        old_ws = self.relays[user_id].get(role)
        if self.is_alive(old_ws):
            await old_ws.close(1001, "Replaced")

        self.relays[user_id][role] = websocket
        logger.info(f"User {user_id}: {role} connected from {remote_addr}.")

        try:
            async for message in websocket:
                other_role = "app" if role == "mac" else "mac"
                other_ws = self.relays[user_id].get(other_role)
                
                if self.is_alive(other_ws):
                    try:
                        await asyncio.wait_for(other_ws.send(message), timeout=5.0)
                    except Exception as e:
                        logger.error(f"Forward error from {role} to {other_role}: {e}")
                else:
                    logger.debug(f"User {user_id}: {role} message dropped ({other_role} offline)")
                    
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"User {user_id}: {role} disconnected ({remote_addr}).")
        except Exception as e:
            logger.error(f"User {user_id}: Relay logic error: {e}")
        finally:
            if self.relays.get(user_id) and self.relays[user_id].get(role) == websocket:
                self.relays[user_id][role] = None

    async def handler(self, websocket):
        """Main handler for websockets.serve."""
        try:
            path = websocket.request.path
            # Strip query params for routing
            base_path = path.split("?")[0]
            parts = base_path.strip("/").split("/")
            
            if len(parts) == 3 and parts[0] == "relay":
                role, user_id = parts[1], parts[2]
                if role in ["mac", "app"]:
                    await self._handle_relay_logic(websocket, role, user_id)
                else:
                    await websocket.close(1003, "Invalid Role")
            else:
                await websocket.close(1003, "Invalid Path")
        except Exception as e:
            logger.error(f"Handler error: {e}")
            await websocket.close(1011, "Internal Error")

    async def start(self):
        """Start the relay server."""
        port = int(os.getenv("RELAY_PORT", self.port))
        host = os.getenv("RELAY_HOST", self.host)
        
        # websockets 13.0+ captures handshake exceptions. 
        # We'll use a custom log filter or handle it in handler.
        
        async with websockets.serve(
            self.handler, 
            host, 
            port,
            process_request=self.process_request,
            ping_interval=30,
            ping_timeout=10
        ):
            logger.info(f"Relay Server started on ws://{host}:{port}")
            # The error "websockets.exceptions.InvalidMessage" usually happens 
            # at a lower level than the handler. We can't easily catch it here
            # without subclassing or wrapping the server, but we can 
            # add a custom logging filter or just accept it as noise for now.
            # However, we can improve our own logs.
            await asyncio.Future() # Run forever

if __name__ == "__main__":
    from dotenv import load_dotenv
    load_dotenv()
    
    # Use environment variables if available
    port = int(os.getenv("RELAY_PORT", 8766))
    host = os.getenv("RELAY_HOST", "0.0.0.0")
    token = os.getenv("RELAY_TOKEN")
    
    server = RelayServer(host=host, port=port, token=token)
    asyncio.run(server.start())
