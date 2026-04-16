import asyncio
import os
import sys
import json
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB
from src.protocol.mcp_code import MCPCodeServer

async def test_mcp_boundaries():
    db = KanbanDB(db_path=":memory:")
    db.init_db()
    server = MCPCodeServer()
    server.db = db
    
    # 1. Test missing project
    resp = await server.call_tool("get_project_outline", {"project_id": "non_existent"})
    assert resp["content"][0]["text"] == "{}"
    print("[✓] Non-existent project handled")

    # 2. Test missing symbol
    resp = await server.call_tool("get_symbol_code", {"project_id": "p1", "symbol_name": "Ghost"})
    assert "Error" in resp["content"][0]["text"]
    assert resp.get("isError") == True
    print("[✓] Missing symbol handled")

    # 3. Test invalid tool
    resp = await server.call_tool("bad_tool", {})
    assert "Unknown tool" in resp["content"][0]["text"]
    print("[✓] Invalid tool handled")

if __name__ == "__main__":
    asyncio.run(test_mcp_boundaries())
