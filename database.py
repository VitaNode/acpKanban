import sqlite3
import uuid
from datetime import datetime

class KanbanDB:
    def __init__(self, db_path="kanban.db"):
        self.db_path = db_path
        self.init_db()
        self.migrate()

    def get_connection(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def init_db(self):
        with self.get_connection() as conn:
            cursor = conn.cursor()
            # Tasks Table
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
            # Timeline Table
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
            # Schema Version Table (Issue 4)
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS schema_version (
                    version INTEGER PRIMARY KEY,
                    updated_at DATETIME
                )
            ''')
            
            # Indexes
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_timeline_task_id ON timeline(task_id)')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)')
            conn.commit()

    def migrate(self):
        # Basic Migration Mechanism (Issue 4)
        version = self.get_db_version()
        with self.get_connection() as conn:
            if version < 1:
                # Initialize version 1
                conn.execute("INSERT OR IGNORE INTO schema_version (version, updated_at) VALUES (1, ?)", 
                             (datetime.now().isoformat(),))
                conn.commit()
            # Add future migrations here: if version < 2: ...

    def get_db_version(self):
        try:
            with self.get_connection() as conn:
                cursor = conn.execute("SELECT version FROM schema_version")
                row = cursor.fetchone()
                return row[0] if row else 0
        except sqlite3.OperationalError:
            return 0

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

    def get_task(self, task_id):
        # Issue 2
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_task_summary(self):
        # Issue 3
        with self.get_connection() as conn:
            cursor = conn.execute("""
                SELECT status, COUNT(*) as count 
                FROM tasks 
                GROUP BY status
            """)
            return {row['status']: row['count'] for row in cursor.fetchall()}

    def update_task_status(self, task_id, status):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT id FROM tasks WHERE id = ?", (task_id,))
            if not cursor.fetchone():
                raise ValueError(f"Task {task_id} not found")
            
            conn.execute(
                "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                (status, now, task_id)
            )
            self._log_event(conn, task_id, "status_change", f"Status changed to {status}")
            conn.commit()

    def bulk_update_status(self, task_ids, status):
        # Issue 5
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            for task_id in task_ids:
                conn.execute(
                    "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                    (status, now, task_id)
                )
                self._log_event(conn, task_id, "bulk_status_change", f"Bulk updated to {status}")
            conn.commit()

    def delete_task(self, task_id):
        # Explicit delete for safety (Issue 1)
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT id FROM tasks WHERE id = ?", (task_id,))
            if not cursor.fetchone():
                raise ValueError(f"Task {task_id} not found")
            
            conn.execute("DELETE FROM timeline WHERE task_id = ?", (task_id,))
            conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
            conn.commit()

    def add_timeline_event(self, task_id, event_type, content):
        with self.get_connection() as conn:
            self._log_event(conn, task_id, event_type, content)
            conn.commit()

    def _log_event(self, conn, task_id, event_type, content):
        now = datetime.now().isoformat()
        conn.execute(
            "INSERT INTO timeline (task_id, event_type, content, timestamp) VALUES (?, ?, ?, ?)",
            (task_id, event_type, content, now)
        )

    def get_all_tasks(self):
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM tasks")
            return [dict(row) for row in cursor.fetchall()]

    def get_task_timeline(self, task_id):
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM timeline WHERE task_id = ? ORDER BY timestamp DESC", (task_id,))
            return [dict(row) for row in cursor.fetchall()]
