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
        server = await websockets.serve(self._handle_local_client, "0.0.0.0", 8766)
        self.logger.info("Local tool bridge started on ws://localhost:8766")
        await server.wait_closed()

    async def _handle_local_client(self, websocket, path=None):
        self._local_clients.add(websocket)
        try:
            async for message in websocket:
                data = json.loads(message)
                # Handle raw ACP from local tools
                await self.handle_rpc(data, lambda n: websocket.send(json.dumps(n)))
        except:
            pass
        finally:
            self._local_clients.remove(websocket)

    async def _run_relay_loop(self):
        headers = {"X-User-ID": self.user_id}
        if self.token: headers["Authorization"] = f"Bearer {self.token}"
        
        while True:
            try:
                async with websockets.connect(self.relay_url, extra_headers=headers) as ws:
                    self.logger.info("Connected to Relay Server")
                    async for message in ws:
                        data = json.loads(message)
                        asyncio.create_task(self.handle_rpc(data, lambda n: ws.send(json.dumps(n))))
            except Exception as e:
                self.logger.error(f"Relay error: {e}. Retrying in 5s...")
                await asyncio.sleep(5)

    async def on_ui_response(self, request_id: str, result: Any):
        """Phase 3.2: Standardized UI Response Resolver."""
        future = self._pending_ui_requests.pop(request_id, None)
        if future and not future.done():
            future.set_result(result)

    async def handle_rpc(self, data: Dict[str, Any], send_output: Callable):
        # Wrap the output to await it correctly
        async def safe_send(msg):
            try: await send_output(msg)
            except: pass

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

        return await self.dispatcher.dispatch(data, on_ui_request)

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
