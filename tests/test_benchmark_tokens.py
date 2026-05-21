import sys
import os
from pathlib import Path

# Add root
sys.path.append(str(Path(__file__).parent.parent))

from src.utils.tokens import estimate_tokens
from src.persistence.database import KanbanDB
from src.logic.context import ContextBuilder

def benchmark():
    # Setup dummy context
    project_name = "acpKanban Project"
    workspace_path = os.getcwd()
    
    # 1. OLD MODE: Full Code Injection (Simulation)
    # Assume 10 files, each 300 lines (~1500 tokens each)
    # We traditionally injected a lot of boilerplate or project overview
    old_context = f"# Project: {project_name}\nPath: {workspace_path}\n"
    old_context += "Full Code Structure:\n" + ("X" * 12000) # Simulating ~3000 tokens of code
    
    old_tokens = estimate_tokens(old_context)
    print(f"--- BENCHMARK RESULTS ---")
    print(f"[OLD MODE] Est. Tokens: {old_tokens}")

    # 2. NEW MODE: Slim Context (Real)
    db = KanbanDB(db_path=":memory:")
    db.init_db()
    
    project_id = db.projects.create(project_name, workspace_path=workspace_path)
    col_id = db.columns.create(project_id, "Todo")
    card_id = db.cards.create(col_id, "Fix login", description="Update auth logic")
    
    builder = ContextBuilder(db)
    
    import asyncio
    new_context = asyncio.run(builder.build_initial_context(card_id))
    new_tokens = estimate_tokens(new_context)
    
    print(f"[NEW MODE] Est. Tokens: {new_tokens}")
    
    saving = (1 - (new_tokens / old_tokens)) * 100
    print(f"[SUMMARY] Token Saving: {saving:.1f}%")
    print(f"-------------------------")

if __name__ == "__main__":
    benchmark()
