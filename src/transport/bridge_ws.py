import asyncio
import websockets
import subprocess
import json
import sys
import os
from datetime import datetime
from src.logger import setup_logger

logger = setup_logger("BridgeWS")

# Path to the actual ACP server
ACP_SERVER_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "api")
PYTHON_EXE = sys.executable

async def handler(websocket):
    client_addr = websocket.remote_address
    logger.info(f"New Client Connected: {client_addr}")
    
    process = None
    try:
        # Issue 3: Subprocess start error handling
        process = await asyncio.create_subprocess_exec(
            PYTHON_EXE, ACP_SERVER_PATH,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        logger.info(f"ACP Server started for {client_addr} (PID: {process.pid})")
    except Exception as e:
        logger.error(f"Failed to start ACP Server: {e}")
        await websocket.close(1011, "Server initialization failed")
        return

    async def forward_to_server():
        try:
            async for message in websocket:
                if process.returncode is None:
                    process.stdin.write(message.encode() + b"\n")
                    await process.stdin.drain()
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Client {client_addr} connection closed.")
        except Exception as e:
            logger.error(f"forward_to_server: {e}")
        finally:
            # Issue 1: Resource cleanup
            if process and process.returncode is None:
                logger.info(f"Terminating ACP Server (PID: {process.pid})")
                process.terminate()
                await process.wait()

    async def forward_to_client():
        try:
            while True:
                line = await process.stdout.readline()
                if not line: break
                await websocket.send(line.decode().strip())
        except Exception as e:
            logger.error(f"forward_to_client: {e}")

    async def log_stderr():
        try:
            while True:
                line = await process.stderr.readline()
                if not line: break
                logger.warning(f"[SERVER LOG {process.pid}]: {line.decode().strip()}")
        except Exception:
            pass

    # Issue 1 & 4: Resource cleanup and gathering
    try:
        await asyncio.gather(
            forward_to_server(),
            forward_to_client(),
            log_stderr()
        )
    finally:
        if process and process.returncode is None:
            process.terminate()
            await process.wait()

async def main():
    # Issue 2: Heartbeat detection (ping_interval)
    async with websockets.serve(
        handler, 
        "0.0.0.0", 
        8766,
        ping_interval=30,
        ping_timeout=10
    ):
        logger.info("ACP WebSocket Bridge (Robust) started on ws://localhost:8766")
        await asyncio.Future()  # run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
