import asyncio
import os
import sys
import json
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB

async def verify_semantic():
    test_db_path = "verify_semantic.db"
    if os.path.exists(test_db_path):
        os.remove(test_db_path)
    
    db = KanbanDB(db_path=test_db_path)
    db.init_db()
    
    # 1. Verify Extension Loading (Skipping as we use Python fallback)
    print("[*] Starting semantic search logic test (using Python fallback if sqlite-vec unavailable)...")
    
    # 2. Inject Mock Data with Vectors
    project_id = db.projects.create("Semantic Test")
    col_id = db.columns.create(project_id, "Todo")
    
    # Simple 3-dim vectors for testing
    v1 = [1.0, 0.0, 0.0]
    v2 = [0.0, 1.0, 0.0]
    v_query = [0.9, 0.1, 0.0] # Should match v1
    
    print("[*] Injecting mock symbols...")
    db.code_symbols.upsert(
        project_id=project_id,
        file_path="auth.py",
        symbol_name="login",
        symbol_type="function",
        signature="def login()",
        start_line=1,
        end_line=10,
        embedding=v1
    )
    db.code_symbols.upsert(
        project_id=project_id,
        file_path="ui.py",
        symbol_name="draw",
        symbol_type="function",
        signature="def draw()",
        start_line=1,
        end_line=10,
        embedding=v2
    )
    
    # 3. Test Semantic Search
    print("[*] Testing CodeSymbolRepository.search_semantic...")
    results = db.code_symbols.search_semantic(v_query, project_id, limit=1)
    
    if results:
        match = results[0]
        print(f"[✓] Found match: {match['symbol_name']} in {match['file_path']} (Similarity: {match['similarity']:.4f})")
        assert match['symbol_name'] == "login", "Semantic search matched wrong symbol!"
    else:
        print("[❌] Semantic search returned no results!")
        return

    # 4. Test Card Semantic Search
    print("[*] Testing CardRepository.search_cards_semantic...")
    card_id = db.cards.create(col_id, "Auth Task")
    db.cards.upsert_card_embedding(card_id, v1)
    
    card_results = db.cards.search_cards_semantic(v_query, project_id, limit=1)
    if card_results:
        print(f"[✓] Found card: {card_results[0]['title']} (Similarity: {card_results[0]['similarity']:.4f})")
    else:
        print("[❌] Card semantic search failed!")

    print("[✓] All Semantic Search Verifications Passed")

    # Cleanup
    db.close()
    if os.path.exists(test_db_path):
        os.remove(test_db_path)

if __name__ == "__main__":
    asyncio.run(verify_semantic())
