import sqlite3
import uuid
from datetime import datetime
from queue import Queue
import threading

class KanbanDB:
    _instance_lock = threading.Lock()
    _pool = None

    def __init__(self, db_path="kanban.db", pool_size=5):
        self.db_path = db_path
        self.init_db()
        self.migrate()

    def get_connection(self):
        # Use a simple connection for now, but ensure PRAGMAs are set
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")  # Better concurrency
        return conn

    def init_db(self):
        with self.get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    description TEXT,
                    status TEXT DEFAULT 'todo',
                    created_at DATETIME,
                    updated_at DATETIME
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS timeline (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT,
                    event_type TEXT,
                    content TEXT,
                    timestamp DATETIME,
                    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS schema_version (
                    version INTEGER PRIMARY KEY,
                    updated_at DATETIME
                )
            ''')
            conn.commit()

    def get_db_version(self):
        try:
            with self.get_connection() as conn:
                cursor = conn.execute("SELECT version FROM schema_version ORDER BY version DESC LIMIT 1")
                row = cursor.fetchone()
                return row[0] if row else 0
        except sqlite3.OperationalError:
            return 0

    def migrate(self):
        version = self.get_db_version()
        with self.get_connection() as conn:
            if version < 1:
                # Version 1 is the initial state
                conn.execute("INSERT OR IGNORE INTO schema_version (version, updated_at) VALUES (1, ?)", 
                             (datetime.now().isoformat(),))
            
            # Future migrations:
            # if version < 2:
            #     conn.execute("ALTER TABLE tasks ADD COLUMN priority INTEGER DEFAULT 0")
            #     conn.execute("UPDATE schema_version SET version = 2, updated_at = ?", (now,))
            
            conn.commit()

    def add_task(self, title, description=""):
        task_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute(
                "INSERT INTO tasks (id, title, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                (task_id, title, description, now, now)
            )
            self._log_event(conn, task_id, "creation", f"Task created: {title}")
            conn.commit()
        return task_id

    def update_task_status(self, task_id, status):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute(
                "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                (status, now, task_id)
            )
            self._log_event(conn, task_id, "status_change", f"Status changed to {status}")
            conn.commit()

    def _log_event(self, conn, task_id, event_type, content):
        now = datetime.now().isoformat()
        conn.execute(
            "INSERT INTO timeline (task_id, event_type, content, timestamp) VALUES (?, ?, ?, ?)",
            (task_id, event_type, content, now)
        )

    def get_all_tasks(self):
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM tasks ORDER BY created_at DESC")
            return [dict(row) for row in cursor.fetchall()]
