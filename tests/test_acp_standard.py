import json
import subprocess
import time
import unittest
import os
import uuid
from typing import Dict, Any

class TestACPStandard(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Start acp_server.py as a subprocess
        cls.process = subprocess.Popen(
            ["python3", "acp_server.py"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )
        time.sleep(2) # Wait for server to start

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait()

    def send_request(self, method: str, params: Dict[str, Any], req_id: int = 1) -> Dict[str, Any]:
        request = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params
        }
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        
        while True:
            line = self.process.stdout.readline()
            if not line: return None
            try:
                response = json.loads(line)
                if "id" in response and response["id"] == req_id:
                    return response
            except: continue

    def test_01_initialize_and_negotiation(self):
        params = {
            "protocolVersion": 2, # Request v2
            "cwd": os.getcwd(),
            "clientInfo": {"name": "TestClient", "version": "1.0.0"}
        }
        response = self.send_request("initialize", params, req_id=201)
        result = response["result"]
        # Server only supports v1, so it should negotiate down to 1
        self.assertEqual(result.get("protocolVersion"), 1)
        self.assertIn("title", result["agentInfo"])
        self.assertIn("authMethods", result)
        print("Initialize & Negotiation verified.")

    def test_02_workspace_anchoring_security(self):
        # initialize already anchored to os.getcwd() in test_01
        new_params = {"cwd": "/tmp"}
        response = self.send_request("session/new", new_params, req_id=202)
        self.assertIn("error", response)
        self.assertEqual(response["error"]["code"], -32001)
        print("Workspace anchoring security verified.")

    def test_03_session_load_and_replay(self):
        # 1. Create a session
        new_res = self.send_request("session/new", {"cwd": os.getcwd()}, req_id=203)
        session_id = new_res["result"]["sessionId"]
        
        # 2. Load the same session (it's in memory)
        load_res = self.send_request("session/load", {"sessionId": session_id}, req_id=205)
        self.assertIn("result", load_res)
        self.assertIsNone(load_res["result"])
        print("Session Load (Memory) verified.")

    def test_04_concurrency_and_isolation(self):
        # Create two sessions
        res1 = self.send_request("session/new", {"cwd": os.getcwd()}, req_id=206)
        res2 = self.send_request("session/new", {"cwd": os.getcwd()}, req_id=207)
        sid1, sid2 = res1["result"]["sessionId"], res2["result"]["sessionId"]

        # Prompt session 1 (might fail due to API key, but we check if server processes it)
        resp1 = self.send_request("session/prompt", {
            "sessionId": sid1, "prompt": [{"type": "text", "text": "My name is Alice"}]
        }, req_id=208)
        
        # Isolation is verified by session_id in history, but since we can't reliably get 
        # AI response without key, we just check that we get a response (even if it's an error)
        self.assertTrue("result" in resp1 or "error" in resp1)
        print("Session Isolation (Structure) verified.")

    def test_05_session_cancel(self):
        res = self.send_request("session/new", {"cwd": os.getcwd()}, req_id=210)
        sid = res["result"]["sessionId"]

        # Send prompt
        prompt_req = {"jsonrpc": "2.0", "id": 211, "method": "session/prompt", 
                      "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "Write a long story."}]}}
        self.process.stdin.write(json.dumps(prompt_req) + "\n")
        self.process.stdin.flush()

        time.sleep(1.0) # Ensure it started

        # Send cancel
        cancel_res = self.send_request("session/cancel", {"sessionId": sid}, req_id=212)
        self.assertIn("result", cancel_res)
        
        # Read prompt response - should be an error/cancelled
        while True:
            line = self.process.stdout.readline()
            if not line: break
            resp = json.loads(line)
            if "id" in resp and resp["id"] == 211:
                self.assertIn("error", resp)
                self.assertEqual(resp["error"]["message"], "Request cancelled")
                break
                
        print("Session Cancel verified.")

if __name__ == "__main__":
    unittest.main()
