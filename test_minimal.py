import subprocess, json, sys, time

def test_minimal():
    p = subprocess.Popen(
        [sys.executable, 'acp_server.py'],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    
    # Check if process started
    time.sleep(1)
    if p.poll() is not None:
        print("Process died immediately!")
        print("STDERR:", p.stderr.read())
        return

    print("Sending initialize...")
    try:
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize"}) + "\n")
        p.stdin.flush()
        out = p.stdout.readline()
        print("OUT:", out)
        
        print("Sending chat message...")
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "chat/message", "params": {"message": "Hi"}}) + "\n")
        p.stdin.flush()
        out = p.stdout.readline()
        print("OUT:", out)
    except Exception as e:
        print(f"Error: {e}")
        print("STDERR:", p.stderr.read())

    p.terminate()

if __name__ == "__main__":
    test_minimal()
