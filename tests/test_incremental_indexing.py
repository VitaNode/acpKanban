import os
import pytest
import asyncio
from src.persistence.database import KanbanDB
from src.persistence.indexer import CodeIndexer

@pytest.mark.anyio
async def test_incremental_indexing(tmp_path):
    db_path = str(tmp_path / "test_incr.db")
    db = KanbanDB(db_path)
    db.init_db()
    
    # Create a test project
    pid = db.projects.create("Test Project", str(tmp_path))
    
    indexer = CodeIndexer(db)
    
    # 1. First indexing (Empty)
    await indexer.index_project(pid, str(tmp_path))
    assert db.get_project_file_count(pid) == 0
    
    # 2. Add a file
    file1 = tmp_path / "main.py"
    file1.write_text("def hello(): pass")
    
    await indexer.index_project(pid, str(tmp_path))
    assert db.get_project_file_count(pid) == 1
    assert db.get_project_symbol_count(pid) == 1
    
    # 3. Modify the file (Incremental)
    file1.write_text("def hello(): pass\ndef world(): pass")
    await indexer.index_project(pid, str(tmp_path))
    assert db.get_project_file_count(pid) == 1
    assert db.get_project_symbol_count(pid) == 2 # hello and world
    
    # 4. Add another file
    file2 = tmp_path / "utils.py"
    file2.write_text("class Utils: pass")
    await indexer.index_project(pid, str(tmp_path))
    assert db.get_project_file_count(pid) == 2
    assert db.get_project_symbol_count(pid) == 3 # hello, world, Utils
    
    # 5. Delete a file
    os.remove(file1)
    await indexer.index_project(pid, str(tmp_path))
    assert db.get_project_file_count(pid) == 1 # Only utils.py remains
    assert db.get_project_symbol_count(pid) == 1 # Only Utils remains
    
    # 6. Check Project Stats
    proj = db.projects.get_by_id(pid)
    assert proj['total_files'] == 1
    assert proj['total_symbols'] == 1
