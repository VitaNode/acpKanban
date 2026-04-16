import asyncio
import os
import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).parent.parent))

from src.persistence.database import KanbanDB
from src.persistence.indexer import CodeIndexer

async def test_indexer_accuracy():
    db = KanbanDB(db_path=":memory:")
    db.init_db()
    indexer = CodeIndexer(db)
    project_id = "test_acc"

    # 1. Test Python Nesting & Decorators
    py_code = """
@decorator
class Outer:
    def method(self):
        class Inner:
            pass
"""
    with open("tmp_test.py", "w") as f: f.write(py_code)
    await indexer.index_file(project_id, os.path.abspath("tmp_test.py"), "tmp_test.py")
    
    symbols = db.code_symbols.get_by_project(project_id)
    names = [s['symbol_name'] for s in symbols]
    print(f"[*] Found Python symbols: {names}")
    assert "Outer" in names
    # Note: Depending on walker implementation, name might be 'method' or 'Outer.method'
    assert any("method" in n for n in names)
    
    # 2. Test Dart Parsing
    dart_code = "class MyWidget { void build() {} }"
    with open("tmp_test.dart", "w") as f: f.write(dart_code)
    await indexer.index_file(project_id, os.path.abspath("tmp_test.dart"), "tmp_test.dart")
    
    symbols = db.code_symbols.get_by_project(project_id)
    names = [s['symbol_name'] for s in symbols]
    print(f"[*] Found Dart symbols: {names}")
    assert any("MyWidget" in n for n in names)

    # 3. Test Empty File
    with open("empty.py", "w") as f: f.write("")
    await indexer.index_file(project_id, os.path.abspath("empty.py"), "empty.py")
    # Should not crash

    # Cleanup
    for f in ["tmp_test.py", "tmp_test.dart", "empty.py"]:
        if os.path.exists(f): os.remove(f)
    print("[✓] Indexer Accuracy Test Passed")

if __name__ == "__main__":
    asyncio.run(test_indexer_accuracy())
