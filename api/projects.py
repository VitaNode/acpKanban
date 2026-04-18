from fastapi import APIRouter, HTTPException, Query, BackgroundTasks
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
import asyncio
from datetime import datetime
from src.persistence.embedding import embedding_service
from src.transport.bus import bus
from api.dependencies import (
    get_db,
    validate_project_exists,
    format_card_response,
    HTTPError,
)

router = APIRouter(prefix="/api", tags=["projects"])


class ColumnPositionItem(BaseModel):
    id: str
    position: int


class ColumnReorderRequest(BaseModel):
    positions: List[ColumnPositionItem]


class ColumnCreateRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    position: Optional[int] = None
    color: Optional[str] = "#808080"
    prompt_template: Optional[str] = Field(None, max_length=5000)
    acp_provider_id: Optional[str] = Field(None, max_length=50)


class ColumnUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=100)
    color: Optional[str] = None
    prompt_template: Optional[str] = Field(None, max_length=5000)
    acp_provider_id: Optional[str] = Field(None, max_length=50)


class ProjectCreateRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    workspace_path: Optional[str] = Field(None, max_length=500)
    description: Optional[str] = Field(None, max_length=2000)


class ProjectUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=200)
    workspace_path: Optional[str] = Field(None, max_length=500)
    description: Optional[str] = Field(None, max_length=2000)


class ProjectResponse(BaseModel):
    id: str
    name: str
    workspace_path: Optional[str]
    description: Optional[str] = None
    created_at: str
    updated_at: str
    card_count: int = 0
    index_status: str = "idle"
    last_indexed_at: Optional[str] = None
    total_files: int = 0
    total_symbols: int = 0
    total_vectorized_symbols: int = 0


class IndexStartRequest(BaseModel):
    force_full: bool = False
    mode: str = "full" # "structural" | "full"


class IndexStatusResponse(BaseModel):
    project_id: str
    index_status: str
    progress: Optional[Dict[str, Any]] = None
    stats: Dict[str, int]
    last_indexed_at: Optional[str] = None


class IndexTaskManager:
    """Manages background indexing tasks with robust locking and progress tracking."""
    def __init__(self):
        self._tasks: Dict[str, asyncio.Task] = {}
        self._progress: Dict[str, Dict[str, Any]] = {}
        self._start_times: Dict[str, float] = {}
        self._lock = asyncio.Lock()

    async def start_task(self, project_id: str, workspace_path: str, force_full: bool = False):
        async with self._lock:
            existing = self._tasks.get(project_id)
            if existing and not existing.done():
                return False
            
            # Cleanup finished task and its progress
            self._tasks.pop(project_id, None)
            self._progress.pop(project_id, None)
            self._start_times[project_id] = asyncio.get_event_loop().time()
            
            task = asyncio.create_task(self._run_indexing(project_id, workspace_path, force_full))
            self._tasks[project_id] = task
            return True

    async def cancel_task(self, project_id: str):
        async with self._lock:
            task = self._tasks.get(project_id)
            if task and not task.done():
                task.cancel()
                try:
                    await asyncio.wait_for(task, timeout=3.0)
                except (asyncio.CancelledError, asyncio.TimeoutError):
                    pass
                
                db = get_db()
                db.update_project_stats(project_id, index_status="idle")
                self._progress.pop(project_id, None)
                self._start_times.pop(project_id, None)
                return True
            return False

    def get_progress(self, project_id: str) -> Optional[Dict[str, Any]]:
        # This can be called frequently, we return a snapshot
        return self._progress.get(project_id)

    async def _run_indexing(self, project_id: str, workspace_path: str, force_full: bool):
        db = get_db()
        db.update_project_stats(project_id, index_status="running")
        start_time = self._start_times.get(project_id, asyncio.get_event_loop().time())
        mode = "full" if force_full else "incremental"
        
        try:
            async def on_progress(p):
                elapsed = round(asyncio.get_event_loop().time() - start_time, 1)
                full_p = {
                    "status": "running",
                    "mode": mode,
                    "elapsed_seconds": elapsed,
                    **p
                }
                async with self._lock:
                    self._progress[project_id] = full_p

                # Push to WebSocket (card_id format check: we use project:id but bus expect card_id)
                # NotificationBus should be generic but currently it mentions card_id
                bus.publish(f"project:{project_id}", {
                    "type": "index_progress",
                    "project_id": project_id,
                    "data": full_p
                })

            await embedding_service.index_codebase(
                project_id, 
                workspace_path, 
                force_full=force_full, 
                on_progress=on_progress
            )
            
            db.update_project_stats(
                project_id, 
                index_status="idle", 
                last_indexed_at=datetime.now().isoformat()
            )
            
            total_elapsed = round(asyncio.get_event_loop().time() - start_time, 1)
            bus.publish(f"project:{project_id}", {
                "type": "index_completed",
                "project_id": project_id,
                "data": {
                    "status": "completed",
                    "total_time_seconds": total_elapsed
                }
            })

        except asyncio.CancelledError:
            db.update_project_stats(project_id, index_status="idle")
            raise
        except Exception as e:
            import traceback
            traceback.print_exc()
            db.update_project_stats(project_id, index_status="error")
            bus.publish(f"project:{project_id}", {
                "type": "index_error",
                "project_id": project_id,
                "data": {
                    "status": "error", 
                    "error_code": "indexing_failed",
                    "message": str(e),
                    "recoverable": True
                }
            })
        finally:
            async with self._lock:
                self._progress.pop(project_id, None)
                self._start_times.pop(project_id, None)

# Global manager instance
index_task_manager = IndexTaskManager()


@router.get("/projects", response_model=list[ProjectResponse])
async def get_projects():
    """
    Get all projects.
    """
    db = get_db()
    try:
        projects = db.get_projects()
        return [
            ProjectResponse(
                id=p["id"],
                name=p["name"],
                workspace_path=p.get("workspace_path"),
                description=p.get("description"),
                created_at=p["created_at"],
                updated_at=p["updated_at"],
                card_count=p.get("card_count", 0),
                index_status=p.get("index_status", "idle"),
                last_indexed_at=p.get("last_indexed_at"),
                total_files=p.get("total_files", 0),
                total_symbols=p.get("total_symbols", 0),
                total_vectorized_symbols=p.get("total_vectorized_symbols", 0),
            )
            for p in projects
        ]
    except Exception as e:
        raise HTTPError(400, str(e))


@router.post("/projects", response_model=ProjectResponse, status_code=201)
async def create_project(request: ProjectCreateRequest, background_tasks: BackgroundTasks):
    """
    Create a new project.
    """
    db = get_db()
    try:
        project_id = db.create_project(
            name=request.name,
            workspace_path=request.workspace_path,
            description=request.description,
        )

        project = db.get_project(project_id)
        if not project:
            raise HTTPError(500, "Failed to create project")

        # Trigger indexing in background using manager
        if request.workspace_path:
            await index_task_manager.start_task(project_id, request.workspace_path)

        return ProjectResponse(
            id=project["id"],
            name=project["name"],
            workspace_path=project.get("workspace_path"),
            description=project.get("description"),
            created_at=project["created_at"],
            updated_at=project["updated_at"],
            card_count=0,
            index_status=project.get("index_status", "idle"),
            last_indexed_at=project.get("last_indexed_at"),
            total_files=project.get("total_files", 0),
            total_symbols=project.get("total_symbols", 0),
            total_vectorized_symbols=project.get("total_vectorized_symbols", 0),
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/projects/{project_id}", response_model=ProjectResponse)
async def get_project(project_id: str):
    """
    Get a project by ID.
    """
    db = get_db()
    project = validate_project_exists(project_id, db)

    with db.get_connection() as conn:
        cursor = conn.execute(
            "SELECT COUNT(*) as count FROM cards c JOIN columns col ON col.id = c.column_id WHERE col.project_id = ?",
            (project_id,),
        )
        row = cursor.fetchone()
        card_count = row[0] if row else 0

    return ProjectResponse(
        id=project["id"],
        name=project["name"],
        workspace_path=project.get("workspace_path"),
        description=project.get("description"),
        created_at=project["created_at"],
        updated_at=project["updated_at"],
        card_count=card_count,
        index_status=project.get("index_status", "idle"),
        last_indexed_at=project.get("last_indexed_at"),
        total_files=project.get("total_files", 0),
        total_symbols=project.get("total_symbols", 0),
        total_vectorized_symbols=project.get("total_vectorized_symbols", 0),
    )


@router.post("/projects/{project_id}/index/start")
async def start_indexing(project_id: str, request: IndexStartRequest):
    db = get_db()
    project = validate_project_exists(project_id, db)
    
    if not project.get("workspace_path"):
        raise HTTPError(400, "Project has no workspace path configured")
    
    started = await index_task_manager.start_task(
        project_id, 
        project["workspace_path"], 
        force_full=request.force_full
    )
    
    if not started:
        return {"success": False, "error_code": "ALREADY_RUNNING", "message": "Index task is already running"}
    
    return {"success": True, "message": "Indexing started"}


@router.get("/projects/{project_id}/index/status", response_model=IndexStatusResponse)
async def get_indexing_status(project_id: str):
    db = get_db()
    project = validate_project_exists(project_id, db)
    
    progress = index_task_manager.get_progress(project_id)
    
    return IndexStatusResponse(
        project_id=project_id,
        index_status=project.get("index_status", "idle"),
        progress=progress,
        stats={
            "total_files": project.get("total_files", 0),
            "total_symbols": project.get("total_symbols", 0),
            "total_vectorized_symbols": project.get("total_vectorized_symbols", 0)
        },
        last_indexed_at=project.get("last_indexed_at")
    )


@router.post("/projects/{project_id}/index/cancel")
async def cancel_indexing(project_id: str):
    db = get_db()
    validate_project_exists(project_id, db)
    
    cancelled = await index_task_manager.cancel_task(project_id)
    return {"success": cancelled}


@router.put("/projects/{project_id}", response_model=ProjectResponse)
async def update_project(project_id: str, request: ProjectUpdateRequest, background_tasks: BackgroundTasks):
    """
    Update a project.
    """
    db = get_db()
    validate_project_exists(project_id, db)

    try:
        db.update_project(
            project_id=project_id,
            name=request.name,
            workspace_path=request.workspace_path,
            description=request.description,
        )
        project = db.get_project(project_id)
        if not project:
            raise HTTPError(404, "Project not found")

        # Optional: trigger re-indexing if workspace path changed
        # For now, let user trigger it manually or stay with background default
        # if request.workspace_path:
        #    await index_task_manager.start_task(project_id, project["workspace_path"])

        with db.get_connection() as conn:
            cursor = conn.execute(
                "SELECT COUNT(*) as count FROM cards c JOIN columns col ON col.id = c.column_id WHERE col.project_id = ?",
                (project_id,),
            )
            row = cursor.fetchone()
            card_count = row[0] if row else 0

        return ProjectResponse(
            id=project["id"],
            name=project["name"],
            workspace_path=project.get("workspace_path"),
            description=project.get("description"),
            created_at=project["created_at"],
            updated_at=project["updated_at"],
            card_count=card_count,
            index_status=project.get("index_status", "idle"),
            last_indexed_at=project.get("last_indexed_at"),
            total_files=project.get("total_files", 0),
            total_symbols=project.get("total_symbols", 0),
            total_vectorized_symbols=project.get("total_vectorized_symbols", 0),
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.delete("/projects/{project_id}")
async def delete_project(project_id: str):
    """
    Delete a project.
    """
    db = get_db()
    project = validate_project_exists(project_id, db)

    try:
        db.delete_project(project_id)
        return {"message": f"Project '{project['name']}' deleted successfully"}
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/projects/{project_id}/columns", response_model=list)
async def get_columns(project_id: str):
    """
    Get all columns for a project.
    """
    db = get_db()
    validate_project_exists(project_id, db)

    try:
        columns = db.get_columns(project_id)
        return columns
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/projects/{project_id}/summaries", response_model=list)
async def get_project_summaries(project_id: str):
    """
    Get all summaries for a project.
    """
    db = get_db()
    validate_project_exists(project_id, db)

    try:
        summaries = db.get_all_summaries(project_id)
        return summaries
    except Exception as e:
        raise HTTPError(400, str(e))


@router.post("/projects/{project_id}/columns", response_model=dict, status_code=201)
async def create_column(project_id: str, request: ColumnCreateRequest):
    """
    Create a new column for a project.
    """
    db = get_db()
    validate_project_exists(project_id, db)

    try:
        column_id = db.create_column(
            project_id=project_id,
            name=request.name,
            position=request.position,
            color=request.color,
            prompt_template=request.prompt_template,
            acp_provider_id=request.acp_provider_id,
        )
        column = db.get_column(column_id)
        if not column:
            raise HTTPError(500, "Failed to create column")
        return column
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.put("/columns/{column_id}", response_model=dict)
async def update_column(column_id: str, request: ColumnUpdateRequest):
    """
    Update a column.
    """
    db = get_db()

    # Check column exists
    column = db.get_column(column_id)
    if not column:
        raise HTTPError(404, "Column not found")

    try:
        db.update_column(
            column_id=column_id,
            name=request.name,
            color=request.color,
            prompt_template=request.prompt_template,
            acp_provider_id=request.acp_provider_id,
        )
        return db.get_column(column_id)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.delete("/columns/{column_id}")
async def delete_column(
    column_id: str,
    move_to_column_id: Optional[str] = Query(
        None, description="Target column ID to move cards to"
    ),
):
    """
    Delete a column.
    If the column has cards, you must provide move_to_column_id to move them.
    """
    db = get_db()

    # Check column exists
    column = db.get_column(column_id)
    if not column:
        raise HTTPError(404, "Column not found")

    # Check if column has cards
    cards = db.get_cards_by_column(column_id, include_completed=True)
    if cards and not move_to_column_id:
        raise HTTPError(
            400,
            f"Column has {len(cards)} cards. Provide move_to_column_id or delete cards first",
        )

    if move_to_column_id:
        # Validate target column
        target_column = db.get_column(move_to_column_id)
        if not target_column:
            raise HTTPError(404, "Target column not found")
        if target_column["project_id"] != column["project_id"]:
            raise HTTPError(400, "Target column must belong to the same project")

    try:
        db.delete_column(column_id, move_to_column_id)
        return {"status": "deleted"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.patch("/projects/{project_id}/columns/reorder")
async def reorder_columns(project_id: str, request: ColumnReorderRequest):
    """
    Reorder columns for a project.
    """
    db = get_db()
    validate_project_exists(project_id, db)

    positions = [{"id": p.id, "position": p.position} for p in request.positions]

    if not positions:
        raise HTTPError(400, "No positions provided")

    try:
        db.reorder_columns(positions)
        return {"status": "reordered"}
    except Exception as e:
        raise HTTPError(400, str(e))


@router.post("/projects/{project_id}/switch")
async def switch_project(project_id: str):
    """
    Switch to a project. Returns complete project data for UI refresh.
    """
    db = get_db()
    project = validate_project_exists(project_id, db)

    # 1. Get card count and project details in one go (already done)
    with db.get_connection() as conn:
        cursor = conn.execute(
            "SELECT COUNT(*) as count FROM cards c JOIN columns col ON col.id = c.column_id WHERE col.project_id = ?",
            (project_id,),
        )
        row = cursor.fetchone()
        card_count = row[0] if row else 0

    # 2. Get all columns and all cards for the project in TWO queries instead of N+1
    columns = db.get_columns(project_id)
    
    # Get all cards for all columns in this project
    with db.get_connection() as conn:
        cursor = conn.execute(
            """
            SELECT c.*, col.name as column_name 
            FROM cards c 
            JOIN columns col ON c.column_id = col.id 
            WHERE col.project_id = ? 
            ORDER BY c.position ASC
            """,
            (project_id,),
        )
        all_cards = [dict(row) for row in cursor.fetchall()]

    # 3. Map cards to columns in memory
    column_data = []
    for col in columns:
        col_id = col["id"]
        col_cards = [c for c in all_cards if c["column_id"] == col_id]
        column_data.append(
            {
                "id": col_id,
                "name": col["name"],
                "position": col["position"],
                "color": col["color"],
                "card_count": len(col_cards),
                "cards": [
                    {
                        "id": c["id"],
                        "title": c["title"],
                        "description": c.get("description", ""),
                        "position": c["position"],
                        "status": c.get("status", "active"),
                        "completed_at": c.get("completed_at"),
                        "parent_id": c.get("parent_id"),
                        "acp_session_id": c.get("acp_session_id"),
                        "acp_provider_id": c.get("acp_provider_id"),
                        "session_count": c.get("session_count", 0),
                        "created_at": c["created_at"],
                        "updated_at": c["updated_at"],
                    }
                    for c in col_cards
                ],
            }
        )

    timeline = db.get_timeline(project_id, limit=20)

    return {
        "project": {
            "id": project_id,
            "name": project["name"],
            "workspace_path": project.get("workspace_path"),
            "card_count": card_count,
            "index_status": project.get("index_status", "idle"),
            "last_indexed_at": project.get("last_indexed_at"),
            "total_files": project.get("total_files", 0),
            "total_symbols": project.get("total_symbols", 0),
            "total_vectorized_symbols": project.get("total_vectorized_symbols", 0),
            "created_at": project["created_at"],
            "updated_at": project["updated_at"],
        },
        "columns": column_data,
        "timeline": timeline,
        "message": f"Switched to project '{project['name']}'",
    }


@router.get("/projects/{project_id}/status", response_model=dict)
async def get_project_status(project_id: str):
    """
    Get agent status for a project.
    """
    db = get_db()
    validate_project_exists(project_id, db)

    try:
        status = db.get_project_agent_status(project_id)
        if status:
            return {
                "project_id": project_id,
                "state": status["state"],
                "start_time": status.get("start_time"),
                "last_message": status.get("last_message"),
                "updated_at": status.get("updated_at"),
            }
        else:
            return {
                "project_id": project_id,
                "state": "idle",
                "start_time": None,
                "last_message": None,
                "updated_at": None,
            }
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/projects/status", response_model=list)
async def get_all_project_statuses():
    """
    Get agent statuses for all active projects.
    """
    db = get_db()
    try:
        statuses = db.get_all_agent_statuses()
        return [
            {
                "project_id": s["project_id"],
                "project_name": s["project_name"],
                "state": s["state"],
                "start_time": s.get("start_time"),
                "last_message": s.get("last_message"),
                "updated_at": s.get("updated_at"),
            }
            for s in statuses
        ]
    except Exception as e:
        raise HTTPError(400, str(e))
