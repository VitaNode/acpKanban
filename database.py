import sqlite3
import uuid
import json
import asyncio
from datetime import datetime
from contextlib import asynccontextmanager
from typing import Optional, List, Dict, Any
import threading
from queue import Queue, Empty
from contextlib import contextmanager
from config_manager import config

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
                     JOIN columns col ON col.id = c.column_id
                     WHERE col.project_id = p.id) as card_count
                FROM projects p
                ORDER BY p.updated_at DESC"""
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, project_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def update(self, project_id: str, name: str = None, workspace_path: str = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            if name is not None:
                conn.execute(
                    "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
                    (name, now, project_id),
                )
            if workspace_path is not None:
                conn.execute(
                    "UPDATE projects SET workspace_path = ?, updated_at = ? WHERE id = ?",
                    (workspace_path, now, project_id),
                )

    def delete(self, project_id: str):
        with self.db.get_connection() as conn:
            conn.execute("PRAGMA foreign_keys = ON")
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute("DELETE FROM project_agent_status WHERE project_id = ?", (project_id,))
                conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))
                conn.commit()
            except Exception as e:
                conn.rollback()
                raise e

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
        column_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()

        with self.db.get_connection() as conn:
            if position is None:
                cursor = conn.execute(
                    "SELECT MAX(position) FROM columns WHERE project_id = ?",
                    (project_id,),
                )
                row = cursor.fetchone()
                position = (row[0] + 1) if row[0] is not None else 0

            conn.execute(
                "INSERT INTO columns (id, project_id, name, position, color, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (column_id, project_id, name, position, color, now),
            )
            return column_id

class CardRepository(BaseRepository):
    def get_by_column(self, column_id: str, include_completed: bool = False) -> List[Dict]:
        with self.db.get_connection() as conn:
            if include_completed:
                cursor = conn.execute(
                    "SELECT c.*, (SELECT COUNT(*) FROM card_sessions WHERE card_id = c.id) as session_count FROM cards c WHERE c.column_id = ? ORDER BY c.position",
                    (column_id,),
                )
            else:
                cursor = conn.execute(
                    "SELECT c.*, (SELECT COUNT(*) FROM card_sessions WHERE card_id = c.id) as session_count FROM cards c WHERE c.column_id = ? AND status = 'active' ORDER BY c.position",
                    (column_id,),
                )
            return [dict(row) for row in cursor.fetchall()]

    def get_by_id(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT c.*, col.name as column_name, col.project_id FROM cards c JOIN columns col ON col.id = c.column_id WHERE c.id = ?",
                (card_id,),
            )
            row = cursor.fetchone()
            return dict(row) if row else None

    def create(self, column_id: str, title: str, description: str = "", position: int = None) -> str:
        card_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()

        with self.db.get_connection() as conn:
            if position is None:
                cursor = conn.execute(
                    "SELECT MAX(position) FROM cards WHERE column_id = ?",
                    (column_id,),
                )
                row = cursor.fetchone()
                position = (row[0] + 1) if row[0] is not None else 0

            conn.execute(
                "INSERT INTO cards (id, column_id, title, description, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (card_id, column_id, title, description, position, now, now),
            )
            return card_id

    def update_card_session_id(self, card_id: str, session_id: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET acp_session_id = ? WHERE id = ?", (session_id, card_id))

class SummaryRepository(BaseRepository):
    def get_all_for_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT s.*, c.title FROM summaries s JOIN cards c ON c.id = s.card_id JOIN columns col ON col.id = c.column_id WHERE col.project_id = ? ORDER BY s.updated_at DESC",
                (project_id,),
            )
            return [dict(row) for row in cursor.fetchall()]

    def upsert(self, card_id: str, summary: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO summaries (card_id, summary, updated_at) VALUES (?, ?, ?) ON CONFLICT(card_id) DO UPDATE SET summary=excluded.summary, updated_at=excluded.updated_at",
                (card_id, summary, now),
            )

class SessionRepository(BaseRepository):
    def add_message(self, card_id: str, role: str, content: str, metadata: Dict = None, is_complete: bool = True) -> int:
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                "INSERT INTO card_sessions (card_id, role, content, metadata, created_at, is_complete) VALUES (?, ?, ?, ?, ?, ?)",
                (card_id, role, content, json.dumps(metadata) if metadata else None, now, 1 if is_complete else 0),
            )
            msg_id = cursor.lastrowid
            conn.commit()
            return msg_id

    def append_message(self, card_id: str, role: str, content: str, is_complete: bool = False) -> int:
        """Append content to the last message if same role and within 30s window."""
        now = datetime.now()
        now_iso = now.isoformat()
        
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                "SELECT id, role, content, created_at, is_complete FROM card_sessions WHERE card_id = ? ORDER BY id DESC LIMIT 1",
                (card_id,)
            )
            row = cursor.fetchone()
            
            should_append = False
            if row:
                msg_id, last_role, last_content, last_created, last_is_complete = row
                try:
                    last_dt = datetime.fromisoformat(last_created)
                    if last_role == role and (now - last_dt).total_seconds() < 30 and not last_is_complete:
                        should_append = True
                except: pass
            
            if should_append:
                new_content = (last_content or "") + content
                conn.execute(
                    "UPDATE card_sessions SET content = ?, created_at = ?, is_complete = ? WHERE id = ?",
                    (new_content, now_iso, 1 if is_complete else 0, msg_id)
                )
                conn.commit()
                return msg_id
            else:
                cursor = conn.execute(
                    "INSERT INTO card_sessions (card_id, role, content, created_at, is_complete) VALUES (?, ?, ?, ?, ?)",
                    (card_id, role, content, now_iso, 1 if is_complete else 0),
                )
                new_id = cursor.lastrowid
                conn.commit()
                return new_id

    def update_message_with_metadata(self, card_id: str, metadata_key: str, metadata_value: Any, new_content: str = None, is_complete: bool = None):
        """Update a message found by metadata (e.g. toolCallId)."""
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            search_str = f'%"{metadata_key}": "{metadata_value}"%'
            cursor = conn.execute(
                "SELECT id FROM card_sessions WHERE card_id = ? AND metadata LIKE ? ORDER BY id DESC LIMIT 1",
                (card_id, search_str)
            )
            row = cursor.fetchone()
            if row:
                msg_id = row[0]
                updates = ["created_at = ?"]
                params = [now]
                if new_content is not None:
                    updates.append("content = ?")
                    params.append(new_content)
                if is_complete is not None:
                    updates.append("is_complete = ?")
                    params.append(1 if is_complete else 0)
                
                params.append(msg_id)
                conn.execute(f"UPDATE card_sessions SET {', '.join(updates)} WHERE id = ?", params)
                conn.commit()

    def get_history(self, card_id: str, limit: int = 50) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT * FROM card_sessions WHERE card_id = ? ORDER BY created_at ASC LIMIT ?",
                (card_id, limit),
            )
            return [dict(row) for row in cursor.fetchall()]

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
        import os

        self.pool_size = pool_size or int(os.getenv("KANBAN_DB_POOL_SIZE", "5"))
        self.db_path = db_path or config.db_path
            
        print(f"[*] Database initialized at: {self.db_path}")

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
        try:
            conn.enable_load_extension(True)
            import sqlite_vec
            sqlite_vec.load(conn)
        except Exception:
            pass

    @contextmanager
    def get_connection(self):
        conn = None
        try:
            try:
                conn = self._pool.get(timeout=2)
            except Empty:
                conn = self._create_new_connection()

            conn.execute("PRAGMA foreign_keys = ON")
            yield conn
            if conn:
                try:
                    conn.commit()
                except Exception:
                    pass
        except Exception as e:
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
            raise e
        finally:
            if conn:
                if not self._pool.full():
                    self._pool.put_nowait(conn)
                else:
                    conn.close()

    @asynccontextmanager
    async def get_async_connection(self):
        pool = await self._ensure_async_pool()
        conn = None
        try:
            conn = await asyncio.wait_for(pool.get(), timeout=2.0)
        except asyncio.TimeoutError:
            conn = self._create_new_connection()

        try:
            yield conn
            if conn:
                try:
                    conn.commit()
                except Exception:
                    pass
        except Exception as e:
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
            raise e
        finally:
            if conn:
                if not pool.full():
                    pool.put_nowait(conn)
                else:
                    conn.close()

    async def close_all_async(self):
        if self._async_pool:
            while not self._async_pool.empty():
                try:
                    conn = self._async_pool.get_nowait()
                    conn.close()
                except (asyncio.QueueEmpty, Exception):
                    break
        self.close_all()

    def close_all(self):
        if hasattr(self, "_pool"):
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
            cursor.execute("CREATE TABLE IF NOT EXISTS columns (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER, color TEXT, created_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, column_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, position INTEGER, status TEXT DEFAULT 'active', completed_at DATETIME, parent_id TEXT, created_at DATETIME, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS card_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, role TEXT, content TEXT, metadata TEXT, created_at DATETIME, is_complete INTEGER DEFAULT 1)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_timeline (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, card_id TEXT, event_type TEXT, content TEXT, metadata TEXT, timestamp DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_agent_status (project_id TEXT PRIMARY KEY, state TEXT, start_time DATETIME, last_message TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT, updated_at DATETIME)")
            conn.commit()
        finally:
            conn.close()
