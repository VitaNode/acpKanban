import asyncio
import websockets
import json
import subprocess
import time
import os
import sys
from e2ee import E2EEManager

async def test_auth_failure():
    print("[*] Testing Auth Failure")
    uri = "ws://localhost:8766/relay/app/test_user"
    # No headers or wrong token
    try:
        async with websockets.connect(uri) as ws:
            pass
        assert False, "Should have failed due to missing auth"
    except (websockets.exceptions.InvalidStatusCode, websockets.exceptions.InvalidMessage) as e:
        print(f"[+] Caught expected auth failure: {e}")

async def test_e2ee_relay():
    print("[*] Testing E2EE Relay")
    token = "default_secret"
    headers = {"Authorization": f"Bearer {token}"}
    uri_mac = "ws://localhost:8766/relay/mac/test_user"
    uri_app = "ws://localhost:8766/relay/app/test_user"

    # 1. Initialize E2EE with a shared secret (Exactly 32 bytes / 64 hex chars)
    shared_secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    e2ee = E2EEManager(session_key_hex=shared_secret)

    async with websockets.connect(uri_mac, extra_headers=headers) as ws_mac, \
               websockets.connect(uri_app, extra_headers=headers) as ws_app:
        
        # App sends E2EE message
        raw_msg = {"jsonrpc": "2.0", "method": "secure_cmd", "id": "S1"}
        envelope = e2ee.wrap_json_rpc(raw_msg)
        await ws_app.send(envelope)
        
        # Mac receives envelope and unwraps
        recv_env = await asyncio.wait_for(ws_mac.recv(), timeout=2.0)
        unwrapped = e2ee.unwrap_json_rpc(recv_env)
        print(f"[*] MAC received and unwrapped: {unwrapped}")
        assert unwrapped["method"] == "secure_cmd"

    print("[+] E2EE Relay Test Passed!")

async def run_tests():
    # Start server
    server_proc = subprocess.Popen([sys.executable, "relay_server.py"])
    time.sleep(2)

    try:
        await test_auth_failure()
        await test_e2ee_relay()
    finally:
        server_proc.terminate()
        server_proc.wait()

if __name__ == "__main__":
    asyncio.run(run_tests())
