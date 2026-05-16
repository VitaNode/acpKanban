import asyncio
import json
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from src.protocol.client import ACPClient
import pytest

@pytest.mark.asyncio
@pytest.mark.parametrize("name, command", [
    ("Gemini CLI", ["gemini", "--acp"]),
    ("Qwen Code", ["qwen", "--acp"]),
    ("OpenClaw", ["openclaw", "acp"]),
    ("OpenCode", ["opencode", "acp"]),
])
async def test_acp_capabilities(name, command):
    test_cwd = os.getcwd()
    print(f"\n{'='*60}")
    print(f"Testing {name}: {' '.join(command)}")
    print('='*60)
    
    client = ACPClient(command=command, cwd=test_cwd, name=name)
    session_id = None
    
    try:
        # Check if command exists first to avoid hang
        import shutil
        if not shutil.which(command[0]):
            pytest.skip(f"Command {command[0]} not found")

        await client.start()
        await asyncio.sleep(2)  # Wait for process to stabilize
        
        # 1. Initialize
        print("\n[1] Testing initialize...")
        init_response = await client.request("initialize", {
            "protocolVersion": 1,
            "clientInfo": {"name": "TestClient", "version": "1.0.0"}
        })
        
        result = init_response.get("result", {})
        agent_caps = result.get("agentCapabilities", {})
        session_caps = agent_caps.get("sessionCapabilities", {})
        load_session = agent_caps.get("loadSession", False)
        
        print(f"  sessionCapabilities.list: {session_caps.get('list', 'NOT SUPPORTED')}")
        print(f"  loadSession: {load_session}")
        
        # 2. Test session/new
        print("\n[2] Testing session/new...")
        new_session = await client.request("session/new", {
            "cwd": cwd or "/tmp",
            "mcpServers": [],
            "_meta": {"sessionKey": f"test:{name}"}
        })
        
        session_id = new_session.get("result", {}).get("sessionId")
        print(f"  sessionId: {session_id}")
        
        # 3. Test session/list (if supported)
        if session_caps.get("list") is not None:
            print("\n[3] Testing session/list...")
            list_response = await client.request("session/list", {"cwd": cwd or "/tmp"})
            sessions = list_response.get("result", {}).get("sessions", [])
            print(f"  Found {len(sessions)} sessions")
            for s in sessions[:3]:  # Show first 3
                print(f"    - {s.get('sessionId')}: {s.get('title', 'N/A')}")
        else:
            print("\n[3] session/list NOT SUPPORTED")
        
        # 4. Test session/load (if supported)
        if load_session and session_id:
            print("\n[4] Testing session/load...")
            load_response = await client.request("session/load", {
                "sessionId": session_id,
                "cwd": cwd or "/tmp",
                "mcpServers": []
            })
            print(f"  Result: {load_response.get('result')}")
        else:
            print("\n[4] session/load NOT SUPPORTED")
        
        return {
            "name": name,
            "session_list": session_caps.get("list") is not None,
            "load_session": load_session,
            "session_id": session_id
        }
        
    except Exception as e:
        print(f"\nERROR: {e}")
        return {"name": name, "error": str(e)}
    finally:
        await client.stop()