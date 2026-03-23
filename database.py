import sqlite3
import uuid
from datetime import datetime
import threading
from queue import Queue, Empty

class KanbanDB:
    _instance_lock = threading.Lock()
    _instance = None

    def __new__(cls, *args, **kwargs):
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = super(KanbanDB, cls).__new__(cls)
            return cls._instance

    def __init__(self, db_path="kanban.db", pool_size=5):
        if hasattr(self, '_initialized'): return
        self.db_path = db_path
        self.pool_size = pool_size
        self._pool = Queue(maxsize=pool_size)
        self._initialized = True
        
        # Initialize schema once
        self.init_db()
        self.migrate()
        
        # Fill pool
        for _ in range(pool_size):
            self._pool.put(self._create_new_connection())

    def _create_new_connection(self):
        conn = sqlite3.connect(self.db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        return conn

    def get_connection(self):
        """Gets a connection from the pool, creating a new one if necessary."""
        try:
            return self._pool.get(timeout=2)
        except Empty:
            return self._create_new_connection()

    def return_connection(self, conn):
        """Returns a connection to the pool."""
        if self._pool.full():
            conn.close()
        else:
            self._pool.put(conn)

    def init_db(self):
        conn = self._create_new_connection()
        try:
            cursor = conn.cursor()
            cursor.execute('''CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT, status TEXT DEFAULT 'todo', created_at DATETIME, updated_at DATETIME)''')
            cursor.execute('''CREATE TABLE IF NOT EXISTS timeline (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, event_type TEXT, content TEXT, timestamp DATETIME, FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE)''')
            cursor.execute('''CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, updated_at DATETIME)''')
            conn.commit()
        finally:
            conn.close()

    def migrate(self):
        # Implementation of multi-version migration
        conn = self._create_new_connection()
        try:
            cursor = conn.execute("SELECT MAX(version) FROM schema_version")
            row = cursor.fetchone()
            current_version = row[0] if row and row[0] else 0
            
            if current_version < 1:
                conn.execute("INSERT INTO schema_version (version, updated_at) VALUES (1, ?)", (datetime.now().isoformat(),))
                conn.commit()
            
            # Placeholder for version 2:
            # if current_version < 2:
            #     conn.execute("ALTER TABLE tasks ADD COLUMN color TEXT")
            #     conn.execute("INSERT INTO schema_version (version, updated_at) VALUES (2, ?)", (datetime.now().isoformat(),))
            #     conn.commit()
        finally:
            conn.close()

    def add_task(self, title, description=""):
        task_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        conn = self.get_connection()
        try:
            conn.execute("INSERT INTO tasks (id, title, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", (task_id, title, description, now, now))
            conn.execute("INSERT INTO timeline (task_id, event_type, content, timestamp) VALUES (?, 'creation', ?, ?)", (task_id, f"Task created: {title}", now))
            conn.commit()
            return task_id
        finally:
            self.return_connection(conn)

    def get_all_tasks(self):
        conn = self.get_connection()
        try:
            cursor = conn.execute("SELECT * FROM tasks ORDER BY created_at DESC")
            return [dict(row) for row in cursor.fetchall()]
        finally:
            self.return_connection(conn)
