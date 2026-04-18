import os
import pytest
from src.persistence.database import KanbanDB
from src.utils.file_hasher import compute_file_hash

def test_db_migration():
    db_path = "test_indexing.db"
    if os.path.exists(db_path):
        os.remove(db_path)
    
    db = KanbanDB(db_path)
    db.init_db()
    
    with db.get_connection() as conn:
        # Check if file_index table exists
        cursor = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='file_index'")
        assert cursor.fetchone() is not None
        
        # Check if new columns exist in projects
        cursor = conn.execute("PRAGMA table_info(projects)")
        columns = [row[1] for row in cursor.fetchall()]
        assert "index_status" in columns
        assert "last_indexed_at" in columns
        assert "total_files" in columns
        assert "total_symbols" in columns
        assert "index_checkpoint" in columns

    # Cleanup
    if os.path.exists(db_path):
        os.remove(db_path)

def test_file_hasher(tmp_path):
    test_file = tmp_path / "test.txt"
    content = b"Hello MyBot Indexing!"
    test_file.write_bytes(content)
    
    hash1 = compute_file_hash(str(test_file))
    assert hash1 is not None
    assert len(hash1) == 64
    
    # Same content should have same hash
    hash2 = compute_file_hash(str(test_file))
    assert hash1 == hash2
    
    # Different content should have different hash
    test_file.write_bytes(b"Something else")
    hash3 = compute_file_hash(str(test_file))
    assert hash1 != hash3

def test_file_hasher_large_file(tmp_path):
    # Create a 1MB file
    test_file = tmp_path / "large.bin"
    with open(test_file, "wb") as f:
        f.write(os.urandom(1024 * 1024))
    
    hash_val = compute_file_hash(str(test_file))
    assert hash_val is not None
    assert len(hash_val) == 64
