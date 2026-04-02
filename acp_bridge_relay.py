import asyncio
import websockets
import os
import json
import logging
import sys
import argparse
import time
from datetime import datetime
from pathlib import Path
from acp_client import ACPClient
from mdns_discovery import LocalDiscovery
from e2ee import E2EEManager
from acp_adapter import ACPProtocolAdapter

# Set up logging
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("BridgeRelay")

CONFIG_PATH = Path(__file__).parent / "acp_config.json"


class SessionContext:
    """Holds ACP client and adapter for a specific card."""

    def __init__(
        self,
        card_id: str,
        provider_id: str,
        acp_client,
        adapter,
        acp_session_id: str = None,
        workspace_path: str = None,
    ):
        self.card_id = card_id
        self.provider_id = provider_id
        self.acp_client = acp_client
        self.adapter = adapter
        self.last_active = time.time()
        self.acp_session_id = acp_session_id
        self.workspace_path = workspace_path
        self.needs_recovery = False

    def is_alive(self) -> bool:
        return (
            self.acp_client.process is not None
            and self.acp_client.process.returncode is None
        )


class UnifiedBridge:
    def __init__(
        self,
        user_id,
        relay_url,
        token=None,
        session_key=None,
        workspace_cwd=None,
        fallback_command=None,
    ):
        self.user_id = user_id
        self.relay_url = f"{relay_url.rstrip('/')}/relay/mac/{user_id}"
        self.token = token or os.getenv("RELAY_TOKEN", "default_secret")
        self._workspace_cwd = workspace_cwd or str(Path.home())
        self._fallback_command = fallback_command

        self.config = self._load_config()
        self.sessions = {}  # card_id -> SessionContext
        self._session_locks = {}  # card_id -> asyncio.Lock
        self.local_discovery = LocalDiscovery(user_id)

        # ECDH pair for initial handshake (load from storage or generate new)
        saved_keys = E2EEManager.load_key_pair(user_id)
        if saved_keys:
            self.private_key, self.public_key_hex = saved_keys
            logger.info(f"Loaded existing ECDH key pair for user: {user_id}")
        else:
            self.private_key, self.public_key_hex = E2EEManager.generate_key_pair()
            E2EEManager.save_key_pair(user_id, self.private_key, self.public_key_hex)
            logger.info(f"Generated new ECDH key pair for user: {user_id}")

        # Session key manager (Starts NOT ready)
        self.e2ee = E2EEManager(session_key_hex=session_key)

        self.local_clients = set()
        self.relay_ws = None
        self.running = True

    def _load_config(self) -> dict:
        try:
            with open(CONFIG_PATH, "r") as f:
                config = json.load(f)
            providers = config.get("providers", [])
            if not providers:
                logger.error(
                    f"No providers defined in {CONFIG_PATH}. "
                    "Bridge cannot start without at least one provider."
                )
                raise RuntimeError("acp_config.json must define at least one provider")
            logger.info(f"Loaded ACP config: {len(providers)} providers")
            return config
        except FileNotFoundError:
            logger.error(
                f"Config file not found: {CONFIG_PATH}. "
                "Create acp_config.json with at least one provider."
            )
            raise
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in {CONFIG_PATH}: {e}")
            raise

    def _get_provider_config(self, provider_id: str) -> dict:
        for p in self.config.get("providers", []):
            if p["id"] == provider_id:
                return p
        raise ValueError(f"Provider '{provider_id}' not found in config")

    async def _get_or_create_session(self, card_id: str) -> SessionContext:
        """Get existing session or create new one, with lock protection."""
        session = self.sessions.get(card_id)
        if session and session.is_alive() and not session.needs_recovery:
            session.last_active = time.time()
            return session

        if card_id not in self._session_locks:
            self._session_locks[card_id] = asyncio.Lock()

        async with self._session_locks[card_id]:
            session = self.sessions.get(card_id)
            if session and session.is_alive() and not session.needs_recovery:
                session.last_active = time.time()
                return session

            from database import KanbanDB

            db = KanbanDB()
            card = await asyncio.to_thread(db.get_card, card_id)

            if not card:
                raise ValueError(f"Card {card_id} not found in database")

            provider_id = card.get("acp_provider_id")
            acp_session_id = card.get("acp_session_id")

            if not provider_id:
                provider_id = self.config.get("default_provider", "gemini")
                logger.warning(
                    f"Card {card_id} has no provider, using default: {provider_id}"
                )

            cursor = await asyncio.to_thread(db.get_column, card["column_id"])
            project_id = cursor.get("project_id") if cursor else None
            project = (
                await asyncio.to_thread(db.get_project, project_id)
                if project_id
                else None
            )
            workspace_path = project.get("workspace_path") if project else None

            if not workspace_path:
                workspace_path = self._workspace_cwd

            try:
                provider_cfg = self._get_provider_config(provider_id)
                command = provider_cfg["command"]
            except ValueError:
                if self._fallback_command:
                    command = self._fallback_command
                    logger.warning(
                        f"Provider '{provider_id}' not in config, using fallback command"
                    )
                else:
                    raise ValueError(
                        f"Provider '{provider_id}' not found and no fallback command"
                    )

            max_sessions = self.config.get("max_sessions", 10)
            if len(self.sessions) >= max_sessions:
                await self._evict_idle_session()

            logger.info(
                f"Creating new ACP session for card {card_id} with provider {provider_id}"
            )
            acp_client = ACPClient(command=command, name=f"ACP-{provider_id}")
            acp_client.add_handler(self._make_acp_message_handler(card_id))
            await acp_client.start()

            adapter = ACPProtocolAdapter(acp_client, workspace_cwd=workspace_path)

            async def persist_callback(card_id: str, session_id: str):
                from database import KanbanDB

                db = KanbanDB()
                await asyncio.to_thread(db.update_card_session_id, card_id, session_id)

            adapter._persist_session_callback = persist_callback

            session = SessionContext(
                card_id=card_id,
                provider_id=provider_id,
                acp_client=acp_client,
                adapter=adapter,
                acp_session_id=acp_session_id,
                workspace_path=workspace_path,
            )
            self.sessions[card_id] = session
            logger.info(f"Session created for card {card_id}: {provider_id}")

            return session

    async def _evict_idle_session(self):
        """Evict the least recently used session."""
        if not self.sessions:
            return
        oldest_card = min(
            self.sessions.keys(), key=lambda k: self.sessions[k].last_active
        )
        await self._close_session(oldest_card)
        logger.info(f"Evicted idle session for card: {oldest_card}")

    async def _close_session(self, card_id: str):
        """Close and clean up a session."""
        session = self.sessions.pop(card_id, None)
        if session:
            try:
                await session.acp_client.stop()
            except Exception as e:
                logger.warning(f"Error closing session for {card_id}: {e}")
        self._session_locks.pop(card_id, None)

    def _make_acp_message_handler(self, card_id: str):
        """Create a message handler bound to a specific card_id."""

        async def handler(data):
            await self.on_acp_message(data, card_id)

        return handler

    async def start(self):
        logger.info(f"Starting Unified Bridge for User: {self.user_id}")
        logger.info(f"Pairing Public Key: {self.public_key_hex}")
        logger.info(f"Workspace: {self._workspace_cwd}")

        self.local_discovery.start_broadcast()

        local_server = websockets.serve(self.handle_local_client, "0.0.0.0", 8766)
        logger.info("Local Server listening on ws://0.0.0.0:8766")

        await asyncio.gather(
            local_server, self.maintain_relay_connection(), self.health_check_loop()
        )

    async def handle_local_client(self, websocket, path=None):
        addr = websocket.remote_address
        logger.info(f"New local client connected: {addr}")
        self.local_clients.add(websocket)
        try:
            async for message in websocket:
                await self.forward_to_acp(message, websocket)
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Local client {addr} disconnected.")
        finally:
            self.local_clients.discard(websocket)

    async def maintain_relay_connection(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        while self.running:
            try:
                async with websockets.connect(
                    self.relay_url,
                    ping_interval=30,
                    ping_timeout=10,
                    extra_headers=headers,
                ) as ws:
                    logger.info("Connected to Cloud Relay.")
                    self.relay_ws = ws
                    try:
                        async for message in ws:
                            await self.forward_to_acp(message, ws)
                    finally:
                        self.relay_ws = None
            except Exception as e:
                await asyncio.sleep(5)

    async def on_acp_message(self, data, card_id: str = None):
        """
        Broadcast output from ACP process.
        """
        # Filter: Only forward notifications, not responses
        if "method" not in data:
            return

        # Filter verbose notifications
        if data.get("method") == "session/update":
            update_type = data.get("params", {}).get("update", {}).get("sessionUpdate")
            if update_type in ["agent_thought_chunk"]:
                return

        plaintext_str = json.dumps(data)

        # 1. Local clients receive plaintext
        for client in list(self.local_clients):
            try:
                await client.send(plaintext_str)
            except Exception:
                self.local_clients.discard(client)

        # 2. Cloud Relay receives E2EE encrypted messages
        if self.relay_ws and not self.relay_ws.closed:
            if self.e2ee.is_ready:
                try:
                    encrypted_env = json.dumps(self.e2ee.wrap_json_rpc(data))
                    await self.relay_ws.send(encrypted_env)
                    logger.debug(
                        f"-> Sent E2EE notification to relay: {data.get('method')}"
                    )
                except Exception as e:
                    logger.error(f"E2EE Wrap error for notification: {e}")
            else:
                logger.debug(
                    "Relay connected but E2EE not paired. Dropping ACP notification."
                )

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

    async def forward_to_acp(self, message, source_ws):
        """
        Forward message to ACP CLI or handle via adapter.
        """
        addr = (
            source_ws.remote_address
            if hasattr(source_ws, "remote_address")
            else "relay"
        )
        try:
            data = json.loads(message)
            original_was_e2ee = data.get("method") == "e2ee/envelope"

            # Handle Pairing (Plaintext)
            if data.get("method") == "pairing/exchange":
                response = await self.handle_pairing(data)
                response["id"] = data.get("id")
                response["jsonrpc"] = "2.0"
                await source_ws.send(json.dumps(response))
                return

            # Handle E2EE Envelope - decrypt and continue processing
            if original_was_e2ee:
                if not self.e2ee.is_ready:
                    logger.warning(
                        f"Received E2EE envelope from {addr} but session not ready. Dropping."
                    )
                    return
                try:
                    data = self.e2ee.unwrap_json_rpc(message)
                    logger.debug(f"Decrypted E2EE from {addr}: {data.get('method')}")
                    message = json.dumps(data)
                except Exception as e:
                    logger.error(f"Failed to decrypt E2EE message from {addr}: {e}")
                    return

            # Extract fields
            method = data.get("method")
            params = data.get("params", {})
            request_id = data.get("id")

            if request_id is not None:
                card_id = params.get("card_id")

                if card_id and method in ("chat/message", "session/prompt"):
                    try:
                        session = await self._get_or_create_session(card_id)
                        params_with_recovery = dict(params)
                        params_with_recovery["acp_session_id"] = session.acp_session_id
                        params_with_recovery["workspace_path"] = session.workspace_path

                        response_result = await session.adapter.handle_request(
                            method, params_with_recovery
                        )

                        if (
                            isinstance(response_result, dict)
                            and "session_id" in response_result
                        ):
                            new_session_id = response_result["session_id"]
                            if new_session_id != session.acp_session_id:
                                from database import KanbanDB

                                db = KanbanDB()
                                await asyncio.to_thread(
                                    db.update_card_session_id, card_id, new_session_id
                                )
                                session.acp_session_id = new_session_id
                                session.needs_recovery = False
                                logger.info(
                                    f"Persisted session_id for card {card_id}: {new_session_id}"
                                )
                    except Exception as e:
                        logger.error(f"Session error for card {card_id}: {e}")
                        response_result = {"error": {"code": -32603, "message": str(e)}}
                else:
                    try:
                        if self.sessions:
                            session = next(iter(self.sessions.values()))
                        else:
                            session = await self._get_or_create_session("_default")
                        response_result = await session.adapter.handle_request(
                            method, params
                        )
                    except Exception as e:
                        logger.error(f"Adapter error for {method}: {e}")
                        response_result = {"error": {"code": -32603, "message": str(e)}}

                # Build response envelope
                response = {"jsonrpc": "2.0", "id": request_id}

                if isinstance(response_result, dict) and "error" in response_result:
                    response["error"] = response_result["error"]
                else:
                    response["result"] = response_result

                # Smart encryption
                if original_was_e2ee and self.e2ee.is_ready:
                    response = self.e2ee.wrap_json_rpc(response)
                    await source_ws.send(json.dumps(response))
                else:
                    await source_ws.send(json.dumps(response))

                logger.info(f"-> Handled {method}: {request_id}")
                return

            # Handle notifications (no ID) - forward to appropriate session
            card_id_for_notification = params.get("card_id")
            if card_id_for_notification and card_id_for_notification in self.sessions:
                session = self.sessions[card_id_for_notification]
                if session.is_alive():
                    payload = (json.dumps(data) + "\n").encode()
                    session.acp_client.process.stdin.write(payload)
                    await session.acp_client.process.stdin.drain()
                    logger.info(f"-> Forwarded notification to ACP: {method}")
                else:
                    logger.error(
                        f"ACP Process not running for card {card_id_for_notification}."
                    )
            else:
                logger.warning(f"No session for notification: {method}")

        except json.JSONDecodeError:
            logger.warning(f"Received non-JSON message from {addr}: {message[:50]}...")
        except Exception as e:
            logger.error(f"Unexpected error in forward_to_acp from {addr}: {e}")

    async def health_check_loop(self):
        while self.running:
            dead_cards = []
            for card_id, session in list(self.sessions.items()):
                if not session.is_alive():
                    logger.critical(f"ACP Process died for card {card_id}!")
                    session.needs_recovery = True
                    dead_cards.append(card_id)

            for card_id in dead_cards:
                try:
                    await self.sessions[card_id].acp_client.stop()
                except Exception as e:
                    logger.warning(f"Error stopping dead process for {card_id}: {e}")
                logger.info(f"Marked session for card {card_id} as needs_recovery")

            timeout = self.config.get("session_idle_timeout_minutes", 30) * 60
            now = time.time()
            for card_id, session in list(self.sessions.items()):
                if now - session.last_active > timeout:
                    logger.info(f"Cleaning up idle session for card: {card_id}")
                    await self._close_session(card_id)

            await asyncio.sleep(10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", default="test_user")
    parser.add_argument("--relay-url", default="wss://mybot.siliconpulse.cc")
    parser.add_argument(
        "--command",
        default=None,
        help="Fallback ACP command (optional, used when card has no provider)",
    )
    parser.add_argument("--token", help="Relay Auth Token")
    parser.add_argument(
        "--e2ee-key", help="32-byte Hex Key for E2EE Session (Optional, for pre-paired)"
    )
    parser.add_argument("--workspace-cwd", help="Default workspace path")
    args = parser.parse_args()

    bridge = UnifiedBridge(
        args.user_id,
        args.relay_url,
        token=args.token,
        session_key=args.e2ee_key,
        workspace_cwd=args.workspace_cwd,
        fallback_command=args.command.split() if args.command else None,
    )
    try:
        asyncio.run(bridge.start())
    except KeyboardInterrupt:
        pass
