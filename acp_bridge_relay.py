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
        supports_yolo: bool = False,
    ):
        self.card_id = card_id
        self.provider_id = provider_id
        self.acp_client = acp_client
        self.adapter = adapter
        self.last_active = time.time()
        self.acp_session_id = acp_session_id
        self.workspace_path = workspace_path
        self.needs_recovery = False
        self.supports_yolo = supports_yolo

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

        self.e2ee = E2EEManager(session_key_hex=session_key)

        self.local_clients = set()
        self.relay_ws = None
        self.running = True
        self.system_config = {}  # Store cloud API settings for summaries/embeddings
        self.active_turns = {}  # card_id -> background task

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

        lock = self._session_locks.setdefault(card_id, asyncio.Lock())
        async with lock:
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
                command = list(provider_cfg["command"])  # Copy to avoid mutating original
                supports_yolo = provider_cfg.get("supports_yolo", False)
            except ValueError:
                if self._fallback_command:
                    command = list(self._fallback_command)
                    supports_yolo = False
                    logger.warning(
                        f"Provider '{provider_id}' not in config, using fallback command"
                    )
                else:
                    raise ValueError(
                        f"Provider '{provider_id}' not found and no fallback command"
                    )

            # Add yolo flag for Gemini CLI (--approval-mode=yolo)
            if supports_yolo and provider_id == "gemini":
                if "--approval-mode=yolo" not in command:
                    command.extend(["--approval-mode", "yolo"])
                    logger.info(f"Added --approval-mode=yolo to Gemini CLI command")

            max_sessions = self.config.get("max_sessions", 10)
            if len(self.sessions) >= max_sessions:
                await self._evict_idle_session()

            logger.info(
                f"Creating new ACP session for card {card_id} with provider {provider_id} (yolo={supports_yolo})"
            )
            acp_client = ACPClient(command=command, name=f"ACP-{provider_id}")
            acp_client.add_handler(self._make_acp_message_handler(card_id))

            # Add auto-approve handler for yolo-enabled providers
            if supports_yolo:
                acp_client.add_handler(self._make_yolo_auto_approve_handler(acp_client))

            await acp_client.start()

            adapter = ACPProtocolAdapter(acp_client, workspace_cwd=workspace_path)
            adapter._persist_session_callback = self._make_persist_callback(card_id)

            session = SessionContext(
                card_id=card_id,
                provider_id=provider_id,
                acp_client=acp_client,
                adapter=adapter,
                acp_session_id=acp_session_id,
                workspace_path=workspace_path,
                supports_yolo=supports_yolo,
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

    def _make_yolo_auto_approve_handler(self, acp_client):
        """Create a handler that auto-approves permission requests for yolo mode."""

        async def handler(data):
            method = data.get("method")
            msg_id = data.get("id")

            # Auto-approve session/request_permission requests
            if method == "session/request_permission" and msg_id is not None:
                logger.info(f"[YOLO] Auto-approving permission request: {msg_id}")
                try:
                    await acp_client.respond(
                        msg_id,
                        result={
                            "outcome": {
                                "outcome": "selected",
                                "optionId": "allow_once"
                            }
                        }
                    )
                except Exception as e:
                    logger.error(f"[YOLO] Failed to auto-approve: {e}")

        return handler

    def _make_persist_callback(self, card_id: str):
        """Create a persist callback for a specific card_id to avoid closure leaks."""

        async def callback(cid: str, session_id: str):
            from database import KanbanDB

            db = KanbanDB()
            # Use the card_id from the outer scope to ensure integrity
            await asyncio.to_thread(db.update_card_session_id, card_id, session_id)

        return callback

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
        Broadcast output from ACP process and persist to database.
        """
        # --- PERSISTENCE LOGIC ---
        if card_id and data.get("method") == "session/update":
            update = data.get("params", {}).get("update", {})
            update_type = update.get("sessionUpdate")
            
            from database import KanbanDB
            db = KanbanDB()

            if update_type == "agent_message_chunk":
                content = update.get("content", {})
                text = content.get("text", "") if isinstance(content, dict) else ""
                if text:
                    # assistant message is NOT complete while streaming
                    await asyncio.to_thread(db.append_session_message, card_id, "assistant", text, is_complete=False)
            
            elif update_type == "tool_call":
                title = update.get("title") or update.get("tool") or "Tool Call"
                status = update.get("status", "pending")
                text = f"🛠️ **{title}** ({status})"
                # Tool calls are saved as assistant messages with metadata for later updates
                await asyncio.to_thread(
                    db.add_session_message, 
                    card_id, "assistant", text, 
                    {"type": "tool_call", "toolCallId": update.get("toolCallId")}, 
                    is_complete=False # Not complete until tool finishing
                )
            
            elif update_type == "tool_call_update":
                status = update.get("status")
                tool_id = update.get("toolCallId")
                
                if tool_id:
                    # Mark as complete if it's no longer pending/in_progress
                    is_finished = status in ["completed", "failed"]
                    await asyncio.to_thread(
                        db.update_session_message_with_metadata,
                        card_id, "toolCallId", tool_id, None, is_finished
                    )
            
            elif update_type == "stop":
                # Final check to mark last assistant message as complete
                await asyncio.to_thread(db.append_session_message, card_id, "assistant", "", is_complete=True)
                # Cleanup active turns
                if card_id in self.active_turns:
                    self.active_turns.pop(card_id, None)
                    logger.info(f"Turn completed for card {card_id[:8]} (stop signal)")

        # Filter specific verbose update types for UI broadcasting
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
                    # --- ASYNC PROCESSING ---
                    # 1. Concurrency Check: Check if a turn is already active for this card
                    if card_id in self.active_turns:
                        logger.warning(f"Rejecting prompt for card {card_id[:8]}: Turn already active")
                        error_resp = {
                            "error": {
                                "code": -32004, 
                                "message": "Agent is already processing a request for this card. Please wait."
                            }
                        }
                        await self._send_acp_response(request_id, error_resp, source_ws, original_was_e2ee)
                        return

                    # 2. Immediate DB Save (User Message)
                    from database import KanbanDB
                    db = KanbanDB()
                    prompt_text = params.get("message") or params.get("prompt")
                    if isinstance(prompt_text, list):
                        prompt_text = " ".join([item.get("text", "") for item in prompt_text if item.get("type") == "text"])
                    
                    await asyncio.to_thread(db.add_session_message, card_id, "user", prompt_text)
                    logger.info(f"Saved user message for card {card_id[:8]}...")

                    # 3. Immediate Ack to Client
                    ack_response = {"status": "submitted", "card_id": card_id}
                    await self._send_acp_response(request_id, ack_response, source_ws, original_was_e2ee)

                    # 4. Run in background and track
                    task = asyncio.create_task(
                        self._process_acp_request(
                            card_id, method, params, request_id, source_ws, original_was_e2ee
                        )
                    )
                    self.active_turns[card_id] = task
                    return 
                else:
                    # Sync processing for non-prompt methods (initialize, health, etc.)
                    try:
                        if method == "initialize":
                            if "systemConfig" in params:
                                self.system_config = params["systemConfig"]
                                if "api_key" in self.system_config:
                                    os.environ["KANBAN_API_KEY"] = self.system_config["api_key"]
                                if "base_url" in self.system_config:
                                    os.environ["KANBAN_BASE_URL"] = self.system_config["base_url"]
                                if "summary_model" in self.system_config:
                                    os.environ["SUMMARY_MODEL"] = self.system_config["summary_model"]
                                if "embedding_model" in self.system_config:
                                    os.environ["EMBEDDING_MODEL"] = self.system_config["embedding_model"]
                                from database import KanbanDB
                                db = KanbanDB()
                                await asyncio.to_thread(db.set_setting, "system_config", self.system_config)

                        if self.sessions:
                            # Use the first available session for global requests if already running
                            session = next(iter(self.sessions.values()))
                            response_result = await session.adapter.handle_request(method, params)
                        elif method == "initialize":
                            response_result = {
                                "protocolVersion": 1,
                                "capabilities": {"chat": True},
                                "serverInfo": {"name": "Unified-Bridge", "version": "1.0.0"}
                            }
                        else:
                            raise ValueError(f"Method {method} requires card_id or an active session")
                        
                        await self._send_acp_response(request_id, response_result, source_ws, original_was_e2ee)
                    except Exception as e:
                        logger.error(f"Bridge error for {method}: {e}")
                        await self._send_acp_response(request_id, {"error": {"code": -32603, "message": str(e)}}, source_ws, original_was_e2ee)
                    return

            # Handle notifications (no ID) - forward to appropriate session
            card_id_for_notification = params.get("card_id")
            if card_id_for_notification and card_id_for_notification in self.sessions:
                session = self.sessions[card_id_for_notification]
                if session.is_alive():
                    # Strip card_id from params before forwarding to ACP
                    inner_params = dict(params)
                    inner_params.pop("card_id", None)
                    # For notifications, we just write to stdin and don't wait for result
                    payload = (json.dumps({"jsonrpc": "2.0", "method": method, "params": inner_params}) + "\n").encode()
                    session.acp_client.process.stdin.write(payload)
                    await session.acp_client.process.stdin.drain()
                    logger.info(f"-> Forwarded notification to ACP: {method}")
                else:
                    logger.error(f"ACP Process not running for card {card_id_for_notification}.")
            else:
                logger.warning(f"No session for notification: {method}")

        except json.JSONDecodeError:
            logger.warning(f"Received non-JSON message from {addr}: {message[:50]}...")
        except Exception as e:
            logger.error(f"Unexpected error in forward_to_acp from {addr}: {e}")

    async def _process_acp_request(self, card_id, method, params, request_id, source_ws, was_e2ee):
        """Background task for long-running ACP requests."""
        try:
            session = await self._get_or_create_session(card_id)
            params_with_recovery = dict(params)
            params_with_recovery["acp_session_id"] = session.acp_session_id
            params_with_recovery["workspace_path"] = session.workspace_path

            # Use callback for real-time notification processing
            async def on_notification(n):
                await self.on_acp_message(n, card_id)

            response_result = await session.adapter.handle_request(
                method, params_with_recovery, on_notification=on_notification
            )

            # Persist session ID if changed
            if isinstance(response_result, dict) and "session_id" in response_result:
                new_session_id = response_result["session_id"]
                if new_session_id != session.acp_session_id:
                    from database import KanbanDB
                    db = KanbanDB()
                    await asyncio.to_thread(db.update_card_session_id, card_id, new_session_id)
                    session.acp_session_id = new_session_id
                    session.needs_recovery = False

            # Broadcast final completion notification (DB marking handled by 'stop' handler in on_acp_message)
            await self.on_acp_message({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "card_id": card_id,
                    "update": {"sessionUpdate": "stop", "reason": "end_turn"}
                }
            }, card_id)
            logger.info(f"Background task finished for card {card_id[:8]}")
        except Exception as e:
            logger.error(f"Background process error for card {card_id}: {e}")
        finally:
            # Always remove from active_turns
            self.active_turns.pop(card_id, None)

    async def _send_acp_response(self, request_id, result, source_ws, was_e2ee):
        """Send response back to the client via WebSocket."""
        response = {"jsonrpc": "2.0", "id": request_id}
        if isinstance(result, dict) and "error" in result:
            response["error"] = result["error"]
        else:
            response["result"] = result

        if was_e2ee and self.e2ee.is_ready:
            response = self.e2ee.wrap_json_rpc(response)
        
        try:
            await source_ws.send(json.dumps(response))
        except Exception as e:
            logger.debug(f"Failed to send response back to client (maybe disconnected): {e}")

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
