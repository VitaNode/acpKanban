import sqlite3
import uuid
import json
import asyncio
import sys
import os
import math
import re
from datetime import datetime
from contextlib import contextmanager
from typing import Optional, List, Dict, Any, Union
import threading
from queue import Queue
from src.logger import setup_logger

logger = setup_logger("KanbanDB")

# Constants for default categories
UNCATEGORIZED_MILESTONE_TITLE = "未分类任务"
DEFAULT_FEATURE_TITLE = "默认功能"

def safe_divide(numerator: Union[int, float], denominator: Union[int, float]) -> float:
    """Safely divide two numbers, returning 0.0 if denominator is zero."""
    if not denominator or denominator == 0:
        return 0.0
    return (float(numerator) / float(denominator)) * 100

class ConnectionPool:
    def __init__(self, connector, max_size=5):
        self._connector = connector
        self._pool = Queue(maxsize=max_size)
        self._lock = threading.Lock()
        self._current_size = 0
        self._max_size = max_size

    def get(self):
        with self._lock:
            if self._pool.empty() and self._current_size < self._max_size:
                conn = self._connector()
                self._current_size += 1
                return conn
        return self._pool.get()

    def put(self, conn):
        try:
            self._pool.put_nowait(conn)
        except:
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
                (SELECT COUNT(*) FROM cards c JOIN columns col ON c.column_id = col.id WHERE col.project_id = p.id AND c.deleted_at IS NULL) as card_count
                FROM projects p WHERE 1=1 ORDER BY created_at DESC
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

    def update_stats(self, project_id: str, index_status: str = None, last_indexed_at: str = None, total_files: int = None, total_symbols: int = None, total_vectorized_symbols: int = None):
        updates = []
        params = []
        if index_status is not None:
            updates.append("index_status = ?")
            params.append(index_status)
        if last_indexed_at is not None:
            updates.append("last_indexed_at = ?")
            params.append(last_indexed_at)
        if total_files is not None:
            updates.append("total_files = ?")
            params.append(total_files)
        if total_symbols is not None:
            updates.append("total_symbols = ?")
            params.append(total_symbols)
        if total_vectorized_symbols is not None:
            updates.append("total_vectorized_symbols = ?")
            params.append(total_vectorized_symbols)
        
        if not updates:
            return

        params.append(project_id)
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE projects SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, project_id: str):
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                # 1. Delete dependent project data in order of constraints
                
                # Delete project agent status
                conn.execute("DELETE FROM project_agent_status WHERE project_id = ?", (project_id,))
                
                # Delete timeline events
                conn.execute("DELETE FROM project_timeline WHERE project_id = ?", (project_id,))
                
                # Delete file index and code symbols
                conn.execute("DELETE FROM file_index WHERE project_id = ?", (project_id,))
                conn.execute("DELETE FROM code_symbols WHERE project_id = ?", (project_id,))
                
                # Delete card sessions and summaries for all cards in this project
                conn.execute("""
                    DELETE FROM card_sessions WHERE card_id IN (
                        SELECT c.id FROM cards c 
                        JOIN columns col ON c.column_id = col.id 
                        WHERE col.project_id = ?
                    )
                """, (project_id,))
                
                conn.execute("""
                    DELETE FROM summaries WHERE card_id IN (
                        SELECT c.id FROM cards c 
                        JOIN columns col ON c.column_id = col.id 
                        WHERE col.project_id = ?
                    )
                """, (project_id,))
                
                conn.execute("""
                    DELETE FROM summary_history WHERE card_id IN (
                        SELECT c.id FROM cards c 
                        JOIN columns col ON c.column_id = col.id 
                        WHERE col.project_id = ?
                    )
                """, (project_id,))
                
                # Delete cards
                conn.execute("""
                    DELETE FROM cards WHERE column_id IN (
                        SELECT id FROM columns WHERE project_id = ?
                    )
                """, (project_id,))
                
                # Delete features and milestones
                conn.execute("""
                    DELETE FROM features WHERE milestone_id IN (
                        SELECT id FROM milestones WHERE project_id = ?
                    )
                """, (project_id,))
                conn.execute("DELETE FROM milestones WHERE project_id = ?", (project_id,))
                
                # Delete columns
                conn.execute("DELETE FROM columns WHERE project_id = ?", (project_id,))
                
                # 2. Finally delete the project itself
                conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))
                
                conn.execute("COMMIT")
            except Exception as e:
                conn.execute("ROLLBACK")
                logger.error(f"Failed to delete project {project_id}: {e}")
                raise

class MilestoneRepository(BaseRepository):
    def create(self, project_id: str, title: str, description: str = None, target_date: str = None) -> str:
        m_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT MAX(order_index) FROM milestones WHERE project_id = ?", (project_id,))
            max_idx = cursor.fetchone()[0]
            order_index = (max_idx + 1) if max_idx is not None else 0
            conn.execute("""
                INSERT INTO milestones (id, project_id, title, description, target_date, status, order_index, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (m_id, project_id, title, description, target_date, 'active', order_index, now))
            return m_id

    def get_by_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM milestones WHERE project_id = ? AND deleted_at IS NULL ORDER BY order_index", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def update(self, m_id: str, title: str = None, description: str = None, status: str = None, target_date: str = None):
        updates = []
        params = []
        if title: updates.append("title = ?"); params.append(title)
        if description: updates.append("description = ?"); params.append(description)
        if status: updates.append("status = ?"); params.append(status)
        if target_date: updates.append("target_date = ?"); params.append(target_date)
        if not updates: return
        params.append(m_id)
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE milestones SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, m_id: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                # Soft delete milestone
                conn.execute("UPDATE milestones SET deleted_at = ? WHERE id = ?", (now, m_id))
                # Soft delete related features
                conn.execute("UPDATE features SET deleted_at = ? WHERE milestone_id = ?", (now, m_id))
                # Soft delete related cards
                conn.execute("""
                    UPDATE cards SET deleted_at = ? WHERE feature_id IN (
                        SELECT id FROM features WHERE milestone_id = ?
                    )
                """, (now, m_id))
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

class FeatureRepository(BaseRepository):
    def create(self, milestone_id: str, title: str, description: str = None) -> str:
        f_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT MAX(order_index) FROM features WHERE milestone_id = ?", (milestone_id,))
            max_idx = cursor.fetchone()[0]
            order_index = (max_idx + 1) if max_idx is not None else 0
            conn.execute("""
                INSERT INTO features (id, milestone_id, title, description, status, order_index, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (f_id, milestone_id, title, description, 'active', order_index, now))
            return f_id

    def get_by_milestone(self, milestone_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM features WHERE milestone_id = ? AND deleted_at IS NULL ORDER BY order_index", (milestone_id,))
            return [dict(row) for row in cursor.fetchall()]

    def update(self, f_id: str, title: str = None, description: str = None, status: str = None):
        updates = []
        params = []
        if title: updates.append("title = ?"); params.append(title)
        if description: updates.append("description = ?"); params.append(description)
        if status: updates.append("status = ?"); params.append(status)
        if not updates: return
        params.append(f_id)
        with self.db.get_connection() as conn:
            conn.execute(f"UPDATE features SET {', '.join(updates)} WHERE id = ?", params)

    def delete(self, f_id: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute("UPDATE features SET deleted_at = ? WHERE id = ?", (now, f_id))
                conn.execute("UPDATE cards SET deleted_at = ? WHERE feature_id = ?", (now, f_id))
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

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
            conn.execute("BEGIN IMMEDIATE")
            try:
                if move_to_column_id:
                    conn.execute("UPDATE cards SET column_id = ? WHERE column_id = ?", (move_to_column_id, column_id))
                else:
                    conn.execute("DELETE FROM cards WHERE column_id = ?", (column_id,))
                conn.execute("DELETE FROM columns WHERE id = ?", (column_id,))
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def reorder(self, positions: List[Dict[str, Any]]):
        with self.db.get_connection() as conn:
            for item in positions:
                conn.execute("UPDATE columns SET position = ? WHERE id = ?", (item["position"], item["id"]))

class CardRepository(BaseRepository):
    def create(self, column_id: str, title: str, description: str = None, parent_id: str = None, feature_id: str = None) -> str:
        card_id = str(uuid.uuid4())[:8]
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT MAX(position) FROM cards WHERE column_id = ?", (column_id,))
            max_pos = cursor.fetchone()[0]
            position = (max_pos + 1) if max_pos is not None else 0
            conn.execute("""
                INSERT INTO cards (id, column_id, title, description, position, parent_id, feature_id, plan_status, created_at, updated_at) 
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (card_id, column_id, title, description, position, parent_id, feature_id, 'plan', now, now))
            return card_id

    def get_by_id(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT c.*, col.project_id, col.name as column_name,
                (SELECT COUNT(*) FROM card_sessions WHERE card_id = c.id) as session_count
                FROM cards c 
                JOIN columns col ON col.id = c.column_id 
                WHERE c.id = ? AND c.deleted_at IS NULL
            """, (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_by_column(self, column_id: str, include_completed: bool = False) -> List[Dict]:
        query = """
            SELECT c.*, 
            (SELECT COUNT(*) FROM card_sessions cs WHERE cs.card_id = c.id) as session_count
            FROM cards c WHERE c.column_id = ? AND c.deleted_at IS NULL
        """
        params = [column_id]
        if not include_completed:
            query += " AND status != 'completed'"
        query += " ORDER BY position ASC"
        
        with self.db.get_connection() as conn:
            cursor = conn.execute(query, params)
            return [dict(row) for row in cursor.fetchall()]

    def update(self, card_id: str, title: str = None, description: str = None, status: str = None, feature_id: str = None):
        updates = []
        params = []
        
        # SECURITY: Define whitelist for SQL generation to prevent injection via column names
        # Logic here manually appends hardcoded field names to 'updates' list
        if title is not None:
            updates.append("title = ?"); params.append(title)
        if description is not None:
            updates.append("description = ?"); params.append(description)
        if feature_id is not None:
            updates.append("feature_id = ?"); params.append(feature_id)
        
        if status is not None:
            updates.append("status = ?")
            params.append(status)
            if status == 'completed':
                updates.append("completed_at = ?")
                params.append(datetime.now().isoformat())
                updates.append("plan_status = ?")
                params.append('completed')
            else:
                updates.append("completed_at = NULL")
                # When reactivating, session-based sync is handled below within the same connection
        
        if not updates:
            return

        updates.append("updated_at = ?")
        params.append(datetime.now().isoformat())
        params.append(card_id)

        with self.db.get_connection() as conn:
            # Sync plan_status if status was updated to active/reactivated
            if status and status != 'completed':
                cursor = conn.execute("SELECT acp_session_id FROM cards WHERE id = ?", (card_id,))
                row = cursor.fetchone()
                session_id = row['acp_session_id'] if row else None
                updates.append("plan_status = ?")
                params.insert(-1, 'active' if session_id else 'plan')

            # Column names are from hardcoded list above, values are parametrized. Safe from SQLi.
            sql = f"UPDATE cards SET {', '.join(updates)} WHERE id = ?"
            conn.execute(sql, params)

    def delete(self, card_id: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET deleted_at = ? WHERE id = ?", (now, card_id))

    def move(self, card_id: str, target_column_id: str, target_position: int = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                # 1. Get current state of the card
                cursor = conn.execute("SELECT column_id, position FROM cards WHERE id = ?", (card_id,))
                row = cursor.fetchone()
                if not row:
                    return
                
                old_column_id = row['column_id']
                old_position = row['position']

                # 2. Determine target position if not provided
                if target_position is None:
                    cursor = conn.execute("SELECT MAX(position) FROM cards WHERE column_id = ?", (target_column_id,))
                    max_pos = cursor.fetchone()[0]
                    target_position = (max_pos + 1) if max_pos is not None else 0

                # 3. Handle shifting logic
                if old_column_id == target_column_id:
                    if old_position < target_position:
                        conn.execute("UPDATE cards SET position = position - 1 WHERE column_id = ? AND position > ? AND position <= ? AND deleted_at IS NULL", (target_column_id, old_position, target_position))
                    elif old_position > target_position:
                        conn.execute("UPDATE cards SET position = position + 1 WHERE column_id = ? AND position >= ? AND position < ? AND deleted_at IS NULL", (target_column_id, target_position, old_position))
                else:
                    conn.execute("UPDATE cards SET position = position - 1 WHERE column_id = ? AND position > ? AND deleted_at IS NULL", (old_column_id, old_position))
                    conn.execute("UPDATE cards SET position = position + 1 WHERE column_id = ? AND position >= ? AND deleted_at IS NULL", (target_column_id, target_position))

                # 4. Final update
                conn.execute("UPDATE cards SET column_id = ?, position = ?, updated_at = ? WHERE id = ?", (target_column_id, target_position, now, card_id))
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

    def update_provider(self, card_id: str, provider_id: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET acp_provider_id = ? WHERE id = ?", (provider_id, card_id))

    def update_session_id(self, card_id: str, session_id: str):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT plan_status FROM cards WHERE id = ?", (card_id,))
            row = cursor.fetchone()
            current_plan_status = row['plan_status'] if row else 'plan'
            
            new_plan_status = current_plan_status
            if current_plan_status != 'completed':
                new_plan_status = 'active' if session_id else 'plan'

            conn.execute("UPDATE cards SET acp_session_id = ?, plan_status = ?, updated_at = ? WHERE id = ?", (session_id, new_plan_status, now, card_id))

    def get_progress_stats(self, project_id: str, depth: int = 3) -> List[Dict]:
        """
        Fetches progress tree using optimized single-query JOIN.
        Respects 'depth' parameter (1: M, 2: +F, 3: +C).
        """
        with self.db.get_connection() as conn:
            query = """
                SELECT 
                    m.id as m_id, m.project_id, m.title as m_title, m.description as m_desc, m.status as m_status, m.target_date as m_target,
                    f.id as f_id, f.milestone_id, f.title as f_title, f.description as f_desc, f.status as f_status,
                    c.id as c_id, c.title as c_title, c.plan_status
                FROM milestones m
                LEFT JOIN features f ON f.milestone_id = m.id AND f.deleted_at IS NULL
                LEFT JOIN cards c ON c.feature_id = f.id AND c.deleted_at IS NULL
                WHERE m.project_id = ? AND m.deleted_at IS NULL
                ORDER BY m.order_index, f.order_index, c.position
            """
            cursor = conn.execute(query, (project_id,))
            rows = cursor.fetchall()
            
            milestones = {}
            for row in rows:
                mid = row['m_id']
                if mid not in milestones:
                    milestones[mid] = {
                        'id': mid, 
                        'project_id': row['project_id'],
                        'title': row['m_title'], 
                        'description': row['m_desc'],
                        'status': row['m_status'], 
                        'target_date': row['m_target'], 
                        'progress': 0.0, 'features': [],
                        '_features': {}, '_total': 0, '_done': 0
                    }
                
                m = milestones[mid]
                if depth < 2: continue
                
                fid = row['f_id']
                if fid:
                    if fid not in m['_features']:
                        m['_features'][fid] = {
                            'id': fid, 
                            'milestone_id': row['milestone_id'], 
                            'title': row['f_title'], 
                            'description': row['f_desc'],
                            'status': row['f_status'], 
                            'progress': 0.0, 
                            'cards': [],
                            'counts': {'plan': 0, 'active': 0, 'completed': 0}
                        }
                        m['features'].append(m['_features'][fid])
                    
                    f = m['_features'][fid]
                    cid = row['c_id']
                    if cid:
                        p_status = row['plan_status'] or 'plan'
                        f['counts'][p_status] += 1
                        m['_total'] += 1
                        if p_status == 'completed': m['_done'] += 1
                        if depth >= 3:
                            f['cards'].append({'id': cid, 'title': row['c_title'], 'plan_status': p_status})

            result = []
            for m in milestones.values():
                for f in m['features']:
                    f_total = sum(f['counts'].values())
                    f['progress'] = safe_divide(f['counts']['completed'], f_total)
                m['progress'] = safe_divide(m['_done'], m['_total'])
                del m['_features']; del m['_total']; del m['_done']
                result.append(m)
            return result

    def update_config_options(self, card_id: str, config_options: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET config_options = ? WHERE id = ?", (config_options, card_id))

    def update_available_commands(self, card_id: str, available_commands: str):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET available_commands = ? WHERE id = ?", (available_commands, card_id))

    def update_token_usage(self, card_id: str, input_tokens: int, output_tokens: int):
        logger.debug(f"[DB] Updating token usage for {card_id}: +↑{input_tokens} +↓{output_tokens}")
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET input_tokens = input_tokens + ?, output_tokens = output_tokens + ? WHERE id = ?", (input_tokens, output_tokens, card_id))

    def update_card_embedding(self, card_id: str, embedding: List[float]):
        with self.db.get_connection() as conn:
            conn.execute("UPDATE cards SET embedding = ? WHERE id = ?", (json.dumps(embedding), card_id))

    def get_config_options(self, card_id: str) -> Optional[str]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT config_options FROM cards WHERE id = ?", (card_id,))
            row = cursor.fetchone()
            return row[0] if row else None

    def get_available_commands(self, card_id: str) -> Optional[str]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT available_commands FROM cards WHERE id = ?", (card_id,))
            row = cursor.fetchone()
            return row[0] if row else None

class SummaryRepository(BaseRepository):
    def upsert(self, card_id: str, summary: str, embedding: str = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            # Check if summary actually changed before recording history
            cursor = conn.execute("SELECT summary FROM summaries WHERE card_id = ?", (card_id,))
            row = cursor.fetchone()
            existing_summary = row[0] if row else None
            
            conn.execute("""
                INSERT INTO summaries (card_id, summary, embedding, updated_at) 
                VALUES (?, ?, ?, ?)
                ON CONFLICT(card_id) DO UPDATE SET summary=excluded.summary, embedding=excluded.embedding, updated_at=excluded.updated_at
            """, (card_id, summary, embedding, now))
            
            if summary and summary != existing_summary:
                conn.execute("INSERT INTO summary_history (card_id, summary, created_at) VALUES (?, ?, ?)", (card_id, summary, now))

    def get(self, card_id: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM summaries WHERE card_id = ?", (card_id,))
            row = cursor.fetchone()
            return dict(row) if row else None

    def search_semantic(self, query_vector: List[float], project_id: str, limit: int = 5) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT s.card_id, s.summary, s.embedding, c.title
                FROM summaries s
                JOIN cards c ON s.card_id = c.id
                JOIN columns col ON c.column_id = col.id
                WHERE col.project_id = ?
            """, (project_id,))
            rows = cursor.fetchall()
            results = []
            for row in rows:
                if row['embedding']:
                    try:
                        emb = json.loads(row['embedding'])
                        dist = math.sqrt(sum((a - b) ** 2 for a, b in zip(query_vector, emb)))
                        results.append({'card_id': row['card_id'], 'summary': row['summary'], 'title': row['title'], 'distance': dist})
                    except: continue
            results.sort(key=lambda x: x['distance'])
            return results[:limit]

class SessionRepository(BaseRepository):
    def get_incomplete_messages(self, card_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT id, role, content, metadata FROM card_sessions WHERE card_id = ? AND is_complete = 0",
                (card_id,)
            )
            rows = cursor.fetchall()
            return [dict(row) for row in rows]

    def update_message_metadata(self, msg_id: int, metadata: Dict):
        with self.db.get_connection() as conn:
            conn.execute(
                "UPDATE card_sessions SET metadata = ?, is_complete = 1 WHERE id = ?",
                (json.dumps(metadata), msg_id)
            )

    def mark_complete(self, card_id: str):
        with self.db.get_connection() as conn:
            conn.execute(
                "UPDATE card_sessions SET is_complete = 1 WHERE card_id = ? AND role = 'assistant' AND is_complete = 0",
                (card_id,)
            )

    def get_max_seq_id(self, card_id: str) -> int:
        with self.db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT MAX(seq_id) FROM card_sessions WHERE card_id = ?",
                (card_id,)
            )
            row = cursor.fetchone()
            return row[0] if row and row[0] is not None else 0

    def add_message(self, *args, **kwargs):
        # Flexible signature to avoid TypeError: (card_id, role, content, metadata=None, is_milestone=False, ...)
        card_id = args[0] if len(args) > 0 else kwargs.get('card_id')
        role = args[1] if len(args) > 1 else kwargs.get('role')
        content = args[2] if len(args) > 2 else kwargs.get('content')
        metadata = args[3] if len(args) > 3 else kwargs.get('metadata')
        is_milestone = kwargs.get('is_milestone', False)
        if len(args) > 4 and not is_milestone: is_milestone = args[4]
        
        now = datetime.now().isoformat()
        is_complete = kwargs.get('is_complete', 1)
        seq_id = kwargs.get('seq_id')
        
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO card_sessions (card_id, role, content, metadata, created_at, is_milestone, is_complete, seq_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", 
                         (card_id, role, content, json.dumps(metadata) if metadata else None, now, 1 if is_milestone else 0, 1 if is_complete else 0, seq_id))

    def append_message(self, card_id: str, role: str, content_chunk: str, is_complete: bool = False, seq_id: int = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            # Check the last message for this card
            # Stability Fix: Use id DESC as secondary sort
            cursor = conn.execute("SELECT id, role, content, metadata, is_complete, seq_id FROM card_sessions WHERE card_id = ? ORDER BY created_at DESC, id DESC LIMIT 1", (card_id,))
            row = cursor.fetchone()
            
            # Type Isolation: Don't append to reasoning records
            is_reasoning = False
            if row and row[3]: # metadata
                try:
                    meta = json.loads(row[3])
                    if meta.get('type') == 'reasoning':
                        is_reasoning = True
                except: pass

            if row and row[1] == role and row[4] == 0 and not is_reasoning:
                # Append to existing incomplete message of the same role/type
                msg_id = row[0]
                new_content = (row[2] or "") + content_chunk
                
                # AG-UI Fix: Never update seq_id once it is assigned to a record.
                # This prevents the message from 'jumping' to a later position 
                # if marked complete with a higher seq_id.
                conn.execute("UPDATE card_sessions SET content = ?, is_complete = ? WHERE id = ?", 
                             (new_content, 1 if is_complete else 0, msg_id))
            elif content_chunk:
                # Start a new message
                # Ensure seq_id is never NULL for new records
                if seq_id is None:
                    cursor_max = conn.execute("SELECT MAX(seq_id) FROM card_sessions WHERE card_id = ?", (card_id,))
                    max_seq = cursor_max.fetchone()[0] or 0
                    seq_id = max_seq + 1
                    
                conn.execute("INSERT INTO card_sessions (card_id, role, content, created_at, is_complete, seq_id) VALUES (?, ?, ?, ?, ?, ?)", (card_id, role, content_chunk, now, 1 if is_complete else 0, seq_id))

    def append_thought(self, card_id: str, thought_chunk: str, seq_id: int = None):
        """Legacy thought append (to metadata). Keeps compatibility for non-AG-UI agents."""
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            # Stability Fix: Use id DESC as tie-breaker
            cursor = conn.execute("SELECT id, role, metadata, is_complete FROM card_sessions WHERE card_id = ? AND role = 'assistant' AND is_complete = 0 ORDER BY created_at DESC, id DESC LIMIT 1", (card_id,))
            row = cursor.fetchone()
            if row:
                msg_id = row[0]
                meta = json.loads(row[2]) if row[2] else {}
                meta['thought'] = (meta.get('thought') or "") + thought_chunk
                conn.execute("UPDATE card_sessions SET metadata = ?, seq_id = ? WHERE id = ?", (json.dumps(meta), seq_id, msg_id))
            else:
                meta = {'thought': thought_chunk}
                conn.execute("INSERT INTO card_sessions (card_id, role, content, metadata, created_at, is_complete, seq_id) VALUES (?, 'assistant', '', ?, ?, 0, ?)", (card_id, json.dumps(meta), now, seq_id))

    def append_reasoning(self, card_id: str, reasoning_chunk: str, seq_id: int = None):
        """Append to reasoning record. Merges with last incomplete reasoning record to avoid fragmentation."""
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            # Try to find the last incomplete reasoning record
            cursor = conn.execute("""
                SELECT id, content FROM card_sessions 
                WHERE card_id = ? AND role = 'assistant' AND is_complete = 0 
                ORDER BY created_at DESC, id DESC LIMIT 1
            """, (card_id,))
            row = cursor.fetchone()
            
            if row:
                msg_id = row[0]
                # Verify it's actually a reasoning record
                cursor_meta = conn.execute("SELECT metadata FROM card_sessions WHERE id = ?", (msg_id,))
                meta_row = cursor_meta.fetchone()
                try:
                    meta = json.loads(meta_row[0]) if meta_row[0] else {}
                    if meta.get('type') == 'reasoning':
                        new_content = (row[1] or "") + reasoning_chunk
                        conn.execute("UPDATE card_sessions SET content = ?, seq_id = ? WHERE id = ?", (new_content, seq_id, msg_id))
                        return
                except: pass

            # Otherwise, insert new record
            conn.execute("""
                INSERT INTO card_sessions 
                (card_id, role, content, metadata, created_at, is_complete, seq_id) 
                VALUES (?, 'assistant', ?, ?, ?, 0, ?)
            """, (card_id, reasoning_chunk, json.dumps({'type': 'reasoning'}), now, seq_id))

    def update_message_with_metadata(self, card_id: str, metadata_key: str, metadata_val: Any, content: str = None, is_complete: bool = True, append_content: bool = False):
        """Update the metadata of the last assistant message for a card."""
        with self.db.get_connection() as conn:
            # Look for the last assistant message (even if complete)
            cursor = conn.execute("""
                SELECT id, metadata, content FROM card_sessions 
                WHERE card_id = ? AND role = 'assistant' 
                ORDER BY created_at DESC, id DESC LIMIT 1
            """, (card_id,))
            row = cursor.fetchone()
            if row:
                msg_id = row[0]
                try:
                    meta = json.loads(row[1]) if row[1] else {}
                except:
                    meta = {}
                
                # Merge or set metadata
                if isinstance(metadata_val, list) and metadata_key in meta and isinstance(meta[metadata_key], list):
                    # For tool_calls, we might want to append? 
                    # But Dispatcher currently sends the full list for that turn.
                    meta[metadata_key] = metadata_val
                else:
                    meta[metadata_key] = metadata_val
                
                if content is not None:
                    if append_content:
                        new_content = (row[2] or "") + content
                    else:
                        new_content = content
                else:
                    new_content = row[2]

                conn.execute("UPDATE card_sessions SET metadata = ?, content = ?, is_complete = ? WHERE id = ?", 
                             (json.dumps(meta), new_content, 1 if is_complete else 0, msg_id))
            else:
                # No assistant message found, create one
                now = datetime.now().isoformat()
                meta = {metadata_key: metadata_val}
                conn.execute("""
                    INSERT INTO card_sessions 
                    (card_id, role, content, metadata, created_at, is_complete) 
                    VALUES (?, 'assistant', ?, ?, ?, ?)
                """, (card_id, content or "", json.dumps(meta), now, 1 if is_complete else 0))

    def get_history(self, card_id: str, limit: int = 50, after_seq: int = None) -> List[Dict]:
        with self.db.get_connection() as conn:
            query = "SELECT * FROM card_sessions WHERE card_id = ?"
            params = [card_id]
            if after_seq is not None:
                query += " AND seq_id > ?"
                params.append(after_seq)
            
            # Stability Fix: Always order by seq_id then id to guarantee logic sequence
            query += " ORDER BY seq_id ASC, id ASC"
            cursor = conn.execute(query, params)
            return [dict(row) for row in cursor.fetchall()][-limit:]

class CodeSymbolRepository(BaseRepository):
    def upsert(self, project_id: str, file_path: str, symbol_name: str, symbol_type: str, signature: str, start_line: int, end_line: int, documentation: str, code_content: str, embedding: str = None):
        with self.db.get_connection() as conn:
            conn.execute("""
                INSERT INTO code_symbols (project_id, file_path, symbol_name, symbol_type, signature, start_line, end_line, documentation, code_content, embedding)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_id, file_path, symbol_name, symbol_type) DO UPDATE SET 
                    signature=excluded.signature, start_line=excluded.start_line, end_line=excluded.end_line,
                    documentation=excluded.documentation, code_content=excluded.code_content, embedding=excluded.embedding
            """, (project_id, file_path, symbol_name, symbol_type, signature, start_line, end_line, documentation, code_content, embedding))

    def get_by_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM code_symbols WHERE project_id = ?", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def delete_by_file(self, project_id: str, file_path: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM code_symbols WHERE project_id = ? AND file_path = ?", (project_id, file_path))

    def search_semantic(self, query_vector: List[float], project_id: str, limit: int = 10) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT id, file_path, symbol_name, embedding FROM code_symbols WHERE project_id = ? AND embedding IS NOT NULL", (project_id,))
            rows = cursor.fetchall()
            results = []
            for row in rows:
                try:
                    emb = json.loads(row['embedding'])
                    dist = math.sqrt(sum((a - b) ** 2 for a, b in zip(query_vector, emb)))
                    results.append({'file_path': row['file_path'], 'symbol_name': row['symbol_name'], 'distance': dist})
                except: continue
            results.sort(key=lambda x: x['distance'])
            return results[:limit]

class TimelineRepository(BaseRepository):
    def add_event(self, project_id: str, card_id: str, event_type: str, content: str, metadata: Dict = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("INSERT INTO project_timeline (project_id, card_id, event_type, content, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?)", (project_id, card_id, event_type, content, json.dumps(metadata) if metadata else None, now))

    def get_by_project(self, project_id: str, limit: int = 100) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("""
                SELECT t.*, c.title as card_title 
                FROM project_timeline t 
                LEFT JOIN cards c ON t.card_id = c.id 
                WHERE t.project_id = ? 
                ORDER BY t.timestamp DESC LIMIT ?
            """, (project_id, limit))
            return [dict(row) for row in cursor.fetchall()]

class AgentStatusRepository(BaseRepository):
    def update(self, project_id: str, state: str, message: str = None):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT project_id FROM project_agent_status WHERE project_id = ?", (project_id,))
            if cursor.fetchone():
                conn.execute("UPDATE project_agent_status SET state = ?, last_message = ?, updated_at = ? WHERE project_id = ?", (state, message, now, project_id))
            else:
                conn.execute("INSERT INTO project_agent_status (project_id, state, last_message, start_time, updated_at) VALUES (?, ?, ?, ?, ?)", (project_id, state, message, now, now))

    def get_all(self) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM project_agent_status")
            return [dict(row) for row in cursor.fetchall()]

class FileIndexRepository(BaseRepository):
    def get(self, project_id: str, file_path: str) -> Optional[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM file_index WHERE project_id = ? AND file_path = ?", (project_id, file_path))
            row = cursor.fetchone()
            return dict(row) if row else None

    def get_by_project(self, project_id: str) -> List[Dict]:
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM file_index WHERE project_id = ?", (project_id,))
            return [dict(row) for row in cursor.fetchall()]

    def upsert(self, project_id: str, file_path: str, file_hash: str, file_size: int):
        now = datetime.now().isoformat()
        with self.db.get_connection() as conn:
            conn.execute("""
                INSERT INTO file_index (project_id, file_path, file_hash, file_size, indexed_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(project_id, file_path) DO UPDATE SET 
                    file_hash=excluded.file_hash, file_size=excluded.file_size, indexed_at=excluded.indexed_at
            """, (project_id, file_path, file_hash, file_size, now))

    def delete(self, project_id: str, file_path: str):
        with self.db.get_connection() as conn:
            conn.execute("DELETE FROM file_index WHERE project_id = ? AND file_path = ?", (project_id, file_path))

class KanbanDB:
    _instance = None
    _lock = threading.Lock()
    _initialized = False

    def __new__(cls, *args, **kwargs):
        with cls._lock:
            if cls._instance is None:
                cls._instance = super(KanbanDB, cls).__new__(cls)
            return cls._instance

    def __init__(self, db_path: str = "kanban.db"):
        if self._initialized: return
        self.db_path = db_path
        self._pool = ConnectionPool(self._create_new_connection)
        self.projects = ProjectRepository(self)
        self.milestones = MilestoneRepository(self)
        self.features = FeatureRepository(self)
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
            cursor.execute("CREATE TABLE IF NOT EXISTS milestones (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, target_date DATETIME, status TEXT DEFAULT 'active', order_index INTEGER DEFAULT 0, created_at DATETIME, deleted_at DATETIME, FOREIGN KEY (project_id) REFERENCES projects(id))")
            cursor.execute("CREATE TABLE IF NOT EXISTS features (id TEXT PRIMARY KEY, milestone_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, status TEXT DEFAULT 'active', order_index INTEGER DEFAULT 0, created_at DATETIME, deleted_at DATETIME, FOREIGN KEY (milestone_id) REFERENCES milestones(id))")
            cursor.execute("CREATE TABLE IF NOT EXISTS columns (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER, color TEXT, prompt_template TEXT, acp_provider_id TEXT, approval_mode TEXT, created_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, column_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, position INTEGER, status TEXT DEFAULT 'active', plan_status TEXT DEFAULT 'plan', completed_at DATETIME, parent_id TEXT, last_summary TEXT, embedding TEXT, created_at DATETIME, updated_at DATETIME, acp_session_id TEXT, acp_provider_id TEXT, config_options TEXT, feature_id TEXT, deleted_at DATETIME, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0)")
            cursor.execute("CREATE TABLE IF NOT EXISTS card_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, role TEXT, content TEXT, metadata TEXT, created_at DATETIME, is_complete INTEGER DEFAULT 1, is_milestone INTEGER DEFAULT 0, seq_id INTEGER)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_timeline (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, card_id TEXT, event_type TEXT, content TEXT, metadata TEXT, timestamp DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS project_agent_status (project_id TEXT PRIMARY KEY, state TEXT, start_time DATETIME, last_message TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS summaries (card_id TEXT PRIMARY KEY, summary TEXT NOT NULL, embedding TEXT, updated_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS summary_history (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, summary TEXT NOT NULL, created_at DATETIME)")
            cursor.execute("CREATE TABLE IF NOT EXISTS code_symbols (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, file_path TEXT NOT NULL, symbol_name TEXT NOT NULL, symbol_type TEXT NOT NULL, signature TEXT, start_line INTEGER, end_line INTEGER, documentation TEXT, code_content TEXT, embedding TEXT, UNIQUE(project_id, file_path, symbol_name, symbol_type))")
            cursor.execute("CREATE TABLE IF NOT EXISTS file_index (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, file_path TEXT NOT NULL, file_hash TEXT NOT NULL, file_size INTEGER, indexed_at DATETIME, UNIQUE(project_id, file_path))")
            
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_milestones_project_deleted ON milestones(project_id, deleted_at)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_features_milestone_deleted ON features(milestone_id, deleted_at)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_cards_feature_deleted ON cards(feature_id, deleted_at)")

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
                ("cards", "plan_status", "TEXT DEFAULT 'plan'"),
                ("cards", "feature_id", "TEXT"),
                ("cards", "deleted_at", "DATETIME"),
                ("cards", "input_tokens", "INTEGER DEFAULT 0"),
                ("cards", "output_tokens", "INTEGER DEFAULT 0"),
                ("summaries", "embedding", "TEXT"), 
                ("card_sessions", "is_milestone", "INTEGER DEFAULT 0"),
                ("card_sessions", "seq_id", "INTEGER"),
            ]
            
            for table, col, col_type in migrations:
                try: 
                    cursor.execute(f"ALTER TABLE {table} ADD COLUMN {col} {col_type}")
                except Exception as e: 
                    if "duplicate column name" not in str(e).lower():
                        logger.warning(f"DB Migration: Could not add {table}.{col}: {e}")
            
            now = datetime.now().isoformat()
            cursor.execute("SELECT id FROM projects")
            projects = cursor.fetchall()
            for project in projects:
                pid = project['id']
                cursor.execute("SELECT id FROM milestones WHERE project_id = ? AND title = ?", (pid, UNCATEGORIZED_MILESTONE_TITLE))
                if not cursor.fetchone():
                    m_id = str(uuid.uuid4())[:8]
                    f_id = str(uuid.uuid4())[:8]
                    cursor.execute("INSERT INTO milestones (id, project_id, title, status, created_at) VALUES (?, ?, ?, ?, ?)", (m_id, pid, UNCATEGORIZED_MILESTONE_TITLE, 'active', now))
                    cursor.execute("INSERT INTO features (id, milestone_id, title, status, created_at) VALUES (?, ?, ?, ?, ?)", (f_id, m_id, DEFAULT_FEATURE_TITLE, 'active', now))
                    cursor.execute("UPDATE cards SET feature_id = ? WHERE feature_id IS NULL AND column_id IN (SELECT id FROM columns WHERE project_id = ?)", (f_id, pid))

    # --- API Bridge Methods ---
    def get_projects(self): return self.projects.get_all()
    def create_project(self, name, workspace_path=None, description=None): return self.projects.create(name, workspace_path, description)
    def get_project(self, project_id): return self.projects.get_by_id(project_id)
    def update_project(self, project_id, name=None, workspace_path=None, description=None): return self.projects.update(project_id, name, workspace_path, description)
    def update_project_stats(self, project_id, index_status=None, last_indexed_at=None, total_files=None, total_symbols=None, total_vectorized_symbols=None): return self.projects.update_stats(project_id, index_status, last_indexed_at, total_files, total_symbols, total_vectorized_symbols)
    def delete_project(self, project_id): return self.projects.delete(project_id)

    def get_milestones(self, project_id): return self.milestones.get_by_project(project_id)
    def create_milestone(self, project_id, title, description=None, target_date=None): return self.milestones.create(project_id, title, description, target_date)
    def update_milestone(self, m_id, title=None, description=None, status=None, target_date=None): return self.milestones.update(m_id, title, description, status, target_date)
    def delete_milestone(self, m_id): return self.milestones.delete(m_id)

    def get_features(self, m_id): return self.features.get_by_milestone(m_id)
    def create_feature(self, m_id, title, description=None): return self.features.create(m_id, title, description)
    def update_feature(self, f_id, title=None, description=None, status=None): return self.features.update(f_id, title, description, status)
    def delete_feature(self, f_id): return self.features.delete(f_id)

    def get_columns(self, project_id): return self.columns.get_all(project_id)
    def get_column(self, column_id): return self.columns.get_by_id(column_id)
    def create_column(self, project_id, name, position=None, color="#808080", prompt_template=None, acp_provider_id=None): return self.columns.create(project_id, name, position, color, prompt_template, acp_provider_id)
    def update_column(self, column_id, name=None, color=None, prompt_template=None, acp_provider_id=None): return self.columns.update(column_id, name, color, prompt_template, acp_provider_id)
    def delete_column(self, column_id, move_to_column_id=None): return self.columns.delete(column_id, move_to_column_id)
    def reorder_columns(self, positions): return self.columns.reorder(positions)

    def get_card(self, card_id): return self.cards.get_by_id(card_id)
    def get_cards_by_column(self, column_id, include_completed=False): return self.cards.get_by_column(column_id, include_completed)
    def create_card(self, column_id, title, description=None, parent_id=None, feature_id=None): return self.cards.create(column_id, title, description, parent_id, feature_id)
    def update_card(self, card_id, title=None, description=None, status=None, feature_id=None): return self.cards.update(card_id, title, description, status, feature_id)
    def delete_card(self, card_id): return self.cards.delete(card_id)
    def move_card(self, card_id, target_column_id, target_position=None): return self.cards.move(card_id, target_column_id, target_position)
    def update_card_provider(self, card_id, provider_id): return self.cards.update_provider(card_id, provider_id)
    def update_card_session_id(self, card_id, session_id): return self.cards.update_session_id(card_id, session_id)
    def get_project_progress(self, project_id, depth=3): return self.cards.get_progress_stats(project_id, depth)

    def get_summary(self, card_id): return self.summaries.get(card_id)
    def get_session_history(self, card_id, limit=50, after_seq=None): return self.sessions.get_history(card_id, limit, after_seq)
    def add_session_message(self, card_id, role, content, metadata=None, is_milestone=False): return self.sessions.add_message(card_id, role, content, metadata, is_milestone)
    def append_message(self, card_id, role, content_chunk, is_complete=False, seq_id=None): return self.sessions.append_message(card_id, role, content_chunk, is_complete, seq_id)
    def update_message_with_metadata(self, card_id, metadata_key, metadata_val, content=None, is_complete=True): return self.sessions.update_message_with_metadata(card_id, metadata_key, metadata_val, content, is_complete)
    def add_thought(self, card_id, thought, seq_id=None): return self.sessions.append_thought(card_id, thought, seq_id)
    def append_thought(self, card_id, thought_chunk, seq_id=None): return self.sessions.append_thought(card_id, thought_chunk, seq_id)
    def append_reasoning(self, card_id, reasoning_chunk, seq_id=None): return self.sessions.append_reasoning(card_id, reasoning_chunk, seq_id)

    def get_timeline(self, project_id, limit=100): return self.timeline.get_by_project(project_id, limit)
    def add_timeline_event(self, project_id, card_id, event_type, content, metadata=None): return self.timeline.add_event(project_id, card_id, event_type, content, metadata)

    def get_project_agent_statuses(self): return self.agent_status.get_all()
    def update_project_agent_status(self, project_id, state, message=None): return self.agent_status.update(project_id, state, message)

    def get_file_index(self, project_id): return self.file_index.get_all(project_id)
    def get_file_index_entry(self, project_id, file_path): return self.file_index.get(project_id, file_path)
    def update_file_index(self, project_id, file_path, file_hash, file_size): return self.file_index.upsert(project_id, file_path, file_hash, file_size)
    def delete_file_index(self, project_id, file_path): return self.file_index.delete(project_id, file_path)
    def get_project_file_count(self, project_id: int) -> int:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) FROM file_index WHERE project_id = ?", (project_id,))
            return cursor.fetchone()[0]
    def get_project_symbol_count(self, project_id: int) -> int:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", (project_id,))
            return cursor.fetchone()[0]
    def get_project_vectorized_symbol_count(self, project_id: int) -> int:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT COUNT(*) FROM code_symbols WHERE project_id = ? AND embedding IS NOT NULL AND embedding != 'null' AND embedding != '[]'", (project_id,))
            return cursor.fetchone()[0]

    def get_settings(self) -> Dict[str, Any]:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT key, value FROM settings")
            return {row[0]: row[1] for row in cursor.fetchall()}

    def get_setting(self, key: str, default: Any = None) -> Any:
        with self.get_connection() as conn:
            cursor = conn.execute("SELECT value FROM settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row[0] if row else default

    def set_setting(self, key: str, value: Any):
        now = datetime.now().isoformat()
        with self.get_connection() as conn:
            conn.execute("INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at", (key, str(value), now))

    def update_card_config_options(self, card_id: str, config_options: str): return self.cards.update_config_options(card_id, config_options)
    def get_card_config_options(self, card_id: str): return self.cards.get_config_options(card_id)
    def update_card_available_commands(self, card_id: str, available_commands: str): return self.cards.update_available_commands(card_id, available_commands)
    def get_card_available_commands(self, card_id: str): return self.cards.get_available_commands(card_id)
    def update_card_token_usage(self, card_id: str, input_tokens: int, output_tokens: int): return self.cards.update_token_usage(card_id, input_tokens, output_tokens)
    def complete_card(self, card_id): return self.cards.update(card_id, status='completed')
    def uncomplete_card(self, card_id): return self.cards.update(card_id, status='active')
    def mark_session_complete(self, card_id): return self.sessions.mark_complete(card_id)
    def update_card_summary(self, card_id: str, summary: str, sync_to_card: bool = True):
        """Update the source of truth summary and optionally sync to card front for UI display."""
        # 1. Update summaries table (History)
        self.summaries.upsert(card_id, summary)
        
        # 2. Optionally sync to cards table (UI Display)
        if sync_to_card:
            with self.get_connection() as conn:
                conn.execute("UPDATE cards SET last_summary = ?, updated_at = ? WHERE id = ?", (summary, datetime.now().isoformat(), card_id))
