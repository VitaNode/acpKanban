import asyncio
import json
import logging
import uuid
import argparse
import sys
import websockets
from typing import Dict, Any, Optional, Callable
from src.orchestration.dispatcher import MessageDispatcher
from src.persistence.database import KanbanDB
from src.transport.bus import bus
from src.logger import setup_logger

class UnifiedBridge:
    def __init__(self, user_id, relay_url, token=None, session_key=None, workspace_cwd=None):
        self.logger = setup_logger(f"Bridge[{user_id[:8]}]")
        self.user_id = user_id
        self.relay_url = relay_url
        self.token = token
        self.db = KanbanDB()
        self.dispatcher = MessageDispatcher(self.db)
        self._pending_ui_requests: Dict[str, asyncio.Future] = {}
        self._local_clients = set()

    async def start(self):
        """Starts both local and relay servers."""
        self.logger.info(f"Bridge starting for user {self.user_id}...")

        # 1. Start Relay Connection (if URL provided)
        if self.relay_url:
            asyncio.create_task(self._run_relay_loop())

        # 2. Start Local WebSocket Server (port 8766) for direct tool access
        # Note: websockets.serve() returns a Server object, not a coroutine
        server = await websockets.serve(
            self._handle_local_client,
            "0.0.0.0",
            8766,
            ping_interval=20,
            ping_timeout=20,
        )
        self.logger.info("Local tool bridge started on ws://0.0.0.0:8766")
        
        # Keep the server running
        try:
            await asyncio.Future()  # Run forever
        except asyncio.CancelledError:
            server.close()
            await server.wait_closed()

    async def _handle_local_client(self, websocket):
        """Handle incoming WebSocket connections from Flutter or local tools."""
        self._local_clients.add(websocket)
        self.logger.info(f"Client connected: {websocket.remote_address}")
        try:
            async for message in websocket:
                try:
                    data = json.loads(message)
                    self.logger.debug(f"Received: {data.get('method', 'N/A')}")
                    
                    # Handle E2EE pairing request
                    if data.get('method') == 'pairing/exchange':
                        await self._handle_pairing_exchange(websocket, data)
                        continue
                    
                    await self.handle_rpc(data, lambda n: websocket.send(json.dumps(n)))
                except json.JSONDecodeError:
                    self.logger.warning(f"Invalid JSON: {message[:100]}")
                except Exception as e:
                    self.logger.error(f"RPC handling error: {e}", exc_info=True)
        except websockets.exceptions.ConnectionClosed:
            self.logger.info(f"Client disconnected: {websocket.remote_address}")
        except Exception as e:
            self.logger.error(f"Client error: {e}", exc_info=True)
        finally:
            self._local_clients.discard(websocket)
            self.logger.info(f"Client removed: {websocket.remote_address}")

    async def _handle_pairing_exchange(self, websocket, data):
        """Handle E2EE pairing/exchange request."""
        request_id = data.get('id')
        params = data.get('params', {})
        client_public_key = params.get('publicKey')
        
        self.logger.info(f"Pairing request received, client public key: {client_public_key[:20]}...")
        
        # For now, accept pairing without generating our own key
        # In production, we would generate our own key pair here
        response = {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "publicKey": "bridge-public-key-placeholder"
            }
        }
        
        await websocket.send(json.dumps(response))
        self.logger.info("Pairing response sent")

    async def _run_relay_loop(self):
        headers = {"X-User-ID": self.user_id}
        if self.token: headers["Authorization"] = f"Bearer {self.token}"

        while True:
            try:
                # websockets >= 13.0 uses additional_headers instead of extra_headers
                connect_kwargs = {"additional_headers": headers}
                # Fallback for older versions
                try:
                    async with websockets.connect(self.relay_url, **connect_kwargs) as ws:
                        await self._handle_relay_connection(ws)
                except TypeError:
                    # Old version fallback
                    connect_kwargs = {"extra_headers": headers}
                    async with websockets.connect(self.relay_url, **connect_kwargs) as ws:
                        await self._handle_relay_connection(ws)
            except Exception as e:
                self.logger.error(f"Relay error: {e}. Retrying in 5s...")
                await asyncio.sleep(5)

    async def _handle_relay_connection(self, ws):
        """Handle an established relay connection."""
        self.logger.info("Connected to Relay Server")
        async for message in ws:
            data = json.loads(message)
            asyncio.create_task(self.handle_rpc(data, lambda n: ws.send(json.dumps(n))))

    async def on_ui_response(self, request_id: str, result: Any):
        """Phase 3.2: Standardized UI Response Resolver."""
        future = self._pending_ui_requests.pop(request_id, None)
        if future and not future.done():
            future.set_result(result)

    async def handle_rpc(self, data: Dict[str, Any], send_output: Callable):
        # Wrap the output to await it correctly
        async def safe_send(msg):
            try: await send_output(msg)
            except Exception as e:
                self.logger.error(f"Failed to send output: {e}")

        async def on_ui_request(method, params):
            rid = str(uuid.uuid4())
            fut = asyncio.get_event_loop().create_future()
            self._pending_ui_requests[rid] = fut
            await safe_send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            try:
                return await asyncio.wait_for(fut, timeout=60.0)
            except asyncio.TimeoutError:
                self._pending_ui_requests.pop(rid, None)
                return {"error": {"code": -32000, "message": "UI Request Timeout"}}

        result = await self.dispatcher.dispatch(data, on_ui_request)
        
        # If dispatcher returned an error, send it back to the client
        if result and "error" in result:
            request_id = data.get("id")
            if request_id is not None:
                error_response = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": result["error"]
                }
                await safe_send(error_response)
                self.logger.warning(f"Sent error to client: {result['error']}")
        
        return result

    async def shutdown(self):
        await self.dispatcher.shutdown()

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--relay-url")
    parser.add_argument("--token")
    parser.add_argument("--workspace-cwd")
    args, unknown = parser.parse_known_args()

    bridge = UnifiedBridge(args.user_id, args.relay_url, token=args.token, workspace_cwd=args.workspace_cwd)
    try:
        await bridge.start()
    except KeyboardInterrupt:
        await bridge.shutdown()

if __name__ == "__main__":
    asyncio.run(main())
