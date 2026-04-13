import sqlite3
import uuid
import json
import asyncio
import sys
import os
from datetime import datetime
from contextlib import asynccontextmanager
from typing import Optional, List, Dict, Any
import threading
from queue import Queue, Empty
from contextlib import contextmanager
from src.config.manager import config

MAX_SESSION_MESSAGES_PER_CARD = 200

class BaseRepository:
    def __init__(self, db: 'KanbanDB'):
        self.db = db

class ProjectRepository(BaseRepository):
    def add_timeline_event(self, project_id: str, card_id: Optional[str], event_type: str, content: str, metadata: Dict = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO project_timeline (project_id, card_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                (project_id, card_id, event_type, content, json.dumps(metadata) if metadata else None, now),
            )

    def create(self, name: str, workspace_path: str = None) -> str:
        project_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()

        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO projects (id, name, workspace_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                (project_id, name, workspace_path, now, now),
            )

            default_columns = [
                ("Todo", "#808080"),
                ("In Progress", "#1890ff"),
                ("Done", "#52c41a"),
            ]
            for i, (col_name, col_color) in enumerate(default_columns):
                col_id = str(uuid.uuid4())[:8]
                conn.execute(
                    "INSERT INTO columns (id, project_id, name, position, color, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (col_id, project_id, col_name, i, col_color, now),
                )

            conn.execute(
                "INSERT INTO project_timeline (project_id, event_type, content, timestamp) VALUES (?, ?, ?, ?)",
                (project_id, "project_created", f"Project '{name}' created", now),
            )

            return project_id

    def get_all(self) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                """SELECT p.*,
                    (SELECT COUNT(*) FROM cards c
                     JOIN columns col ON c.column_id = col.id
                     WHERE col.project_id = p.id) as card_count
                   FROM projects p ORDER BY updated_at DESC"""
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, project_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def update(self, project_id: str, name: str = None, workspace_path: str = None):
        updates = []
        params = []
        if name:
            updates.append("name = ?")
            params.append(name)
        if workspace_path is not None:
            updates.append("workspace_path = ?")
            params.append(workspace_path)
        
        if not updates: return
        
        updates.append("updated_at = ?")
        params.append(datetime.now().isoformat())
        params.append(project_id)
        
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE projects SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, project_id: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))
            conn.execute("DELETE FROM columns WHERE project_id = ?", (project_id,))
            conn.execute("DELETE FROM project_timeline WHERE project_id = ?", (project_id,))
            # Cards are deleted via ON DELETE CASCADE (if configured) or manually here:
            # For SQLite, manually cleaning related tables if PRAGMA foreign_keys = OFF
            cursor = conn.execute("SELECT id FROM columns WHERE project_id = ?", (project_id,))
            col_ids = [row[0] for row in cursor.fetchall()]
            if col_ids:
                placeholders = ",".join(["?"] * len(col_ids))
                conn.execute(f"DELETE FROM cards WHERE column_id IN ({placeholders})", col_ids)

    def get_timeline(self, project_id: str, limit: int = 100) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                """SELECT t.*, c.title as card_title 
                   FROM project_timeline t 
                   LEFT JOIN cards c ON c.id = t.card_id 
                   WHERE t.project_id = ? 
                   ORDER BY t.timestamp DESC LIMIT ?""",
                (project_id, limit),
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_all_agent_statuses(self) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT s.*, p.name as project_name 
                FROM project_agent_status s
                JOIN projects p ON p.id = s.project_id
            """)
            return [dict(row) for row in cursor.fetchall()]

    def get_project_agent_status(self, project_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM project_agent_status WHERE project_id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

class ColumnRepository(BaseRepository):
    def get_by_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT c.*, COUNT(cards.id) as card_count FROM columns c LEFT JOIN cards ON cards.column_id = c.id WHERE c.project_id = ? GROUP BY c.id ORDER BY c.position",
                (project_id,),
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, column_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM columns WHERE id = ?", (column_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_column_simple_for_bridge(self, column_id: str) -> Optional[Dict]:
        """Simplified version of get_column for bridge internal use."""
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT id, project_id FROM columns WHERE id = ?", (column_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def create(self, project_id: str, name: str, position: int = None, color: str = "#808080") -> str:
        col_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        if position is None:
            with self.db.get_connection() as conn:
                cursor = conn.execute("SELECT MAX(position) FROM columns WHERE project_id = ?", (project_id,))
                max_pos = cursor.fetchone()[0]
                position = (max_pos + 1) if max_pos is not None else 0
        
        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO columns (id, project_id, name, position, color, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (col_id, project_id, name, position, color, now),
            )
            return col_id

    def update(self, column_id: str, name: str = None, color: str = None):
        updates = []
        params = []
        if name:
            updates.append("name = ?")
            params.append(name)
        if color:
            updates.append("color = ?")
            params.append(color)
        
        if not updates: return
        params.append(column_id)
        
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE columns SET {', '.join(updates)} WHERE id = ?", params)

    def update_position(self, column_id: str, position: int):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE columns SET position = ? WHERE id = ?", (position, column_id))

    def delete(self, column_id: str, move_to_column_id: str = None):
        with self.db.get_connection() as conn:
            if move_to_column_id:
                conn.execute("UPDATE cards SET column_id = ? WHERE column_id = ?", (move_to_column_id, column_id))
            conn.execute("DELETE FROM columns WHERE id = ?", (column_id,))

class CardRepository(BaseRepository):
    def create(self, column_id: str, title: str, description: str = None, parent_id: str = None) -> str:
        card_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT MAX(position) FROM cards WHERE column_id = ?", (column_id,))
            max_pos = cursor.fetchone()[0]
            position = (max_pos + 1) if max_pos is not None else 0
            
            conn.execute(
                "INSERT INTO cards (id, column_id, title, description, position, parent_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (card_id, column_id, title, description, position, parent_id, now, now),
            )
            return card_id

    def get_by_id(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT c.*, col.project_id 
                FROM cards c 
                JOIN columns col ON col.id = c.column_id 
                WHERE c.id = ?
            """, (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_by_column(self, column_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM cards WHERE column_id = ? AND status = 'active' ORDER BY position", (column_id,))
            return [dict(row) for row in cursor.fetchall()]

    def update(self, card_id: str, title: str = None, description: str = None):
        updates = []
        params = []
        if title:
            updates.append("title = ?")
            params.append(title)
        if description is not None:
            updates.append("description = ?")
            params.append(description)
        
        if not updates: return
        
        updates.append("updated_at = ?")
        params.append(datetime.now().isoformat())
        params.append(card_id)
        
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE cards SET {', '.join(updates)} WHERE id = ?", params)

    def move(self, card_id: str, target_column_id: str, target_position: int = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            if target_position is None:
                cursor = conn.execute("SELECT MAX(position) FROM cards WHERE column_id = ?", (target_column_id,))
                max_pos = cursor.fetchone()[0]
                target_position = (max_pos + 1) if max_pos is not None else 0
            
            conn.execute(
                "UPDATE cards SET column_id = ?, position = ?, updated_at = ? WHERE id = ?",
                (target_column_id, target_position, now, card_id),
            )

    def delete(self, card_id: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM cards WHERE id = ?", (card_id,))
            conn.execute("DELETE FROM card_sessions WHERE card_id = ?", (card_id,))

    def update_card_session_id(self, card_id: str, session_id: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET acp_session_id = ? WHERE id = ?", (session_id, card_id))

    def update_provider(self, card_id: str, provider_id: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET acp_provider_id = ? WHERE id = ?", (provider_id, card_id))

    def complete_card(self, card_id: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET status = 'completed', completed_at = ?, updated_at = ? WHERE id = ?", (now, now, card_id))

    def uncomplete_card(self, card_id: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET status = 'active', completed_at = NULL, updated_at = ? WHERE id = ?", (now, card_id))

    def search_cards_semantic(self, embedding_vector: List[float], project_id: str = None, limit: int = 5) -> List[Dict]:
        # Placeholder for sqlite-vec implementation
        return []

    def upsert_card_embedding(self, card_id: str, embedding_vector: List[float]):
        # Placeholder for sqlite-vec implementation
        pass

    def search_cards_fts(self, query: str, project_id: str = None) -> List[Dict]:
        # FTS search across cards
        with self.db.get_connection() as conn:
            sql = """
                SELECT c.*, col.name as column_name 
                FROM cards c 
                JOIN columns col ON col.id = c.column_id 
                WHERE (c.title LIKE ? OR c.description LIKE ?)
            """
            params = [f"%{query}%", f"%{query}%"]
            if project_id:
                sql += " AND col.project_id = ?"
                params.append(project_id)
            
            cursor = conn.execute(sql, params)
            return [dict(row) for row in cursor.fetchall()]

class SummaryRepository(BaseRepository):
    def get_all_for_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                """SELECT s.*, c.title 
                   FROM summaries s 
                   JOIN cards c ON c.id = s.card_id 
                   JOIN columns col ON col.id = c.column_id 
                   WHERE col.project_id = ?""", (project_id,)
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_by_card_id(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM summaries WHERE card_id = ?", (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def upsert(self, card_id: str, summary: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO summaries (card_id, summary, updated_at) VALUES (?, ?, ?) ON CONFLICT(card_id) DO UPDATE SET summary=excluded.summary, updated_at=excluded.updated_at",
                (card_id, summary, now),
            )

class SessionRepository(BaseRepository):
    def add_message(self, card_id: str, role: str, content: str, metadata: Dict = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO card_sessions (card_id, role, content, metadata, created_at) VALUES (?, ?, ?, ?, ?)",
                (card_id, role, content, json.dumps(metadata) if metadata else None, now),
            )
            
            # Maintenance: limit history
            conn.execute(
                """DELETE FROM card_sessions WHERE id IN (
                    SELECT id FROM card_sessions WHERE card_id = ? 
                    ORDER BY created_at DESC LIMIT -1 OFFSET ?
                )""", (card_id, MAX_SESSION_MESSAGES_PER_CARD)
            )

    def get_history(self, card_id: str, limit: int = 50) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT * FROM card_sessions WHERE card_id = ? ORDER BY created_at ASC LIMIT ?",
                (card_id, limit),
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_latest_message(self, card_id: str, role: str = None) -> Optional[Dict]:
        """Gets the most recent message, optionally filtered by role."""
        with self.db.get_connection() as conn:
            sql = "SELECT * FROM card_sessions WHERE card_id = ?"
            params = [card_id]
            if role:
                sql += " AND role = ?"
                params.append(role)
            sql += " ORDER BY created_at DESC LIMIT 1"
            
            cursor = conn.execute(sql, params)
            row = cursor.fetchone()
            return dict(row) if row else None

    def append_message(self, card_id: str, role: str, content_chunk: str, is_complete: bool = True):
        """Appends content to the last message if role matches, or creates new."""
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            # Check last message
            cursor = conn.execute(
                "SELECT id, content FROM card_sessions WHERE card_id = ? AND role = ? AND is_complete = 0 ORDER BY created_at DESC LIMIT 1",
                (card_id, role)
            )
            row = cursor.fetchone()
            
            if row:
                new_content = row[1] + content_chunk
                # MED-NEW: Do NOT update created_at during append to keep original start time
                conn.execute(
                    "UPDATE card_sessions SET content = ?, is_complete = ? WHERE id = ?",
                    (new_content, 1 if is_complete else 0, row[0])
                )
            else:
                conn.execute(
                    "INSERT INTO card_sessions (card_id, role, content, is_complete, created_at) VALUES (?, ?, ?, ?, ?)",
                    (card_id, role, content_chunk, 1 if is_complete else 0, now)
                )

    def update_message_with_metadata(self, card_id: str, meta_key: str, meta_value: Any, new_content: str = None, is_complete: bool = True):
        """Finds a message by metadata and updates its content/status."""
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            # MED-NEW: Filter by is_complete=0 to avoid updating already finished tool calls
            cursor = conn.execute(
                "SELECT id, metadata FROM card_sessions WHERE card_id = ? AND metadata IS NOT NULL AND is_complete = 0 ORDER BY created_at DESC LIMIT 50",
                (card_id,)
            )
            rows = cursor.fetchall()
            target_id = None
            for row in rows:
                meta_str = row[1]
                if not meta_str: continue
                try:
                    meta = json.loads(meta_str)
                    if isinstance(meta, dict) and meta.get(meta_key) == meta_value:
                        target_id = row[0]
                        break
                except (json.JSONDecodeError, TypeError): 
                    continue
            
            if target_id:
                sql = "UPDATE card_sessions SET is_complete = ?"
                params = [1 if is_complete else 0]
                if new_content is not None:
                    sql += ", content = ?"
                    params.append(new_content)
                sql += " WHERE id = ?"
                params.append(target_id)
                conn.execute(sql, params)

class KanbanDB:
    _instance_lock = threading.Lock()
    _instance = None

    def __new__(cls, *args, **kwargs):
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = super(KanbanDB, cls).__new__(cls)
                cls._instance._initialized = False
            return cls._instance

    def __init__(self, db_path=None, pool_size=None):
        if hasattr(self, "_initialized") and self._initialized:
            return

        self.pool_size = pool_size or int(os.getenv("KANBAN_DB_POOL_SIZE", "5"))
        self.db_path = db_path or config.db_path

        print(f"[*] Database initialized at: {self.db_path}", file=sys.stderr)

        self._pool = Queue(maxsize=self.pool_size)
        self._async_pool = None
        self._async_lock = None

        self._locks_lock = threading.Lock()
        self._column_locks = {}

        for _ in range(self.pool_size):
            conn = self._create_new_connection()
            self._pool.put(conn)

        # Initialize Repositories
        self.projects = ProjectRepository(self)
        self.columns = ColumnRepository(self)
        self.cards = CardRepository(self)
        self.summaries = SummaryRepository(self)
        self.sessions = SessionRepository(self)

        self._initialized = True

    # --- Compatibility Proxy Layer ---
    def get_projects(self) -> List[Dict]: return self.projects.get_all()
    def create_project(self, name: str, workspace_path: str = None) -> str: return self.projects.create(name, workspace_path)
    def get_project(self, project_id: str) -> Optional[Dict]: return self.projects.get_by_id(project_id)
    def update_project(self, project_id: str, name: str = None, workspace_path: str = None): return self.projects.update(project_id, name, workspace_path)
    def delete_project(self, project_id: str): return self.projects.delete(project_id)
    def get_timeline(self, project_id: str, limit: int = 100) -> List[Dict]: return self.projects.get_timeline(project_id, limit)
    def get_all_agent_statuses(self) -> List[Dict]: return self.projects.get_all_agent_statuses()
    def get_project_agent_status(self, project_id: str) -> Optional[Dict]: return self.projects.get_project_agent_status(project_id)

    def get_columns(self, project_id: str) -> List[Dict]: return self.columns.get_by_project(project_id)
    def get_column(self, column_id: str) -> Optional[Dict]: return self.columns.get_by_id(column_id)
    def create_column(self, project_id: str, name: str, position: int = None, color: str = "#808080") -> str: return self.columns.create(project_id, name, position, color)
    def update_column(self, column_id: str, name: str = None, color: str = None): return self.columns.update(column_id, name, color)
    def delete_column(self, column_id: str, move_to_column_id: str = None): return self.columns.delete(column_id, move_to_column_id)
    def update_column_position(self, column_id: str, position: int): return self.columns.update_position(column_id, position)
    
    def create_card(self, column_id: str, title: str, description: str = None, parent_id: str = None) -> str: return self.cards.create(column_id, title, description, parent_id)
    def get_card(self, card_id: str) -> Optional[Dict]: return self.cards.get_by_id(card_id)
    def get_cards_by_column(self, column_id: str) -> List[Dict]: return self.cards.get_by_column(column_id)
    def update_card(self, card_id: str, title: str = None, description: str = None): return self.cards.update(card_id, title, description)
    def move_card(self, card_id: str, target_column_id: str, target_position: int = None): return self.cards.move(card_id, target_column_id, target_position)
    def delete_card(self, card_id: str): return self.cards.delete(card_id)
    def search_cards_fts(self, query: str, project_id: str = None) -> List[Dict]: return self.cards.search_cards_fts(query, project_id)
    def update_card_session_id(self, card_id: str, session_id: str): return self.cards.update_card_session_id(card_id, session_id)
    def update_card_provider(self, card_id: str, provider_id: str): return self.cards.update_provider(card_id, provider_id)
    def update_card_summary(self, card_id: str, summary: str):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute("UPDATE cards SET last_summary = ?, updated_at = ? WHERE id = ?", (summary, now, card_id))
    
    def complete_card(self, card_id: str): return self.cards.complete_card(card_id)
    def uncomplete_card(self, card_id: str): return self.cards.uncomplete_card(card_id)
    def search_cards_semantic(self, embedding_vector: List[float], project_id: str = None, limit: int = 5) -> List[Dict]: return self.cards.search_cards_semantic(embedding_vector, project_id, limit)
    def upsert_card_embedding(self, card_id: str, embedding_vector: List[float]): return self.cards.upsert_card_embedding(card_id, embedding_vector)
    
    def add_session_message(self, card_id: str, role: str, content: str, metadata: Dict = None): return self.sessions.add_message(card_id, role, content, metadata)
    def get_session_history(self, card_id: str, limit: int = 50) -> List[Dict]: return self.sessions.get_history(card_id, limit)
    
    def get_all_summaries(self, project_id: str) -> List[Dict]: return self.summaries.get_all_for_project(project_id)
    def get_summary(self, card_id: str) -> Optional[Dict]: return self.summaries.get_by_card_id(card_id)
    def save_summary(self, card_id: str, summary: str): return self.summaries.upsert(card_id, summary)

    def get_setting(self, key: str, default: Any = None) -> Any:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT value FROM settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row[0] if row else default

    def set_setting(self, key: str, value: Any):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                (key, str(value), now),
            )

    # --- End Proxy Layer ---

    def _create_new_connection(self):
        conn = sqlite3.connect(self.db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        self._load_extensions(conn)
        return conn

    async def _ensure_async_pool(self):
        if self._async_pool is None:
            if self._async_lock is None:
                self._async_lock = asyncio.Lock()
            async with self._async_lock:
                if self._async_pool is None:
                    self._async_pool = asyncio.Queue(maxsize=self.pool_size)
                    for _ in range(self.pool_size):
                        conn = self._create_new_connection()
                        await self._async_pool.put(conn)
        return self._async_pool

    def _load_extensions(self, conn):
        # sqlite-vec extension logic
        pass

    @contextmanager
    def get_connection(self):
        conn = self._pool.get()
        try:
            yield conn
            conn.commit()  # Auto-commit on success
        except Exception:
            conn.rollback()  # Rollback on error
            raise
        finally:
            self._pool.put(conn)

    @asynccontextmanager
    async def get_async_connection(self):
        pool = await self._ensure_async_pool()
        conn = await pool.get()
        try:
            yield conn
        finally:
            await pool.put(conn)

    def close(self):
        if self._pool:
            while not self._pool.empty():
                try:
                    conn = self._pool.get_nowait()
                    conn.close()
                except (Empty, Exception):
                    break

    def init_db(self):
        # Implementation remains the same but uses the new connection logic
        conn = self._create_new_connection()
        try:
            cursor = conn.cursor()
            cursor.execute("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_path TEXT, created_at DATETIME, updated_at DATETIME)")
            # Added strategy fields to columns
            cursor.execute("CREATE TABLE IF NOT EXISTS columns (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER, color TEXT, prompt_template TEXT, acp_provider_id TEXT, approval_mode TEXT, created_at DATETIME)")
            # Added last_summary to cards
            cursor.execute("CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, column_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, position INTEGER, status TEXT DEFAULT 'active', completed_at DATETIME, parent_id TEXT, last_summary TEXT, created_at DATETIME, updated_at DATETIME, acp_session_id TEXT, acp_provider_id TEXT)")
            cursor.execute("CREATE TABLE IF NOT EXISTS card_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, role TEXT, content TEXT, metadata TEXT, created_at DATETIME, is_complete INTEGER DEFAULT 1)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_timeline (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, card_id TEXT, event_type TEXT, content TEXT, metadata TEXT, timestamp DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_agent_status (project_id TEXT PRIMARY KEY, state TEXT, start_time DATETIME, last_message TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS summaries (card_id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at DATETIME)")
            
            # Migration: Check if new columns exist, if not add them
            try:
                cursor.execute("ALTER TABLE columns ADD COLUMN prompt_template TEXT")
                cursor.execute("ALTER TABLE columns ADD COLUMN acp_provider_id TEXT")
                cursor.execute("ALTER TABLE columns ADD COLUMN approval_mode TEXT")
            except: pass
            try:
                cursor.execute("ALTER TABLE cards ADD COLUMN last_summary TEXT")
            except: pass
            
            conn.commit()
        finally:
            conn.close()
