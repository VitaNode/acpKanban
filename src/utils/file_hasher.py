import hashlib
import logging

logger = logging.getLogger("FileHasher")

def compute_file_hash(file_path: str, chunk_size: int = 8192) -> str:
    """
    Computes SHA256 hash of a file in chunks to avoid memory issues with large files.
    """
    sha256 = hashlib.sha256()
    try:
        with open(file_path, 'rb') as f:
            while chunk := f.read(chunk_size):
                sha256.update(chunk)
        return sha256.hexdigest()
    except Exception as e:
        logger.warning(f"Failed to hash {file_path}: {e}")
        return None
