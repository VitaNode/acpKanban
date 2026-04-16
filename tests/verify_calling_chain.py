import asyncio
import os
import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB
from src.persistence.embedding import embedding_service

async def verify_chain():
    test_db_path = "verify_chain.db"
    if os.path.exists(test_db_path):
        os.remove(test_db_path)
    
    db = KanbanDB(db_path=test_db_path)
    db.init_db()
    
    # 1. Simulate Project Creation (The trigger we just added in api/projects.py logic)
    print("[*] Simulating project creation...")
    project_id = db.projects.create("Chain Verification", workspace_path=os.getcwd())
    
    # In production, FastAPI BackgroundTasks would call this. We call it here to verify.
    # But wait, let's verify if the indexer actually populates the symbols.
    await embedding_service.index_codebase(project_id, os.path.join(os.getcwd(), "src", "logic"))
    
    symbols = db.code_symbols.get_by_project(project_id)
    print(f"[*] Symbols in DB: {len(symbols)}")
    
    assert len(symbols) > 0, "Calling chain failed: No symbols indexed!"
    
    # 2. Verify ContextBuilder can now see these symbols
    from src.logic.context import ContextBuilder
    card_id = db.cards.create(db.get_columns(project_id)[0]['id'], "Fix context logic")
    
    builder = ContextBuilder(db)
    context = await builder.build_initial_context(card_id)
    
    print("[*] Verifying Recommended Files in context...")
    # 'context' keyword from 'Fix context logic' should match 'src/logic/context.py'
    assert "src/logic/context.py" in context or "context.py" in context, "Context recommendation failed!"
    
    print("[✓] Calling chain verified: Indexer -> DB -> ContextBuilder")

    # Cleanup
    db.close()
    if os.path.exists(test_db_path):
        os.remove(test_db_path)

if __name__ == "__main__":
    asyncio.run(verify_chain())
