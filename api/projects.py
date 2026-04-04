from fastapi import APIRouter, HTTPException, Query
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
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


class ColumnUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=100)
    color: Optional[str] = None


class ProjectCreateRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    workspace_path: Optional[str] = Field(None, max_length=500)


class ProjectUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=200)
    workspace_path: Optional[str] = Field(None, max_length=500)


class ProjectResponse(BaseModel):
    id: str
    name: str
    workspace_path: Optional[str]
    created_at: str
    updated_at: str
    card_count: int = 0


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
                created_at=p["created_at"],
                updated_at=p["updated_at"],
                card_count=p.get("card_count", 0),
            )
            for p in projects
        ]
    except Exception as e:
        raise HTTPError(400, str(e))


@router.post("/projects", response_model=ProjectResponse, status_code=201)
async def create_project(request: ProjectCreateRequest):
    """
    Create a new project.
    """
    db = get_db()
    try:
        project_id = db.create_project(
            name=request.name,
            workspace_path=request.workspace_path,
        )
        project = db.get_project(project_id)
        if not project:
            raise HTTPError(500, "Failed to create project")

        return ProjectResponse(
            id=project["id"],
            name=project["name"],
            workspace_path=project.get("workspace_path"),
            created_at=project["created_at"],
            updated_at=project["updated_at"],
            card_count=0,
        )
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
        created_at=project["created_at"],
        updated_at=project["updated_at"],
        card_count=card_count,
    )


@router.put("/projects/{project_id}", response_model=ProjectResponse)
async def update_project(project_id: str, request: ProjectUpdateRequest):
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
        )
        project = db.get_project(project_id)
        if not project:
            raise HTTPError(404, "Project not found")

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
            created_at=project["created_at"],
            updated_at=project["updated_at"],
            card_count=card_count,
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
