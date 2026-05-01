import asyncio
import json
import sys
import os

# Add src to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from src.persistence.database import KanbanDB
from src.logic.engine import SessionEngine

async def test_config_update():
    db = KanbanDB("kanban.db")
    card_id = "test_card_config"
    
    # Ensure card exists
    with db.get_connection() as conn:
        conn.execute("INSERT INTO projects (id, name) VALUES ('p1', 'Project 1') ON CONFLICT DO NOTHING")
        conn.execute("INSERT INTO columns (id, project_id, name, position) VALUES ('c1', 'p1', 'Column 1', 1) ON CONFLICT DO NOTHING")
        conn.execute("INSERT INTO cards (id, column_id, title, position, acp_provider_id) VALUES (?, 'c1', 'Card 1', 1, 'opencode') ON CONFLICT DO NOTHING", (card_id,))
    
    from unittest.mock import AsyncMock, MagicMock
    # Mock adapter
    mock_adapter = MagicMock()
    # Mock handle_request to return empty dict (simulating successful set_mode with no data)
    mock_adapter.handle_request = AsyncMock(return_value={})
    
    engine = SessionEngine(provider_id="opencode", card_id=card_id, db=db, workspace_path=".", column_id="c1")
    engine.adapter = mock_adapter
    engine.acp_session_id = "test_session"
    
    # Initial state
    engine.current_config_options = [
        {
            "id": "mode",
            "name": "Mode",
            "category": "mode",
            "type": "select",
            "currentValue": "plan",
            "options": [{"value": "plan", "name": "Plan"}, {"value": "build", "name": "Build"}]
        }
    ]
    engine._save_config_options_to_db()
    
    print(f"Initial currentValue: {engine.current_config_options[0]['currentValue']}")
    
    # Update config
    new_options = await engine.set_config_option("mode", "build")
    
    print(f"Updated currentValue in memory: {new_options[0]['currentValue']}")
    
    # Verify in DB
    db_opts_json = db.get_card_config_options(card_id)
    db_opts = json.loads(db_opts_json)
    print(f"Updated currentValue in DB: {db_opts[0]['currentValue']}")
    
    if db_opts[0]['currentValue'] == "build":
        print("SUCCESS: Backend correctly updates config in memory and DB")
    else:
        print("FAILED: Backend did not update config in DB")

if __name__ == "__main__":
    asyncio.run(test_config_update())
