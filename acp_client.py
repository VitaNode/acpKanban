import asyncio
import json
import logging
import uuid
from typing import AsyncGenerator, Dict, Any, Optional, Union

class ACPClient:
    def __init__(self, command: list, cwd: str = None, name: str = "ACP"):
        self.command = command
        self.cwd = cwd
        self.name = name
        self.process: Optional[asyncio.subprocess.Process] = None
        self.pending_requests: Dict[Union[str, int], asyncio.Future] = {}
        self.notification_queues: Dict[str, asyncio.Queue] = {}
        self.message_handlers = [] # New: list of callbacks for all messages
        self.logger = logging.getLogger(f"ACPClient[{name}]")
        self._running = False

    def add_handler(self, handler):
        """Add a callback for all incoming messages."""
        self.message_handlers.append(handler)

    async def start(self):
        self.logger.info(f"Starting CLI: {' '.join(self.command)}")
        self.process = await asyncio.create_subprocess_exec(
            *self.command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self.cwd
        )
        self._running = True
        asyncio.create_task(self._read_stdout())
        asyncio.create_task(self._read_stderr())
        asyncio.create_task(self._cleanup_pending_requests())

    async def _cleanup_pending_requests(self):
        """Periodically clean up stale futures."""
        while self._running:
            await asyncio.sleep(60)
            # This is a basic cleanup. In a real system, we'd check timestamps.
            # Here we just check if the future is done.
            stale_ids = [k for k, v in self.pending_requests.items() if v.done()]
            for k in stale_ids:
                del self.pending_requests[k]

    async def _read_stdout(self):
        while self._running and self.process and not self.process.stdout.at_eof():
            try:
                line = await self.process.stdout.readline()
                if not line:
                    break
                
                # Some CLIs might print non-JSON noise before or after JSON-RPC
                line_str = line.decode().strip()
                if not line_str:
                    continue
                
                if not (line_str.startswith("{") or line_str.startswith("[")):
                    self.logger.debug(f"Non-JSON stdout: {line_str}")
                    continue

                data = json.loads(line_str)
                await self._handle_message(data)
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.logger.error(f"Error reading stdout: {e}")

    async def _read_stderr(self):
        while self._running and self.process and not self.process.stderr.at_eof():
            try:
                line = await self.process.stderr.readline()
                if line:
                    self.logger.debug(f"CLI Stderr: {line.decode().strip()}")
            except asyncio.CancelledError:
                break
            except Exception as e:
                self.logger.error(f"Error reading stderr: {e}")

    async def _handle_message(self, data: Dict[str, Any]):
        self.logger.debug(f"RECV: {data}")
        
        # Call all raw message handlers
        for handler in self.message_handlers:
            try:
                if asyncio.iscoroutinefunction(handler):
                    await handler(data)
                else:
                    handler(data)
            except Exception as e:
                self.logger.error(f"Error in message handler: {e}")

        msg_id = data.get("id")
        method = data.get("method")
        
        # JSON-RPC 2.0 Logic:
        # 1. Has 'id' but NO 'method' -> It's a Response to our request
        # 2. Has 'id' AND 'method' -> It's a Request from the server
        # 3. Has NO 'id' AND 'method' -> It's a Notification
        
        if msg_id is not None and method is None:
            # This is a response to a client request
            future = self.pending_requests.pop(msg_id, None)
            if future:
                future.set_result(data)
        elif method:
            # This is either a notification or a server-initiated request
            # We put both in notification queues for now
            for queue in self.notification_queues.values():
                await queue.put(data)
            
            # If it has an ID, it's a request we might need to respond to (like approval/request)
            # (Handling of server-initiated requests would go here)
        else:
            self.logger.warning(f"Unrecognized message: {data}")

    async def respond(self, request_id: Union[str, int], result: Any = None, error: Any = None):
        """Respond to a server-initiated request."""
        if not self.process or self.process.returncode is not None:
            raise RuntimeError("ACP Process is not running")

        response_obj = {
            "jsonrpc": "2.0",
            "id": request_id
        }
        if error:
            response_obj["error"] = error
        else:
            response_obj["result"] = result or {}
        
        self.logger.debug(f"SEND RESP: {response_obj}")
        self.process.stdin.write((json.dumps(response_obj) + "\n").encode())
        await self.process.stdin.drain()

    async def request(self, method: str, params: Dict[str, Any] = None) -> Dict[str, Any]:
        if not self.process or self.process.returncode is not None:
            raise RuntimeError("ACP Process is not running")

        msg_id = str(uuid.uuid4())
        request_obj = {
            "jsonrpc": "2.0",
            "id": msg_id,
            "method": method,
            "params": params or {}
        }
        
        future = asyncio.get_running_loop().create_future()
        self.pending_requests[msg_id] = future
        
        self.logger.debug(f"SEND: {request_obj}")
        self.process.stdin.write((json.dumps(request_obj) + "\n").encode())
        await self.process.stdin.drain()
        
        return await future

    def listen(self, listener_id: str = None) -> asyncio.Queue:
        """Create a new queue to listen for notifications."""
        l_id = listener_id or str(uuid.uuid4())
        queue = asyncio.Queue()
        self.notification_queues[l_id] = queue
        return queue

    def stop_listening(self, listener_id: str):
        if listener_id in self.notification_queues:
            del self.notification_queues[listener_id]

    async def stop(self):
        self._running = False
        if self.process:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                self.process.kill()
            self.process = None
