import json
import subprocess
import time
import unittest
import os
import sys
from typing import Dict, Any

class TestACPPermission(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Set debug flag for test endpoints
        env = os.environ.copy()
        env["KANBAN_DEBUG"] = "1"
        
        cls.process = subprocess.Popen(
            ["python3", "acp_server.py"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env
        )
        time.sleep(2)

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait()

    def test_permission_flow(self):
        # 1. Initialize
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"cwd": os.getcwd()}}) + "\n")
        self.process.stdin.flush()
        # Skip potential notifications until response 1
        while True:
            line = self.process.stdout.readline()
            data = json.loads(line)
            if data.get("id") == 1: break

        # 2. New Session
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": os.getcwd()}}) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            data = json.loads(line)
            if data.get("id") == 2:
                sid = data["result"]["sessionId"]
                break

        # 3. Trigger test/request_permission
        trigger_req = {"jsonrpc": "2.0", "id": 3, "method": "test/request_permission", "params": {"sessionId": sid}}
        self.process.stdin.write(json.dumps(trigger_req) + "\n")
        self.process.stdin.flush()

        # 4. Wait for Request from Server
        server_req = None
        while True:
            line = self.process.stdout.readline()
            if not line: break
            data = json.loads(line)
            if "method" in data and data["method"] == "session/request_permission":
                server_req = data
                break
            elif data.get("id") == 3:
                # If we get result 3 before request, something is wrong (permission bypassed)
                self.fail("Received response before permission request")

        self.assertIsNotNone(server_req)
        req_id = server_req["id"]

        # 5. Respond DENY
        deny_res = {"jsonrpc": "2.0", "id": req_id, "result": {"outcome": {"outcome": "selected", "optionId": "deny"}}}
        self.process.stdin.write(json.dumps(deny_res) + "\n")
        self.process.stdin.flush()

        # 6. Wait for final result
        while True:
            line = self.process.stdout.readline()
            data = json.loads(line)
            if data.get("id") == 3:
                self.assertIn("Permission denied", data["result"]["toolResult"])
                break

        print("Permission Flow Verified: Denied correctly.")

if __name__ == "__main__":
    unittest.main()
