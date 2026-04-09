import asyncio
import websockets
import os
import json
import logging
import sys
import argparse
import time
import signal
from datetime import datetime
from pathlib import Path

from src.transport.mdns import LocalDiscovery
from src.transport.e2ee import E2EEManager
from src.config.manager import config
from src.orchestration.dispatcher import MessageDispatcher
from src.persistence.database import KanbanDB
from src.logger import setup_logger, set_request_id

# Set up structured logger
logger = setup_logger("BridgeRelay")

class ConnectionState:
    """Manages the status of local and relay connections (P2-1 FIX)."""
    def __init__(self):
        self.local_clients = set()
        self.relay_ws = None
        self.running = True

    def add_local(self, ws):
        self.local_clients.add(ws)

    def remove_local(self, ws):
        self.local_clients.discard(ws)

    @property
    def is_relay_connected(self) -> bool:
        return self.relay_ws is not None and not self.relay_ws.closed

class UnifiedBridge:
    def __init__(
        self,
        user_id=None,
        relay_url=None,
        token=None,
        session_key=None,
        workspace_cwd=None,
        fallback_command=None,
    ):
        self.user_id = user_id or config.user_id
        self.relay_url = f"{(relay_url or config.relay_url).rstrip('/')}/relay/mac/{self.user_id}"
        self.token = token or config.get("relay.token")
        self._workspace_cwd = workspace_cwd or config.get("system.workspace_root")
        self._fallback_command = fallback_command

        self.db = KanbanDB()
        self.dispatcher = MessageDispatcher(self.db)
        self.local_discovery = LocalDiscovery(self.user_id)
        self.state = ConnectionState()

        # ECDH pair for initial handshake
        saved_keys = E2EEManager.load_key_pair(self.user_id)
        if saved_keys:
            self.private_key, self.public_key_hex = saved_keys
            logger.info(f"Loaded existing ECDH key pair for user: {self.user_id}")
        else:
            self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
            E2EEManager.save_key_pair(self.user_id, self.private_key, self.public_key_hex)
            logger.info(f"Generated new ECDH key pair for user: {self.user_id}")

        self.e2ee = E2EEManager(session_key_hex=session_key)

    async def stop(self):
        """Gracefully stop the bridge and all child processes."""
        if not self.state.running:
            return
        
        logger.info("Graceful shutdown initiated...")
        self.state.running = False
        self.local_discovery.stop_broadcast()
        
        # 1. Stop all engines and tasks via dispatcher
        await self.dispatcher.shutdown()

        # 2. Close relay connection
        if self.state.relay_ws:
            await self.state.relay_ws.close()
            self.state.relay_ws = None

        # 3. Close database connections
        await self.db.close_all_async()
        
        logger.info("Graceful shutdown complete.")

    async def start(self):
        logger.info(f"Starting Unified Bridge for User: {self.user_id}")
        logger.info(f"Pairing Public Key: {self.public_key_hex}")
        logger.info(f"Workspace: {self._workspace_cwd}")

        # Register signal handlers
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, lambda: asyncio.create_task(self.stop()))
            except NotImplementedError:
                pass

        self.local_discovery.start_broadcast()

        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", 8766)
        logger.info("Local Server listening on ws://0.0.0.0:8766")

        try:
            await asyncio.gather(
                local_server, 
                self.maintain_relay_connection(), 
                self.health_check_loop()
            )
        except asyncio.CancelledError:
            logger.info("Bridge tasks cancelled.")
        finally:
            await self.stop()

    async def handle_local_client(self, websocket, path=None):
        addr = websocket.remote_address
        logger.info(f"New local client connected: {addr}")
        self.state.add_local(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, websocket)
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Local client {addr} disconnected.")
        finally:
            self.state.remove_local(websocket)

    async def maintain_relay_connection(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        while self.state.running:
            try:
                async with websockets.connect(
                    self.relay_url,
                    ping_interval=30,
                    ping_timeout=10,
                    extra_headers=headers,
                ) as ws:
                    logger.info("Connected to Cloud Relay.")
                    self.state.relay_ws = ws
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, ws)
                    finally:
                        self.state.relay_ws = None
            except Exception:
                if self.state.running:
                    await asyncio.sleep(5)

    async def forward_to_acp(self, message, source_ws):
        """
        Forward message to Dispatcher.
        """
        if not self.state.running:
            return

        addr = (
            source_ws.remote_address
            if hasattr(source_ws, "remote_address")
            else "relay"
        )
        try:
            data = json.loads(message)
            req_id = data.get("id")
            set_request_id(req_id if isinstance(req_id, str) else None)
            
            original_was_e2ee = data.get("method") == "e2ee/envelope"

            # Handle Pairing
            if data.get("method") == "pairing/exchange":
                response = await self.handle_pairing(data)
                response["id"] = data.get("id")
                response["jsonrpc"] = "2.0"
                await source_ws.send(json.dumps(response))
                return

            # Handle E2EE Envelope
            if original_was_e2ee:
                if not self.e2ee.is_ready:
                    logger.warning(f"Received E2EE envelope from {addr} but session not ready.")
                    return
                try:
                    data = self.e2ee.unwrap_json_rpc(message)
                except Exception as e:
                    logger.error(f"Failed to decrypt E2EE message from {addr}: {e}")
                    return

            # --- ROUTE TO DISPATCHER ---
            async def on_output(output_data):
                await self._send_acp_response(None, output_data, source_ws, original_was_e2ee, is_raw=True)

            response = await self.dispatcher.dispatch(data, on_output=on_output)
            
            if response:
                await self._send_acp_response(data.get("id"), response, source_ws, original_was_e2ee)

        except json.JSONDecodeError:
            logger.warning(f"Received non-JSON message from {addr}")
        except Exception as e:
            logger.error(f"Error in forward_to_acp: {e}")

    async def _send_acp_response(self, request_id, result, source_ws, was_e2ee, is_raw=False):
        """Send response back to the client."""
        if is_raw:
            response = result
        else:
            response = {"jsonrpc": "2.0", "id": request_id}
            if isinstance(result, dict) and "error" in result:
                response["error"] = result["error"]
            else:
                response["result"] = result

        # 1. Local clients receive plaintext or E2EE depending on how they connected
        # Notifications are broadcast to all local clients
        if is_raw:
            payload = json.dumps(response)
            for client in list(self.state.local_clients):
                try:
                    await client.send(payload)
                except Exception:
                    self.state.remove_local(client)

        # 2. Specific response goes back to source
        else:
            try:
                # Responses are ALWAYS sent back in the format they arrived (E2EE if source was E2EE)
                final_resp = response
                if was_e2ee and self.e2ee.is_ready:
                    final_resp = self.e2ee.wrap_json_rpc(response)
                await source_ws.send(json.dumps(final_resp))
            except Exception as e:
                logger.debug(f"Failed to send response back to client: {e}")

        # 3. Forward to Relay if it's a notification and relay is connected
        if is_raw and self.state.is_relay_connected and self.e2ee.is_ready:
            try:
                encrypted_env = self.e2ee.wrap_json_rpc(response)
                await self.state.relay_ws.send(json.dumps(encrypted_env))
            except Exception as e:
                logger.error(f"Relay send error: {e}")

    async def handle_pairing(self, data):
        peer_public = data.get("params", {}).get("publicKey")
        if not peer_public:
            return {"error": "Missing publicKey"}

        try:
            shared_secret = E2EEManager.derive_shared_secret(
                self.private_key, peer_public
            )
            self.e2ee.setup_session(shared_secret)
            logger.info("ECDH Pairing Successful. Session key derived.")
            return {"result": {"publicKey": self.public_key_hex, "status": "paired"}}
        except Exception as e:
            logger.error(f"Pairing failed: {e}")
            return {"error": "Pairing calculation error"}

    async def health_check_loop(self):
        while self.state.running:
            await asyncio.sleep(30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", default=None)
    parser.add_argument("--relay-url", default=None)
    parser.add_argument("--token", help="Relay Auth Token")
    parser.add_argument("--e2ee-key", help="Hex Key for E2EE Session")
    parser.add_argument("--workspace-cwd", help="Default workspace path")
    args = parser.parse_args()

    bridge = UnifiedBridge(
        args.user_id,
        args.relay_url,
        token=args.token,
        session_key=args.e2ee_key,
        workspace_cwd=args.workspace_cwd
    )

    try:
        asyncio.run(bridge.start())
    except (KeyboardInterrupt, SystemExit):
        pass
    except Exception as e:
        logger.critical(f"Bridge crashed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
