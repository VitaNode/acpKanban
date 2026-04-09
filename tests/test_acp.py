import subprocess
import json
import sqlite3
import sys
import os

def test_acp_kanban():
    python_exe = sys.executable
    
    process = subprocess.Popen(
        [python_exe, 'acp_server.py'],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    def send_request(request):
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        return json.loads(line) if line else None

    print("--- Phase 2: Kanban Logic Test ---")
    
    # Initialize
    send_request({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"clientInfo": {"name": "TestClient", "version": "1.0"}}
    })

    # Task Creation Command
    print("Commanding Gemini to create a task...")
    chat_req = {
        "jsonrpc": "2.0", "id": 2, "method": "chat/message",
        "params": {"message": "帮我创建一个新任务，标题是‘实现移动端看板 UI’，描述是‘使用 Flutter 开发’"}
    }
    chat_res = send_request(chat_req)
    if chat_res and 'result' in chat_res:
        print(f"Chat Response: {chat_res['result']['message']}")
    else:
        print(f"Chat Error/Invalid Response: {chat_res}")

    # Verification in Database
    conn = sqlite3.connect("kanban.db")
    cursor = conn.execute("SELECT * FROM tasks")
    tasks = cursor.fetchall()
    print(f"\nDatabase Tasks: {tasks}")
    
    cursor = conn.execute("SELECT * FROM timeline")
    timeline = cursor.fetchall()
    print(f"Database Timeline: {timeline}")
    
    conn.close()

    # Clean up
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}) + "\n")
    process.stdin.flush()
    process.terminate()

if __name__ == "__main__":
    test_acp_kanban()
