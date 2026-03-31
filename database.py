import sqlite3
import uuid
import json
from datetime import datetime
from typing import Optional, List, Dict, Any
import threading
from queue import Queue, Empty
from contextlib import contextmanager

MAX_SESSION_MESSAGES_PER_CARD = 200


class KanbanDB:
    _instance_lock = threading.Lock()
    _instance = None

    def __new__(cls, *args, **kwargs):
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = super(KanbanDB, cls).__new__(cls)
            return cls._instance

    def __init__(self, db_path="kanban.db", pool_size=5):
        if hasattr(self, "_initialized"):
            return
        self.db_path = db_path
        self.pool_size = pool_size
        self._pool = Queue(maxsize=pool_size)
        self._column_locks = {}  # Per-project locks for column/card operations
        # Locking strategy:
        # 1. Per-project locks prevent concurrent modifications to the same project
        # 2. Each project has its own lock object, allowing parallel operations across projects
        # 3. Cross-project moves are rejected at the application level before locking
        # 4. SQLite's IMMEDIATE transactions provide additional row-level safety
        self._locks_lock = threading.Lock()
        self._initialized = True

        self.init_db()
        self.migrate()

        for _ in range(pool_size):
            conn = self._create_new_connection()
            self._load_extensions(conn)
            self._pool.put(conn)

    def _create_new_connection(self):
        conn = sqlite3.connect(self.db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        return conn

    def _load_extensions(self, conn):
        import logging

        logger = logging.getLogger(__name__)

        try:
            conn.enable_load_extension(True)
            extension_paths = [
                "vec0",
                "/usr/local/lib/vec0.so",
                "./lib/vec0.so",
            ]
            for path in extension_paths:
                try:
                    conn.execute(f"SELECT load_extension('{path}')")
                    logger.info(f"Loaded sqlite-vec from {path}")
                    return
                except Exception:
                    continue
            logger.warning("sqlite-vec extension not found. Semantic search disabled.")
        except Exception as e:
            logger.warning(f"Failed to load sqlite-vec: {e}")

    @contextmanager
    def get_connection(self):
        """上下文管理器确保连接正确获取和释放"""
        conn = None
        try:
            # 从连接池获取
            try:
                conn = self._pool.get(timeout=2)
            except Empty:
                conn = self._create_new_connection()
                self._load_extensions(conn)
            
            conn.execute("PRAGMA foreign_keys = ON")
            yield conn
            
        except Exception as e:
            if conn:
                conn.rollback()
            raise e
        finally:
            if conn:
                conn.commit()
                # 归还连接池
                if not self._pool.full():
                    self._pool.put(conn)

    def return_connection(self, conn):
        """DEPRECATED: 不再需要手动归还连接，使用 get_connection() 上下文管理器"""
        import warnings
        warnings.warn(
            "return_connection is deprecated, use 'with self.get_connection() as conn:' instead",
            DeprecationWarning,
            stacklevel=2
        )
        if self._pool.full():
            conn.close()
        else:
            self._pool.put(conn)

    def close_all(self):
        print(f"[*] Closing {self._pool.qsize()} database connections...")
        while not self._pool.empty():
            try:
                conn = self._pool.get_nowait()
                conn.close()
            except Empty:
                break

    def init_db(self):
        conn = self._create_new_connection()
        try:
            cursor = conn.cursor()

            cursor.execute("""CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                workspace_path TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS columns (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                position INTEGER NOT NULL,
                color TEXT DEFAULT '#808080',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS cards (
                id TEXT PRIMARY KEY,
                column_id TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                position INTEGER NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (column_id) REFERENCES columns(id) ON DELETE CASCADE
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS card_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                card_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
                content TEXT,
                metadata TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS project_timeline (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                card_id TEXT,
                event_type TEXT NOT NULL,
                content TEXT,
                metadata TEXT,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS summaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                card_id TEXT NOT NULL UNIQUE,
                summary TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS project_agent_status (
                project_id TEXT PRIMARY KEY,
                state TEXT NOT NULL DEFAULT 'idle',
                start_time DATETIME,
                last_message TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            )""")

            cursor.execute("""CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                updated_at DATETIME
            )""")

            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_cards_column ON cards(column_id)"
            )
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_columns_project ON columns(project_id)"
            )
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_card ON card_sessions(card_id)"
            )
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_timeline_project ON project_timeline(project_id)"
            )
            cursor.execute(
                "CREATE INDEX IF NOT EXISTS idx_timeline_timestamp ON project_timeline(timestamp DESC)"
            )

            conn.commit()
        finally:
            conn.close()

    def migrate(self):
        conn = self._create_new_connection()
        try:
            cursor = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
            )
            if not cursor.fetchone():
                return

            cursor = conn.execute("SELECT MAX(version) FROM schema_version")
            row = cursor.fetchone()
            current_version = row[0] if row and row[0] else 0

            if current_version < 2:
                conn.execute("PRAGMA journal_mode = WAL")
                conn.commit()

                cursor.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(
                    title,
                    description,
                    content='cards',
                    content_rowid='rowid'
                )""")

                cursor.execute("""CREATE TRIGGER IF NOT EXISTS cards_ai AFTER INSERT ON cards BEGIN
                    INSERT INTO cards_fts(title, description)
                    VALUES (new.title, new.description);
                END""")

                cursor.execute("""CREATE TRIGGER IF NOT EXISTS cards_ad AFTER DELETE ON cards BEGIN
                    INSERT INTO cards_fts(cards_fts, title, description)
                    VALUES ('delete', old.title, old.description);
                END""")

                cursor.execute("""CREATE TRIGGER IF NOT EXISTS cards_au AFTER UPDATE ON cards BEGIN
                    INSERT INTO cards_fts(cards_fts, title, description)
                    VALUES ('delete', old.title, old.description);
                    INSERT INTO cards_fts(title, description)
                    VALUES (new.title, new.description);
                END""")

                cursor.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
                    content,
                    content='card_sessions',
                    content_rowid='rowid'
                )""")

                try:
                    cursor.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS card_vectors USING vec0(
                        card_id TEXT PRIMARY KEY,
                        embedding FLOAT[1536]
                    )""")
                    cursor.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS session_vectors USING vec0(
                        session_id INTEGER PRIMARY KEY,
                        embedding FLOAT[1536]
                    )""")
                except Exception:
                    pass

                conn.execute(
                    "INSERT OR REPLACE INTO schema_version (version, updated_at) VALUES (2, ?)",
                    (datetime.now().isoformat(),),
                )
                conn.commit()

            if current_version < 3:
                cursor.execute("""CREATE TABLE IF NOT EXISTS project_agent_status (
                    project_id TEXT PRIMARY KEY,
                    state TEXT NOT NULL DEFAULT 'idle',
                    start_time DATETIME,
                    last_message TEXT,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )""")

                conn.execute(
                    "INSERT OR REPLACE INTO schema_version (version, updated_at) VALUES (3, ?)",
                    (datetime.now().isoformat(),),
                )
                conn.commit()
        finally:
            conn.close()

    def create_project(self, name: str, workspace_path: str = None) -> str:
        project_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        
        with self.get_connection() as conn:
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

    def get_projects(self) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                """SELECT p.*,
                    (SELECT COUNT(*) FROM cards c
                     JOIN columns col ON col.id = c.column_id
                     WHERE col.project_id = p.id) as card_count
                FROM projects p
                ORDER BY p.updated_at DESC"""
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_project(self, project_id: str) -> Optional[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM projects WHERE id = ?", (project_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def update_project(
        self, project_id: str, name: str = None, workspace_path: str = None
    ):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
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

    def delete_project(self, project_id: str):
        with self.get_connection() as conn:
            conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))

    def get_project_agent_status(self, project_id: str) -> Optional[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT * FROM project_agent_status WHERE project_id = ?",
                (project_id,),
            )
            row = cursor.fetchone()
            return dict(row) if row else None

    def update_project_agent_status(
        self,
        project_id: str,
        state: str,
        start_time: str = None,
        last_message: str = None,
    ):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute(
                """INSERT INTO project_agent_status (project_id, state, start_time, last_message, updated_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(project_id) DO UPDATE SET
                   state = excluded.state,
                   start_time = excluded.start_time,
                   last_message = excluded.last_message,
                   updated_at = excluded.updated_at""",
                (project_id, state, start_time, last_message, now),
            )

    def get_all_agent_statuses(self) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                """SELECT ps.*, p.name as project_name FROM project_agent_status ps
                   JOIN projects p ON p.id = ps.project_id
                   WHERE ps.state != 'idle'"""
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_columns(self, project_id: str) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT c.*, COUNT(cards.id) as card_count FROM columns c LEFT JOIN cards ON cards.column_id = c.id WHERE c.project_id = ? GROUP BY c.id ORDER BY c.position",
                (project_id,),
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_column(self, column_id: str) -> Optional[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM columns WHERE id = ?", (column_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def create_column(
        self, project_id: str, name: str, position: int = None, color: str = "#808080"
    ) -> str:
        with self._locks_lock:
            if project_id not in self._column_locks:
                self._column_locks[project_id] = threading.Lock()

        with self._column_locks[project_id]:
            column_id = str(uuid.uuid4())[:8]
            now = datetime.now().isoformat()
            
            with self.get_connection() as conn:
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

                try:
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, event_type, content, timestamp) VALUES (?, ?, ?, ?)",
                        (project_id, "column_created", f"Column '{name}' created", now),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")
                
                return column_id

    def update_column(self, column_id: str, name: str = None, color: str = None):
        now = datetime.now().isoformat()
        
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT project_id, name, color FROM columns WHERE id = ?", (column_id,)
            )
            row = cursor.fetchone()
            if not row:
                return

            project_id, old_name, old_color = row[0], row[1], row[2]
            changes = {}

            if name is not None and name != old_name:
                conn.execute(
                    "UPDATE columns SET name = ? WHERE id = ?", (name, column_id)
                )
                changes["name"] = {"old": old_name, "new": name}
            if color is not None and color != old_color:
                conn.execute(
                    "UPDATE columns SET color = ? WHERE id = ?", (color, column_id)
                )
                changes["color"] = {"old": old_color, "new": color}

            if changes:
                try:
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (
                            project_id,
                            "column_updated",
                            f"Column '{old_name}' updated",
                            json.dumps(changes),
                            now,
                        ),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")

    def delete_column(self, column_id: str, move_to_column_id: str = None):
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT project_id, name FROM columns WHERE id = ?", (column_id,)
            )
            row = cursor.fetchone()
            if not row:
                return

            project_id, col_name = row[0], row[1]

        with self._locks_lock:
            if project_id not in self._column_locks:
                self._column_locks[project_id] = threading.Lock()

        with self._column_locks[project_id]:
            now = datetime.now().isoformat()
            with self.get_connection() as conn:
                metadata = {"column_name": col_name}
                if move_to_column_id:
                    conn.execute(
                        "UPDATE cards SET column_id = ? WHERE column_id = ?",
                        (move_to_column_id, column_id),
                    )
                    cursor = conn.execute(
                        "SELECT name FROM columns WHERE id = ?", (move_to_column_id,)
                    )
                    target_row = cursor.fetchone()
                    if target_row:
                        metadata["moved_cards_to"] = target_row[0]

                conn.execute("DELETE FROM columns WHERE id = ?", (column_id,))

                try:
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (
                            project_id,
                            "column_deleted",
                            f"Column '{col_name}' deleted",
                            json.dumps(metadata),
                            now,
                        ),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")

    def reorder_columns(self, positions: List[Dict[str, Any]]):
        if not positions:
            return

        project_id = positions[0].get("project_id")
        if not project_id:
            with self.get_connection() as conn:
                cursor = conn.execute(
                    "SELECT project_id FROM columns WHERE id = ?", (positions[0]["id"],)
                )
                row = cursor.fetchone()
                if row:
                    project_id = row[0]

        if not project_id:
            return

        with self._locks_lock:
            if project_id not in self._column_locks:
                self._column_locks[project_id] = threading.Lock()

        with self._column_locks[project_id]:
            now = datetime.now().isoformat()
            with self.get_connection() as conn:
                reordered_ids = [p["id"] for p in positions]
                try:
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (
                            project_id,
                            "columns_reordered",
                            "Column order updated",
                            json.dumps({"column_ids": reordered_ids}),
                            now,
                        ),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")

                for item in positions:
                    col_id = item["id"]
                    position = item["position"]
                    conn.execute(
                        "UPDATE columns SET position = ? WHERE id = ?",
                        (position, col_id),
                    )

    def get_cards_by_column(self, column_id: str) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT c.*, (SELECT COUNT(*) FROM card_sessions WHERE card_id = c.id) as session_count FROM cards c WHERE c.column_id = ? ORDER BY c.position",
                (column_id,),
            )
            return [dict(row) for row in cursor.fetchall()]

    def get_card(self, card_id: str) -> Optional[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT c.*, col.name as column_name, col.project_id FROM cards c JOIN columns col ON col.id = c.column_id WHERE c.id = ?",
                (card_id,),
            )
            row = cursor.fetchone()
            return dict(row) if row else None

    def create_card(
        self, column_id: str, title: str, description: str = "", position: int = None
    ) -> str:
        card_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        
        with self.get_connection() as conn:
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

            cursor = conn.execute(
                "SELECT project_id FROM columns WHERE id = ?", (column_id,)
            )
            row = cursor.fetchone()
            if row:
                try:
                    project_id = row[0]
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, card_id, event_type, content, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (
                            project_id,
                            card_id,
                            "card_created",
                            f"Card '{title}' created",
                            now,
                        ),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")

            return card_id

    def update_card(self, card_id: str, title: str = None, description: str = None):
        now = datetime.now().isoformat()
        
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT column_id FROM cards WHERE id = ?", (card_id,)
            )
            row = cursor.fetchone()
            if not row:
                return

            if title is not None:
                conn.execute(
                    "UPDATE cards SET title = ?, updated_at = ? WHERE id = ?",
                    (title, now, card_id),
                )
            if description is not None:
                conn.execute(
                    "UPDATE cards SET description = ?, updated_at = ? WHERE id = ?",
                    (description, now, card_id),
                )

            cursor = conn.execute(
                "SELECT project_id FROM columns WHERE id = ?", (row[0],)
            )
            proj_row = cursor.fetchone()
            if proj_row:
                try:
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, card_id, event_type, content, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (proj_row[0], card_id, "card_updated", "Card updated", now),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")

    def delete_card(self, card_id: str):
        now = datetime.now().isoformat()
        
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT column_id, title FROM cards WHERE id = ?", (card_id,)
            )
            row = cursor.fetchone()
            if not row:
                return

            column_id, title = row[0], row[1]

            conn.execute("DELETE FROM cards WHERE id = ?", (card_id,))

            cursor = conn.execute(
                "SELECT project_id FROM columns WHERE id = ?", (column_id,)
            )
            proj_row = cursor.fetchone()
            if proj_row:
                try:
                    conn.execute(
                        "INSERT INTO project_timeline (project_id, card_id, event_type, content, timestamp) VALUES (?, ?, ?, ?, ?)",
                        (
                            proj_row[0],
                            card_id,
                            "card_deleted",
                            f"Card '{title}' deleted",
                            now,
                        ),
                    )
                except Exception as e:
                    import logging
                    logging.warning(f"Failed to insert timeline event: {e}")

    def move_card(
        self, card_id: str, target_column_id: str, target_position: int = None
    ):
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT c.column_id, col1.project_id as source_project, col2.project_id as target_project "
                "FROM cards c "
                "JOIN columns col1 ON col1.id = c.column_id "
                "JOIN columns col2 ON col2.id = ? "
                "WHERE c.id = ?",
                (target_column_id, card_id),
            )
            row = cursor.fetchone()
            if not row:
                return
            source_column_id, source_project, target_project = row[0], row[1], row[2]

            if source_project != target_project:
                raise Exception("Cannot move card between different projects")

            project_id = target_project

        with self._locks_lock:
            if project_id not in self._column_locks:
                self._column_locks[project_id] = threading.Lock()

        with self._column_locks[project_id]:
            now = datetime.now().isoformat()
            with self.get_connection() as conn:
                cursor = conn.execute(
                    "SELECT column_id, title FROM cards WHERE id = ?", (card_id,)
                )
                row = cursor.fetchone()
                if not row:
                    return
                source_column_id, title = row[0], row[1]

                if target_position is None:
                    cursor = conn.execute(
                        "SELECT MAX(position) FROM cards WHERE column_id = ?",
                        (target_column_id,),
                    )
                    row = cursor.fetchone()
                    target_position = (row[0] + 1) if row[0] is not None else 0

                conn.execute(
                    "UPDATE cards SET column_id = ?, position = ?, updated_at = ? WHERE id = ?",
                    (target_column_id, target_position, now, card_id),
                )

                cursor = conn.execute(
                    "SELECT col1.name, col2.name, col1.project_id FROM columns col1, columns col2 WHERE col1.id = ? AND col2.id = ?",
                    (source_column_id, target_column_id),
                )
                row = cursor.fetchone()
                if row:
                    source_name, target_name, project_id = row[0], row[1], row[2]
                    try:
                        conn.execute(
                            "INSERT INTO project_timeline (project_id, card_id, event_type, content, timestamp) VALUES (?, ?, ?, ?, ?)",
                            (
                                project_id,
                                card_id,
                                "card_moved",
                                f"Card moved from '{source_name}' to '{target_name}'",
                                now,
                            ),
                        )
                    except Exception as e:
                        import logging
                        logging.warning(f"Failed to insert timeline event: {e}")

    def add_session_message(
        self, card_id: str, role: str, content: str, metadata: Dict = None
    ):
        now = datetime.now().isoformat()
        
        with self.get_connection() as conn:
            conn.execute(
                "INSERT INTO card_sessions (card_id, role, content, metadata, created_at) VALUES (?, ?, ?, ?, ?)",
                (
                    card_id,
                    role,
                    content,
                    json.dumps(metadata) if metadata else None,
                    now,
                ),
            )

            cursor = conn.execute(
                "SELECT column_id FROM cards WHERE id = ?", (card_id,)
            )
            row = cursor.fetchone()
            if row:
                cursor = conn.execute(
                    "SELECT project_id FROM columns WHERE id = ?", (row[0],)
                )
                proj_row = cursor.fetchone()
                if proj_row:
                    display_content = (
                        f"[{role}] {content[:100]}"
                        if len(content) > 100
                        else f"[{role}] {content}"
                    )
                    try:
                        conn.execute(
                            "INSERT INTO project_timeline (project_id, card_id, event_type, content, timestamp) VALUES (?, ?, ?, ?, ?)",
                            (
                                proj_row[0],
                                card_id,
                                "ai_action" if role == "assistant" else "user_message",
                                display_content,
                                now,
                            ),
                        )
                    except Exception as e:
                        import logging
                        logging.warning(f"Failed to insert timeline event: {e}")

            conn.execute(
                """
                DELETE FROM card_sessions
                WHERE card_id = ? AND id NOT IN (
                    SELECT id FROM card_sessions
                    WHERE card_id = ?
                    ORDER BY created_at DESC
                    LIMIT ?
                )
            """,
                (card_id, card_id, MAX_SESSION_MESSAGES_PER_CARD),
            )

    def get_session_history(self, card_id: str, limit: int = 50) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT * FROM card_sessions WHERE card_id = ? ORDER BY created_at ASC LIMIT ?",
                (card_id, limit),
            )
            return [dict(row) for row in cursor.fetchall()]

    def add_timeline_event(
        self,
        project_id: str,
        card_id: str,
        event_type: str,
        content: str,
        metadata: Dict = None,
    ):
        with self.get_connection() as conn:
            conn.execute(
                "INSERT INTO project_timeline (project_id, card_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    project_id,
                    card_id,
                    event_type,
                    content,
                    json.dumps(metadata) if metadata else None,
                    datetime.now().isoformat(),
                ),
            )

    def get_timeline(self, project_id: str, limit: int = 100) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                """SELECT t.*, c.title as card_title
                   FROM project_timeline t
                   LEFT JOIN cards c ON c.id = t.card_id
                   WHERE t.project_id = ?
                   ORDER BY t.timestamp DESC
                   LIMIT ?""",
                (project_id, limit),
            )
            return [dict(row) for row in cursor.fetchall()]

    def search_cards_fts(
        self, query: str, project_id: str = None, limit: int = 20
    ) -> List[Dict]:
        with self.get_connection() as conn:
            if project_id:
                sql = """
                    SELECT c.*, col.name as column_name FROM cards c
                    JOIN columns col ON col.id = c.column_id
                    JOIN cards_fts fts ON fts.rowid = c.rowid
                    WHERE cards_fts MATCH ? AND col.project_id = ?
                    ORDER BY rank LIMIT ?
                """
                cursor = conn.execute(sql, (query, project_id, limit))
            else:
                sql = """
                    SELECT c.*, col.name as column_name FROM cards c
                    JOIN columns col ON col.id = c.column_id
                    JOIN cards_fts fts ON fts.rowid = c.rowid
                    WHERE cards_fts MATCH ?
                    ORDER BY rank LIMIT ?
                """
                cursor = conn.execute(sql, (query, limit))
            return [dict(row) for row in cursor.fetchall()]

    def search_cards_semantic(
        self, embedding: List[float], project_id: str = None, limit: int = 5
    ) -> List[Dict]:
        with self.get_connection() as conn:
            try:
                if project_id:
                    sql = """
                        SELECT c.*, col.name as column_name,
                            vec_distance_cosine(card_vectors.embedding, ?) as distance
                        FROM cards c
                        JOIN columns col ON col.id = c.column_id
                        JOIN card_vectors ON card_vectors.card_id = c.id
                        WHERE col.project_id = ?
                        ORDER BY distance LIMIT ?
                    """
                    cursor = conn.execute(sql, (embedding, project_id, limit))
                else:
                    sql = """
                        SELECT c.*, col.name as column_name,
                            vec_distance_cosine(card_vectors.embedding, ?) as distance
                        FROM cards c
                        JOIN columns col ON col.id = c.column_id
                        JOIN card_vectors ON card_vectors.card_id = c.id
                        ORDER BY distance LIMIT ?
                    """
                    cursor = conn.execute(sql, (embedding, limit))
                return [dict(row) for row in cursor.fetchall()]
            except Exception:
                return []

    def upsert_card_embedding(self, card_id: str, embedding: List[float]):
        embedding_json = json.dumps(embedding)
        with self.get_connection() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO card_vectors (card_id, embedding) VALUES (?, ?)",
                (card_id, embedding_json),
            )

    def upsert_session_embedding(self, session_id: int, embedding: List[float]):
        embedding_json = json.dumps(embedding)
        with self.get_connection() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO session_vectors (session_id, embedding) VALUES (?, ?)",
                (session_id, embedding_json),
            )

    def save_summary(self, card_id: str, summary: str):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO summaries (card_id, summary, updated_at) VALUES (?, ?, ?)",
                (card_id, summary, now),
            )

    def get_summary(self, card_id: str) -> Optional[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT * FROM summaries WHERE card_id = ?", (card_id,)
            )
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_all_summaries(self, project_id: str) -> List[Dict]:
        with self.get_connection() as conn:
            cursor = conn.execute(
                "SELECT s.*, c.title FROM summaries s JOIN cards c ON c.id = s.card_id JOIN columns col ON col.id = c.column_id WHERE col.project_id = ? ORDER BY s.updated_at DESC",
                (project_id,),
            )
            return [dict(row) for row in cursor.fetchall()]
