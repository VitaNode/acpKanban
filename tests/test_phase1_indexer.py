import asyncio
import os
import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB
from src.persistence.indexer import CodeIndexer
from src.persistence.embedding import embedding_service

async def test_indexer():
    # Use a temporary test database
    test_db_path = "test_kanban.db"
    if os.path.exists(test_db_path):
        os.remove(test_db_path)
    
    db = KanbanDB(db_path=test_db_path)
    db.init_db()
    
    # Create a dummy project
    project_id = db.projects.create("Test Project", workspace_path=os.getcwd())
    print(f"[*] Created test project: {project_id}")
    
    # 1. Test Structural Indexing
    indexer = CodeIndexer(db)
    # We index only the src/persistence folder for speed
    persistence_path = os.path.join(os.getcwd(), "src", "persistence")
    print(f"[*] Indexing path: {persistence_path}")
    
    await indexer.index_project(project_id, persistence_path)
    
    symbols = db.code_symbols.get_by_project(project_id)
    print(f"[*] Indexed {len(symbols)} symbols.")
    
    # Verify some symbols
    found_db = any(s['symbol_name'] == 'KanbanDB' for s in symbols)
    found_indexer = any(s['symbol_name'] == 'CodeIndexer' for s in symbols)
    
    assert found_db, "KanbanDB class not found in index"
    assert found_indexer, "CodeIndexer class not found in index"
    print("[✓] Structural Indexing Verified")

    # 2. Test Embedding Service Integration (Mocking embedding if no API key)
    if not embedding_service.is_available():
        print("[!] Embedding service not available (no API key). Skipping vectorization test.")
    else:
        print("[*] Starting vectorization...")
        await embedding_service.index_codebase(project_id, persistence_path)
        symbols_with_embed = db.code_symbols.get_by_project(project_id)
        has_embed = any(s.get('embedding') is not None for s in symbols_with_embed)
        print(f"[✓] Vectorization completed. Has embeddings: {has_embed}")

    # Cleanup
    db.close()
    if os.path.exists(test_db_path):
        os.remove(test_db_path)
    print("[✓] All Phase 1 Tests Passed")

if __name__ == "__main__":
    asyncio.run(test_indexer())
