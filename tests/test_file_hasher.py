import os
import pytest
from src.utils.file_hasher import compute_file_hash

def test_hasher_basic(tmp_path):
    f = tmp_path / "test.txt"
    f.write_text("hello world")
    h1 = compute_file_hash(str(f))
    assert h1 is not None
    
    h2 = compute_file_hash(str(f))
    assert h1 == h2

def test_hasher_empty_file(tmp_path):
    f = tmp_path / "empty.txt"
    f.touch()
    h = compute_file_hash(str(f))
    assert h is not None
    # SHA256 of empty string
    assert h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

def test_hasher_missing_file():
    h = compute_file_hash("/non/existent/path")
    assert h is None

def test_hasher_large_file(tmp_path):
    # 10MB file
    f = tmp_path / "large.bin"
    content = os.urandom(10 * 1024 * 1024)
    f.write_bytes(content)
    h = compute_file_hash(str(f))
    assert h is not None
    assert len(h) == 64

def test_hasher_permission_denied(tmp_path):
    f = tmp_path / "no_access.txt"
    f.write_text("secret")
    os.chmod(f, 0o000)
    try:
        h = compute_file_hash(str(f))
        assert h is None
    finally:
        os.chmod(f, 0o644) # restore for cleanup
