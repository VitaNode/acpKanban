import asyncio
import os
import sys
import json
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB
from src.protocol.mcp_code import MCPCodeServer
from src.persistence.indexer import CodeIndexer

async def test_tools():
    # 1. Setup DB and index some data
    test_db_path = "test_phase2.db"
    if os.path.exists(test_db_path):
        os.remove(test_db_path)
    
    db = KanbanDB(db_path=test_db_path)
    db.init_db()
    
    project_id = db.projects.create("Test Project", workspace_path=os.getcwd())
    indexer = CodeIndexer(db)
    # Index a small subset
    test_file = os.path.join(os.getcwd(), "src", "persistence", "database.py")
    await indexer.index_file(project_id, test_file, "src/persistence/database.py")
    
    # 2. Test MCP Server logic
    server = MCPCodeServer()
    # Mocking DB instance for server to use our test DB
    server.db = db
    
    print("[*] Testing list_tools...")
    tools = server.list_tools()
    assert len(tools) >= 3
    print(f"[✓] Tools found: {[t['name'] for t in tools]}")
    
    print("[*] Testing get_project_outline...")
    resp = await server.call_tool("get_project_outline", {"project_id": project_id})
    outline = json.loads(resp["content"][0]["text"])
    assert "src/persistence/database.py" in outline
    print(f"[✓] Outline verified, found {len(outline['src/persistence/database.py'])} symbols in database.py")
    
    print("[*] Testing get_symbol_code...")
    resp = await server.call_tool("get_symbol_code", {"project_id": project_id, "symbol_name": "KanbanDB"})
    code_content = resp["content"][0]["text"]
    assert "class KanbanDB" in code_content
    print("[✓] Symbol code retrieval verified")
    
    print("[*] Testing search_code (keyword fallback)...")
    resp = await server.call_tool("search_code", {"project_id": project_id, "query": "Repository"})
    search_results = resp["content"][0]["text"]
    assert "Repository" in search_results
    print("[✓] Search verified")

    # Cleanup
    db.close()
    if os.path.exists(test_db_path):
        os.remove(test_db_path)
    print("[✓] All Phase 2 Tests Passed")

if __name__ == "__main__":
    asyncio.run(test_tools())
