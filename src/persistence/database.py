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
from src.logger import setup_logger

logger = setup_logger("KanbanDB")

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
            # Try to get from pool first with small timeout
            return self._pool.get(timeout=0.5)
        except Empty:
            with self._lock:
                if self._current_size < self._max_size:
                    conn = self._create_fn()
                    self._current_size += 1
                    return conn
            # Pool is full and empty, wait until one is free
            return self._pool.get()

    def put(self, conn):
        try:
            self._pool.put(conn, block=False)
        except:
            # If pool somehow got extra connections, close this one
            try:
                conn.close()
            except:
                pass
            with self._lock:
                self._current_size = max(0, self._current_size - 1)
                assert self._current_size >= 0, "Connection pool size underflow!"

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
            cursor = conn.execute("""
                SELECT p.*, 
                (SELECT COUNT(*) FROM cards c JOIN columns col ON c.column_id = col.id WHERE col.project_id = p.id) as card_count
                FROM projects p ORDER BY created_at DESC
            """)
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, project_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def update(self, project_id: str, name: str = None, workspace_path: str = None, description: str = None):
        updates = []
        params = []
        if name is not None:
            updates.append("name = ?")
            params.append(name)
        if workspace_path is not None:
            updates.append("workspace_path = ?")
            params.append(workspace_path)
        if description is not None:
            updates.append("description = ?")
            params.append(description)
        
        if not updates:
            return

        updates.append("updated_at = ?")
        params.append(datetime.now().isoformat())
        params.append(project_id)

        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE projects SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, project_id: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))

class ColumnRepository(BaseRepository):
    def create(self, project_id: str, name: str, position: int = None, color: str = "#808080", prompt_template: str = None, acp_provider_id: str = None) -> str:
        col_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        if position is None:
            with self.db.get_connection() as conn:
                cursor = conn.execute("SELECT MAX(position) FROM columns WHERE project_id = ?", (project_id,))
                max_pos = cursor.fetchone()[0]
                position = (max_pos + 1) if max_pos is not None else 0
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO columns (id, project_id, name, position, color, prompt_template, acp_provider_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (col_id, project_id, name, position, color, prompt_template, acp_provider_id, now))
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

    def update(self, column_id: str, name: str = None, color: str = None, prompt_template: str = None, acp_provider_id: str = None):
        updates = []
        params = []
        if name is not None:
            updates.append("name = ?")
            params.append(name)
        if color is not None:
            updates.append("color = ?")
            params.append(color)
        if prompt_template is not None:
            updates.append("prompt_template = ?")
            params.append(prompt_template)
        if acp_provider_id is not None:
            updates.append("acp_provider_id = ?")
            params.append(acp_provider_id)
        
        if not updates:
            return

        params.append(column_id)
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE columns SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, column_id: str, move_to_column_id: str = None):
        with self.db.get_connection() as conn:
            if move_to_column_id:
                conn.execute("UPDATE cards SET column_id = ? WHERE column_id = ?", (move_to_column_id, column_id))
            else:
                conn.execute("DELETE FROM cards WHERE column_id = ?", (column_id,))
            conn.execute("DELETE FROM columns WHERE id = ?", (column_id,))

    def reorder(self, positions: List[Dict[str, Any]]):
        with self.db.get_connection() as conn:
            for item in positions:
                conn.execute("UPDATE columns SET position = ? WHERE id = ?", (item["position"], item["id"]))

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
            cursor = conn.execute("""
                SELECT c.*, col.project_id, col.name as column_name,
                (SELECT COUNT(*) FROM card_sessions WHERE card_id = c.id) as session_count
                FROM cards c 
                JOIN columns col ON col.id = c.column_id 
                WHERE c.id = ?
            """, (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_by_column(self, column_id: str, include_completed: bool = False) -> List[Dict]:
        query = """
            SELECT c.*, 
            (SELECT COUNT(*) FROM card_sessions cs WHERE cs.card_id = c.id) as session_count
            FROM cards c WHERE c.column_id = ?
        """
        params = [column_id]
        if not include_completed:
            query += " AND status != 'completed'"
        query += " ORDER BY position ASC"
        
        with self.db.get_connection() as conn:
            cursor = conn.execute(query, params)
            return [dict(row) for row in cursor.fetchall()]

    def update(self, card_id: str, title: str = None, description: str = None, status: str = None):
        updates = []
        params = []
        if title is not None:
            updates.append("title = ?")
            params.append(title)
        if description is not None:
            updates.append("description = ?")
            params.append(description)
        if status is not None:
            updates.append("status = ?")
            params.append(status)
            if status == 'completed':
                updates.append("completed_at = ?")
                params.append(datetime.now().isoformat())
            else:
                updates.append("completed_at = NULL")
        
        if not updates:
            return

        updates.append("updated_at = ?")
        params.append(datetime.now().isoformat())
        params.append(card_id)

        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE cards SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, card_id: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM cards WHERE id = ?", (card_id,))

    def move(self, card_id: str, target_column_id: str, target_position: int = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            if target_position is None:
                cursor = conn.execute("SELECT MAX(position) FROM cards WHERE column_id = ?", (target_column_id,))
                max_pos = cursor.fetchone()[0]
                target_position = (max_pos + 1) if max_pos is not None else 0
            
            conn.execute("UPDATE cards SET column_id = ?, position = ?, updated_at = ? WHERE id = ?", (target_column_id, target_position, now, card_id))

    def update_provider(self, card_id: str, provider_id: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET acp_provider_id = ? WHERE id = ?", (provider_id, card_id))

    def update_session_id(self, card_id: str, session_id: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET acp_session_id = ? WHERE id = ?", (session_id, card_id))

    def get_config_options(self, card_id: str) -> Optional[str]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT config_options FROM cards WHERE id = ?", (card_id,))
            row = cursor.fetchone()
            return row[0] if row else None

    def update_config_options(self, card_id: str, config_options: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET config_options = ? WHERE id = ?", (config_options, card_id))

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
            # Phase 5.3 FIX: Save current summary to history before overwriting
            cursor = conn.execute("SELECT summary FROM summaries WHERE card_id = ?", (card_id,))
            row = cursor.fetchone()
            if row and row['summary'] != summary:
                conn.execute("INSERT INTO summary_history (card_id, summary, created_at) VALUES (?, ?, ?)", (card_id, row['summary'], now))
            
            conn.execute("INSERT INTO summaries (card_id, summary, embedding, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(card_id) DO UPDATE SET summary=excluded.summary, embedding=excluded.embedding, updated_at=excluded.updated_at", (card_id, summary, json.dumps(embedding) if embedding else None, now))
            
            # Phase 5.3: Sync summary to cards table for easier retrieval in list views
            conn.execute("UPDATE cards SET last_summary = ?, updated_at = ? WHERE id = ?", (summary, now, card_id))

    def update_card_summary(self, card_id: str, summary: str):
        return self.upsert(card_id, summary)

    def get_by_card_id(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM summaries WHERE card_id = ?", (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_all_for_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT s.*, c.title FROM summaries s JOIN cards c ON c.id = s.card_id JOIN columns col ON col.id = c.column_id WHERE col.project_id = ?", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def search_semantic(self, embedding_vector: List[float], project_id: str, limit: int = 5) -> List[Dict]:
        all_summaries = self.get_all_for_project(project_id)
        results = []
        for s in all_summaries:
            if s.get('embedding'):
                try:
                    s['similarity'] = cosine_similarity(embedding_vector, json.loads(s['embedding']))
                    results.append(s)
                except: continue
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
    def add_message(self, card_id: str, role: str, content: str, metadata: Dict = None, is_milestone: bool = False):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO card_sessions (card_id, role, content, metadata, created_at, is_milestone) VALUES (?, ?, ?, ?, ?, ?)", (card_id, role, content, json.dumps(metadata) if metadata else None, now, 1 if is_milestone else 0))

    def append_message(self, card_id: str, role: str, chunk: str, is_complete: bool = False, is_milestone: bool = False):
        with self.db.get_connection() as conn:
            # Find the most recent incomplete message for this card and role
            cursor = conn.execute(
                "SELECT id, content FROM card_sessions WHERE card_id = ? AND role = ? AND is_complete = 0 ORDER BY created_at DESC LIMIT 1",
                (card_id, role)
            )
            row = cursor.fetchone()
            
            if row:
                new_content = row['content'] + chunk
                conn.execute(
                    "UPDATE card_sessions SET content = ?, is_complete = ?, is_milestone = ? WHERE id = ?",
                    (new_content, 1 if is_complete else 0, 1 if is_milestone else 0, row['id'])
                )
            elif chunk or not is_complete:
                # Create a new message if there's no incomplete one
                now = datetime.now().isoformat()
                conn.execute(
                    "INSERT INTO card_sessions (card_id, role, content, is_complete, created_at, is_milestone) VALUES (?, ?, ?, ?, ?, ?)",
                    (card_id, role, chunk, 1 if is_complete else 0, now, 1 if is_milestone else 0)
                )

    def append_thought(self, card_id: str, thought_chunk: str):
        with self.db.get_connection() as conn:
            # Find the most recent incomplete assistant message to append the thought to
            cursor = conn.execute(
                "SELECT id, metadata FROM card_sessions WHERE card_id = ? AND role = 'assistant' AND is_complete = 0 ORDER BY created_at DESC LIMIT 1",
                (card_id,)
            )
            row = cursor.fetchone()
            
            if row:
                metadata = json.loads(row['metadata']) if row['metadata'] else {}
                current_thought = metadata.get('thought', '')
                metadata['thought'] = current_thought + thought_chunk
                conn.execute(
                    "UPDATE card_sessions SET metadata = ? WHERE id = ?",
                    (json.dumps(metadata), row['id'])
                )
            else:
                # No active assistant message, create a placeholder one with is_complete=0
                now = datetime.now().isoformat()
                metadata = {'thought': thought_chunk}
                conn.execute(
                    "INSERT INTO card_sessions (card_id, role, content, metadata, is_complete, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (card_id, 'assistant', '', json.dumps(metadata), 0, now)
                )

    def update_message_with_metadata(self, card_id: str, meta_key: str, meta_value: Any, new_content: str = None, is_complete: bool = True):
        with self.db.get_connection() as conn:
            # Find messages that have the specific metadata key/value
            cursor = conn.execute(
                "SELECT id, content, metadata FROM card_sessions WHERE card_id = ? ORDER BY created_at DESC",
                (card_id,)
            )
            rows = cursor.fetchall()
            
            target_id = None
            for row in rows:
                metadata = json.loads(row['metadata']) if row['metadata'] else {}
                if metadata.get(meta_key) == meta_value:
                    target_id = row['id']
                    break
            
            if target_id:
                updates = ["is_complete = ?"]
                params = [1 if is_complete else 0]
                if new_content is not None:
                    updates.append("content = ?")
                    params.append(new_content)
                params.append(target_id)
                conn.execute(f"UPDATE card_sessions SET {', '.join(updates)} WHERE id = ?", params)

    def get_history(self, card_id: str, limit: int = MAX_SESSION_HISTORY) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM card_sessions WHERE card_id = ? ORDER BY created_at ASC LIMIT ?", (card_id, limit))
            return [dict(row) for row in cursor.fetchall()]

class TimelineRepository(BaseRepository):
    def add_event(self, project_id: str, card_id: str, event_type: str, content: str, metadata: Dict = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO project_timeline (project_id, card_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?)", (project_id, card_id, event_type, content, json.dumps(metadata) if metadata else None, now))

    def get_for_project(self, project_id: str, limit: int = 100) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT t.*, c.title as card_title 
                FROM project_timeline t 
                LEFT JOIN cards c ON t.card_id = c.id 
                WHERE t.project_id = ? 
                ORDER BY timestamp DESC LIMIT ?
            """, (project_id, limit))
            return [dict(row) for row in cursor.fetchall()]

class AgentStatusRepository(BaseRepository):
    def update(self, project_id: str, state: str, message: str = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("""
                INSERT INTO project_agent_status (project_id, state, last_message, updated_at, start_time) 
                VALUES (?, ?, ?, ?, ?) 
                ON CONFLICT(project_id) DO UPDATE SET 
                state=excluded.state, last_message=excluded.last_message, updated_at=excluded.updated_at
            """, (project_id, state, message, now, now))

    def get_by_project(self, project_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM project_agent_status WHERE project_id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_all(self) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT s.*, p.name as project_name 
                FROM project_agent_status s 
                JOIN projects p ON s.project_id = p.id
            """)
            return [dict(row) for row in cursor.fetchall()]

class FileIndexRepository(BaseRepository):
    def upsert(self, project_id: str, file_path: str, file_hash: str, file_size: int):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("""
                INSERT INTO file_index (project_id, file_path, file_hash, file_size, indexed_at) 
                VALUES (?, ?, ?, ?, ?) 
                ON CONFLICT(project_id, file_path) DO UPDATE SET 
                file_hash=excluded.file_hash, file_size=excluded.file_size, indexed_at=excluded.indexed_at
            """, (project_id, file_path, file_hash, file_size, now))

    def get(self, project_id: str, file_path: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM file_index WHERE project_id = ? AND file_path = ?", (project_id, file_path))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_by_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM file_index WHERE project_id = ?", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def delete(self, project_id: str, file_path: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM file_index WHERE project_id = ? AND file_path = ?", (project_id, file_path))

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
        self.timeline = TimelineRepository(self)
        self.agent_status = AgentStatusRepository(self)
        self.file_index = FileIndexRepository(self)
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
            cursor.execute("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_path TEXT, description TEXT, created_at DATETIME, updated_at DATETIME, index_status TEXT DEFAULT 'idle', last_indexed_at DATETIME, total_files INTEGER DEFAULT 0, total_symbols INTEGER DEFAULT 0, total_vectorized_symbols INTEGER DEFAULT 0, index_checkpoint TEXT)")
            cursor.execute("CREATE TABLE IF NOT EXISTS columns (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER, color TEXT, prompt_template TEXT, acp_provider_id TEXT, approval_mode TEXT, created_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, column_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, position INTEGER, status TEXT DEFAULT 'active', completed_at DATETIME, parent_id TEXT, last_summary TEXT, embedding TEXT, created_at DATETIME, updated_at DATETIME, acp_session_id TEXT, acp_provider_id TEXT, config_options TEXT)")
            cursor.execute("CREATE TABLE IF NOT EXISTS card_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, role TEXT, content TEXT, metadata TEXT, created_at DATETIME, is_complete INTEGER DEFAULT 1, is_milestone INTEGER DEFAULT 0)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_timeline (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, card_id TEXT, event_type TEXT, content TEXT, metadata TEXT, timestamp DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_agent_status (project_id TEXT PRIMARY KEY, state TEXT, start_time DATETIME, last_message TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS summaries (card_id TEXT PRIMARY KEY, summary TEXT NOT NULL, embedding TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS summary_history (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, summary TEXT NOT NULL, created_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS code_symbols (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, file_path TEXT NOT NULL, symbol_name TEXT NOT NULL, symbol_type TEXT NOT NULL, signature TEXT, start_line INTEGER, end_line INTEGER, documentation TEXT, code_content TEXT, embedding TEXT, UNIQUE(project_id, file_path, symbol_name, symbol_type))")
            cursor.execute("CREATE TABLE IF NOT EXISTS file_index (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, file_path TEXT NOT NULL, file_hash TEXT NOT NULL, file_size INTEGER, indexed_at DATETIME, UNIQUE(project_id, file_path))")
            
            # Migration/Maintenance: Add columns if they were missing from older versions
            migrations = [
                ("projects", "description", "TEXT"), 
                ("projects", "index_status", "TEXT DEFAULT 'idle'"),
                ("projects", "last_indexed_at", "DATETIME"),
                ("projects", "total_files", "INTEGER DEFAULT 0"),
                ("projects", "total_symbols", "INTEGER DEFAULT 0"),
                ("projects", "total_vectorized_symbols", "INTEGER DEFAULT 0"),
                ("projects", "index_checkpoint", "TEXT"),
                ("columns", "prompt_template", "TEXT"), 
                ("columns", "approval_mode", "TEXT"), 
                ("cards", "last_summary", "TEXT"), 
                ("cards", "config_options", "TEXT"), 
                ("cards", "embedding", "TEXT"), 
                ("summaries", "embedding", "TEXT"), 
                ("card_sessions", "is_milestone", "INTEGER DEFAULT 0")
            ]
            
            for table, col, col_type in migrations:
                try: 
                    cursor.execute(f"ALTER TABLE {table} ADD COLUMN {col} {col_type}")
                except Exception as e: 
                    # Column already exists is expected on repeated runs
                    if "duplicate column name" not in str(e).lower():
                        logger.warning(f"DB Migration: Could not add {table}.{col}: {e}")
                    pass

    # --- API Bridge Methods (Flattened for backward compatibility) ---
    def get_projects(self): return self.projects.get_all()
    def create_project(self, name, workspace_path=None, description=None): return self.projects.create(name, workspace_path, description)
    def get_project(self, project_id): return self.projects.get_by_id(project_id)
    def update_project(self, project_id, name=None, workspace_path=None, description=None): return self.projects.update(project_id, name, workspace_path, description)
    def delete_project(self, project_id): return self.projects.delete(project_id)

    def get_columns(self, project_id): return self.columns.get_all(project_id)
    def get_column(self, column_id): return self.columns.get_by_id(column_id)
    def create_column(self, project_id, name, position=None, color="#808080", prompt_template=None, acp_provider_id=None): return self.columns.create(project_id, name, position, color, prompt_template, acp_provider_id)
    def update_column(self, column_id, name=None, color=None, prompt_template=None, acp_provider_id=None): return self.columns.update(column_id, name, color, prompt_template, acp_provider_id)
    def delete_column(self, column_id, move_to_column_id=None): return self.columns.delete(column_id, move_to_column_id)
    def reorder_columns(self, positions): return self.columns.reorder(positions)

    def get_card(self, card_id): return self.cards.get_by_id(card_id)
    def get_cards_by_column(self, column_id, include_completed=False): return self.cards.get_by_column(column_id, include_completed)
    def create_card(self, column_id, title, description=None, parent_id=None): return self.cards.create(column_id, title, description, parent_id)
    def update_card(self, card_id, title=None, description=None, status=None): return self.cards.update(card_id, title, description, status)
    def delete_card(self, card_id): return self.cards.delete(card_id)
    def move_card(self, card_id, target_column_id, target_position=None): return self.cards.move(card_id, target_column_id, target_position)
    def update_card_provider(self, card_id, provider_id): return self.cards.update_provider(card_id, provider_id)
    def update_card_session_id(self, card_id, session_id): return self.cards.update_session_id(card_id, session_id)
    def get_card_config_options(self, card_id): return self.cards.get_config_options(card_id)
    def update_card_config_options(self, card_id, config_options): return self.cards.update_config_options(card_id, config_options)
    def complete_card(self, card_id): return self.cards.update(card_id, status='completed')
    def uncomplete_card(self, card_id): return self.cards.update(card_id, status='active')

    def get_summary(self, card_id): return self.summaries.get_by_card_id(card_id)
    def get_all_summaries(self, project_id): return self.summaries.get_all_for_project(project_id)
    
    def get_session_history(self, card_id, limit=50): return self.sessions.get_history(card_id, limit)
    def add_session_message(self, card_id, role, content, metadata=None, is_milestone=False): return self.sessions.add_message(card_id, role, content, metadata, is_milestone)
    def append_session_message(self, card_id, role, content, is_complete=False, is_milestone=False): return self.sessions.append_message(card_id, role, content, is_complete, is_milestone)
    def append_thought(self, card_id, thought_text): return self.sessions.append_thought(card_id, thought_text)
    def update_session_message_metadata(self, card_id, meta_key, meta_value, new_content=None, is_complete=True): return self.sessions.update_message_with_metadata(card_id, meta_key, meta_value, new_content, is_complete)

    def get_timeline(self, project_id, limit=100): return self.timeline.get_for_project(project_id, limit)
    def add_timeline_event(self, project_id, card_id, event_type, content, metadata=None): return self.timeline.add_event(project_id, card_id, event_type, content, metadata)

    def get_project_agent_status(self, project_id): return self.agent_status.get_by_project(project_id)
    def get_all_agent_statuses(self): return self.agent_status.get_all()
    def update_agent_status(self, project_id, state, message=None): return self.agent_status.update(project_id, state, message)

    def get_setting(self, key: str, default: Any = None) -> Any:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT value FROM settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row[0] if row else default
            
    def update_project_stats(self, project_id: str, total_files: int = None, total_symbols: int = None, total_vectorized_symbols: int = None, index_status: str = None, last_indexed_at: str = None, index_checkpoint: str = None):
        updates = []
        params = []
        if total_files is not None:
            updates.append("total_files = ?")
            params.append(total_files)
        if total_symbols is not None:
            updates.append("total_symbols = ?")
            params.append(total_symbols)
        if total_vectorized_symbols is not None:
            updates.append("total_vectorized_symbols = ?")
            params.append(total_vectorized_symbols)
        if index_status is not None:
            updates.append("index_status = ?")
            params.append(index_status)
        if last_indexed_at is not None:
            updates.append("last_indexed_at = ?")
            params.append(last_indexed_at)
        if index_checkpoint is not None:
            updates.append("index_checkpoint = ?")
            params.append(index_checkpoint)
        
        if not updates:
            return

        params.append(project_id)
        with self.get_connection() as conn:
            conn.execute(f"UPDATE projects SET {', '.join(updates)} WHERE id = ?", params)

    def get_project_file_count(self, project_id: str) -> int:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) FROM file_index WHERE project_id = ?", (project_id,))
            return cursor.fetchone()[0]

    def get_project_symbol_count(self, project_id: str) -> int:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", (project_id,))
            return cursor.fetchone()[0]

    def get_project_vectorized_symbol_count(self, project_id: str) -> int:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) FROM code_symbols WHERE project_id = ? AND embedding IS NOT NULL AND embedding != '[]'", (project_id,))
            return cursor.fetchone()[0]

    def set_setting(self, key: str, value: Any):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute("INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at", (key, str(value), now))

