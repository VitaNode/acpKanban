import asyncio
import websockets
import json

async def test_connect():
    uri = "ws://127.0.0.1:8766"
    try:
        async with websockets.connect(uri) as websocket:
            print("Successfully connected to bridge")
            # Send a simple ping or invalid request to see if it responds
            await websocket.send(json.dumps({"jsonrpc": "2.0", "method": "ping", "id": 1}))
            response = await asyncio.wait_for(websocket.recv(), timeout=5.0)
            print(f"Received response: {response}")
    except Exception as e:
        print(f"Failed to connect: {e}")

if __name__ == "__main__":
    asyncio.run(test_connect())
