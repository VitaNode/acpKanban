import asyncio
import os
import sys
import json
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB, cosine_similarity

def test_similarity_math():
    v1 = [1.0, 0.0, 0.0]
    v2 = [1.0, 0.0, 0.0]
    v3 = [0.0, 1.0, 0.0]
    
    assert cosine_similarity(v1, v2) == 1.0
    assert cosine_similarity(v1, v3) == 0.0
    print("[✓] Similarity Math Verified")

async def test_repo_semantic():
    db = KanbanDB(db_path=":memory:")
    db.init_db()
    project_id = "test_sem"
    
    # Inject mock data
    db.code_symbols.upsert(
        project_id=project_id,
        file_path="a.py",
        symbol_name="auth",
        symbol_type="function",
        signature="def auth()",
        start_line=1,
        end_line=2,
        embedding=[1.0, 0.1]
    )
    
    # Search with close vector
    results = db.code_symbols.search_semantic([0.9, 0.2], project_id, limit=1)
    assert len(results) > 0
    assert results[0]['symbol_name'] == "auth"
    print("[✓] Repo-level Semantic Search Verified")

if __name__ == "__main__":
    test_similarity_math()
    asyncio.run(test_repo_semantic())
