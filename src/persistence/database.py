import sqlite3
import uuid
import json
import asyncio
import sys
import os
import math
from datetime import datetime
from contextlib import contextmanager
from typing import Optional, List, Dict, Any
import threading
from queue import Queue, Empty

# Constants to avoid magic numbers
DEFAULT_PAGE_SIZE = 100
MAX_SESSION_HISTORY = 200
DEFAULT_POOL_SIZE = 5

try:
    import sqlite_vec
except ImportError:
    sqlite_vec = None

def cosine_similarity(v1: List[float], v2: List[float]) -> float:
    """Fallback cosine similarity in pure Python."""
    if not v1 or not v2 or len(v1) != len(v2):
        return 0.0
    dot_product = sum(a * b for a, b in zip(v1, v2))
    norm_a = math.sqrt(sum(a * a for a in v1))
    norm_b = math.sqrt(sum(b * b for b in v2))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot_product / (norm_a * norm_b)

class ConnectionPool:
    def __init__(self, create_fn, max_size=DEFAULT_POOL_SIZE):
        self._create_fn = create_fn
        self._pool = Queue(max_size)
        self._max_size = max_size
        self._current_size = 0
        self._lock = threading.Lock()

    def get(self):
        try:
            return self._pool.get(timeout=2)
        except Empty:
            with self._lock:
                if self._current_size < self._max_size:
                    conn = self._create_fn()
                    self._current_size += 1
                    return conn
            return self._pool.get()

    def put(self, conn):
        self._pool.put(conn)

class BaseRepository:
    def __init__(self, db):
        self.db = db

class ProjectRepository(BaseRepository):
    def create(self, name: str, workspace_path: str = None, description: str = None) -> str:
        project_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO projects (id, name, workspace_path, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", (project_id, name, workspace_path, description, now, now))
            return project_id

    def get_all(self) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM projects ORDER BY created_at DESC")
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, project_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

class ColumnRepository(BaseRepository):
    def create(self, project_id: str, name: str, position: int = None, color: str = "#808080", prompt_template: str = None) -> str:
        col_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        if position is None:
            with self.db.get_connection() as conn:
                cursor = conn.execute("SELECT MAX(position) FROM columns WHERE project_id = ?", (project_id,))
                max_pos = cursor.fetchone()[0]
                position = (max_pos + 1) if max_pos is not None else 0
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO columns (id, project_id, name, position, color, prompt_template, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", (col_id, project_id, name, position, color, prompt_template, now))
            return col_id

    def get_all(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM columns WHERE project_id = ? ORDER BY position", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, column_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM columns WHERE id = ?", (column_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

class CardRepository(BaseRepository):
    def create(self, column_id: str, title: str, description: str = None, parent_id: str = None) -> str:
        card_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT MAX(position) FROM cards WHERE column_id = ?", (column_id,))
            max_pos = cursor.fetchone()[0]
            position = (max_pos + 1) if max_pos is not None else 0
            conn.execute("INSERT INTO cards (id, column_id, title, description, position, parent_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (card_id, column_id, title, description, position, parent_id, now, now))
            return card_id

    def get_by_id(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT c.*, col.project_id FROM cards c JOIN columns col ON col.id = c.column_id WHERE c.id = ?", (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def upsert_card_embedding(self, card_id: str, embedding_vector: List[float]):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET embedding = ? WHERE id = ?", (json.dumps(embedding_vector), card_id))

    def search_cards_semantic(self, embedding_vector: List[float], project_id: str = None, limit: int = 5) -> List[Dict]:
        with self.db.get_connection() as conn:
            sql = "SELECT c.* FROM cards c JOIN columns col ON col.id = c.column_id WHERE c.embedding IS NOT NULL"
            params = []
            if project_id:
                sql += " AND col.project_id = ?"
                params.append(project_id)
            cursor = conn.execute(sql, params)
            all_rows = [dict(row) for row in cursor.fetchall()]
            for row in all_rows:
                row['similarity'] = cosine_similarity(embedding_vector, json.loads(row['embedding']))
            all_rows.sort(key=lambda x: x['similarity'], reverse=True)
            return all_rows[:limit]

class SummaryRepository(BaseRepository):
    def upsert(self, card_id: str, summary: str, embedding: Optional[List[float]] = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO summaries (card_id, summary, embedding, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(card_id) DO UPDATE SET summary=excluded.summary, embedding=excluded.embedding, updated_at=excluded.updated_at", (card_id, summary, json.dumps(embedding) if embedding else None, now))

    def update_card_summary(self, card_id: str, summary: str):
        return self.upsert(card_id, summary)

    def get_all_for_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT s.*, c.title FROM summaries s JOIN cards c ON c.id = s.card_id JOIN columns col ON col.id = c.column_id WHERE col.project_id = ?", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def search_semantic(self, embedding_vector: List[float], project_id: str, limit: int = 5) -> List[Dict]:
        all_summaries = self.get_all_for_project(project_id)
        results = []
        for s in all_summaries:
            if s.get('embedding'):
                s['similarity'] = cosine_similarity(embedding_vector, json.loads(s['embedding']))
                results.append(s)
        results.sort(key=lambda x: x['similarity'], reverse=True)
        return results[:limit]

class CodeSymbolRepository(BaseRepository):
    def upsert(self, project_id: str, file_path: str, symbol_name: str, symbol_type: str, signature: str, start_line: int, end_line: int, documentation: Optional[str] = None, code_content: Optional[str] = None, embedding: Optional[List[float]] = None):
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO code_symbols (project_id, file_path, symbol_name, symbol_type, signature, start_line, end_line, documentation, code_content, embedding) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(project_id, file_path, symbol_name, symbol_type) DO UPDATE SET signature=excluded.signature, start_line=excluded.start_line, end_line=excluded.end_line, documentation=excluded.documentation, code_content=excluded.code_content, embedding=excluded.embedding", (project_id, file_path, symbol_name, symbol_type, signature, start_line, end_line, documentation, code_content, json.dumps(embedding) if embedding else None))

    def get_by_project(self, project_id: str, limit: int = DEFAULT_PAGE_SIZE, offset: int = 0) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM code_symbols WHERE project_id = ? LIMIT ? OFFSET ?", (project_id, limit, offset))
            return [dict(row) for row in cursor.fetchall()]

    def delete_by_file(self, project_id: str, file_path: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM code_symbols WHERE project_id = ? AND file_path = ?", (project_id, file_path))

    def search_semantic(self, embedding_vector: List[float], project_id: str, limit: int = 10) -> List[Dict]:
        # We fetch a larger batch to do memory similarity calculation if no vec extension
        all_symbols = self.get_by_project(project_id, limit=500) 
        results = []
        for s in all_symbols:
            if s.get('embedding'):
                try:
                    s['similarity'] = cosine_similarity(embedding_vector, json.loads(s['embedding']))
                    results.append(s)
                except: continue
        results.sort(key=lambda x: x.get('similarity', 0), reverse=True)
        return results[:limit]

class SessionRepository(BaseRepository):
    def add_message(self, card_id: str, role: str, content: str, metadata: Dict = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO card_sessions (card_id, role, content, metadata, created_at) VALUES (?, ?, ?, ?, ?)", (card_id, role, content, json.dumps(metadata) if metadata else None, now))

    def get_history(self, card_id: str, limit: int = MAX_SESSION_HISTORY) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM card_sessions WHERE card_id = ? ORDER BY created_at ASC LIMIT ?", (card_id, limit))
            return [dict(row) for row in cursor.fetchall()]

class KanbanDB:
    _instance = None
    _lock = threading.Lock()

    def __new__(cls, *args, **kwargs):
        if not cls._instance:
            with cls._lock:
                if not cls._instance:
                    cls._instance = super(KanbanDB, cls).__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self, db_path: str = "kanban.db"):
        if self._initialized: return
        self.db_path = db_path
        self._pool = ConnectionPool(self._create_new_connection)
        self.projects = ProjectRepository(self)
        self.columns = ColumnRepository(self)
        self.cards = CardRepository(self)
        self.summaries = SummaryRepository(self)
        self.sessions = SessionRepository(self)
        self.code_symbols = CodeSymbolRepository(self)
        self._initialized = True

    def _create_new_connection(self):
        conn = sqlite3.connect(self.db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        return conn

    @contextmanager
    def get_connection(self):
        conn = self._pool.get()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            self._pool.put(conn)

    def init_db(self):
        with self.get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_path TEXT, description TEXT, created_at DATETIME, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS columns (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER, color TEXT, prompt_template TEXT, acp_provider_id TEXT, approval_mode TEXT, created_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, column_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, position INTEGER, status TEXT DEFAULT 'active', completed_at DATETIME, parent_id TEXT, last_summary TEXT, embedding TEXT, created_at DATETIME, updated_at DATETIME, acp_session_id TEXT, acp_provider_id TEXT, config_options TEXT)")
            cursor.execute("CREATE TABLE IF NOT EXISTS card_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, role TEXT, content TEXT, metadata TEXT, created_at DATETIME, is_complete INTEGER DEFAULT 1)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_timeline (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, card_id TEXT, event_type TEXT, content TEXT, metadata TEXT, timestamp DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_agent_status (project_id TEXT PRIMARY KEY, state TEXT, start_time DATETIME, last_message TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS summaries (card_id TEXT PRIMARY KEY, summary TEXT NOT NULL, embedding TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS code_symbols (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, file_path TEXT NOT NULL, symbol_name TEXT NOT NULL, symbol_type TEXT NOT NULL, signature TEXT, start_line INTEGER, end_line INTEGER, documentation TEXT, code_content TEXT, embedding TEXT, UNIQUE(project_id, file_path, symbol_name, symbol_type))")
            for table, col in [("projects", "description"), ("columns", "prompt_template"), ("columns", "acp_provider_id"), ("columns", "approval_mode"), ("cards", "last_summary"), ("cards", "config_options"), ("cards", "embedding"), ("summaries", "embedding")]:
                try: cursor.execute(f"ALTER TABLE {table} ADD COLUMN {col} TEXT")
                except: pass

    def get_projects(self): return self.projects.get_all()
    def create_project(self, name, workspace_path=None, description=None): return self.projects.create(name, workspace_path, description)
    def get_project(self, project_id): return self.projects.get_by_id(project_id)
    def create_column(self, project_id, name, position=None, color="#808080", prompt_template=None): return self.columns.create(project_id, name, position, color, prompt_template)
    def get_columns(self, project_id): return self.columns.get_all(project_id)
    def create_card(self, column_id, title, description=None, parent_id=None): return self.cards.create(column_id, title, description, parent_id)
    def get_card(self, card_id): return self.cards.get_by_id(card_id)
    def get_all_summaries(self, project_id): return self.summaries.get_all_for_project(project_id)
    def get_setting(self, key: str, default: Any = None) -> Any:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT value FROM settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row[0] if row else default
    def set_setting(self, key: str, value: Any):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute("INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at", (key, str(value), now))
