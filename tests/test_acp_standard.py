import json
import subprocess
import time
import unittest
import os
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
        
        # Read until we get a response with matching id
        while True:
            line = self.process.stdout.readline()
            if not line:
                return None
            response = json.loads(line)
            if "id" in response and response["id"] == req_id:
                return response
            # Log notifications for debugging
            if "method" in response:
                print(f"DEBUG Notification: {response['method']} - {response.get('params')}")

    def test_01_initialize(self):
        params = {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {}, "terminal": {}},
            "clientInfo": {"name": "TestClient", "version": "1.0.0"}
        }
        response = self.send_request("initialize", params, req_id=101)
        self.assertIn("result", response)
        result = response["result"]
        self.assertEqual(result.get("protocolVersion"), 1)
        self.assertIn("agentCapabilities", result)
        self.assertIn("tools", result["agentCapabilities"])
        print("Initialize verified.")

    def test_02_session_lifecycle(self):
        # 1. New Session
        new_params = {
            "cwd": os.getcwd(),
            "_meta": {"sessionKey": "agent:main:kanban:test_card_123"}
        }
        response = self.send_request("session/new", new_params, req_id=102)
        self.assertIn("result", response)
        session_id = response["result"].get("sessionId")
        self.assertIsNotNone(session_id)
        print(f"Session New verified: {session_id}")

        # 2. Prompt
        prompt_params = {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": "Hello, who are you?"}]
        }
        response = self.send_request("session/prompt", prompt_params, req_id=103)
        self.assertIn("result", response)
        self.assertIn("text", response["result"])
        print(f"Session Prompt verified: {response['result']['text'][:50]}...")

        # 3. List Sessions
        response = self.send_request("session/list", {}, req_id=104)
        self.assertIn("result", response)
        sessions = response["result"].get("sessions", [])
        self.assertTrue(any(s["sessionId"] == session_id for s in sessions))
        print("Session List verified.")

if __name__ == "__main__":
    unittest.main()
