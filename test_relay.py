import asyncio
import websockets
import json
import subprocess
import time
import os

async def test_relay_path2():
    print("[*] Testing Path 2: Relay Mode")
    uri_mac = "ws://localhost:8766/relay/mac/test_user"
    uri_app = "ws://localhost:8766/relay/app/test_user"

    async with websockets.connect(uri_mac) as ws_mac, \
               websockets.connect(uri_app) as ws_app:
        
        print("[*] Connected both MAC and APP")

        # Test APP -> MAC
        test_msg_app = json.dumps({"jsonrpc": "2.0", "method": "test_from_app", "id": 1})
        await ws_app.send(test_msg_app)
        print("[*] Sent message from APP")
        
        recv_mac = await asyncio.wait_for(ws_mac.recv(), timeout=2.0)
        print(f"[*] MAC received: {recv_mac}")
        assert recv_mac == test_msg_app

        # Test MAC -> APP
        test_msg_mac = json.dumps({"jsonrpc": "2.0", "result": "ok_from_mac", "id": 1})
        await ws_mac.send(test_msg_mac)
        print("[*] Sent message from MAC")

        recv_app = await asyncio.wait_for(ws_app.recv(), timeout=2.0)
        print(f"[*] APP received: {recv_app}")
        assert recv_app == test_msg_mac

    print("[+] Path 2 Test Passed!")

async def test_relay_path3():
    print("[*] Testing Path 3: Direct Mode")
    uri_direct = "ws://localhost:8766/direct"
    
    async with websockets.connect(uri_direct) as ws:
        # Send initialize
        init_req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        await ws.send(init_req)
        
        resp = await asyncio.wait_for(ws.recv(), timeout=5.0)
        data = json.loads(resp)
        print(f"[*] Path 3 Response: {data}")
        assert "result" in data
        assert "capabilities" in data["result"]

    print("[+] Path 3 Test Passed!")

import sys

async def run_tests():
    # Start server in background
    server_process = subprocess.Popen([sys.executable, "relay_server.py"], env=os.environ)
    time.sleep(2) # Wait for server to start

    try:
        await test_relay_path2()
        await test_relay_path3()
    finally:
        server_process.terminate()
        server_process.wait()

if __name__ == "__main__":
    asyncio.run(run_tests())
