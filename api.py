from fastapi import FastAPI, HTTPException, Query
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional, List, Dict, Any
from datetime import datetime
from enum import Enum
from database import KanbanDB
from embedding import embedding_service

app = FastAPI(title="Kanban API", version="2.0.0")


@app.exception_handler(Exception)
async def global_exception_handler(request, exc):
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "detail": str(exc)},
    )


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc):
    return JSONResponse(
        status_code=400,
        content={"error": "Validation error", "detail": exc.errors()},
    )


@app.exception_handler(HTTPException)
async def http_exception_handler(request, exc):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.detail},
    )


db = KanbanDB()


class ProjectCreate(BaseModel):
    name: str
    workspace_path: Optional[str] = None


class ProjectUpdate(BaseModel):
    name: Optional[str] = None
    workspace_path: Optional[str] = None


class ColumnCreate(BaseModel):
    name: str
    position: Optional[int] = None
    color: Optional[str] = "#808080"


class ColumnUpdate(BaseModel):
    name: Optional[str] = None
    color: Optional[str] = None


class CardCreate(BaseModel):
    column_id: str
    title: str
    description: Optional[str] = ""
    position: Optional[int] = None


class CardUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None


class CardMove(BaseModel):
    target_column_id: str
    target_position: Optional[int] = None


class SessionMessage(BaseModel):
    role: str
    content: str
    metadata: Optional[Dict[str, Any]] = None


class SearchQuery(BaseModel):
    query: str
    mode: str = "fts"
    project_id: Optional[str] = None
    limit: int = 20


@app.get("/health")
def health_check():
    return {
        "status": "healthy",
        "embedding_available": embedding_service.is_available(),
    }


@app.get("/api/projects", response_model=List[Dict])
def get_projects():
    return db.get_projects()


@app.post("/api/projects", response_model=Dict)
def create_project(data: ProjectCreate):
    project_id = db.create_project(data.name, data.workspace_path)
    return {"id": project_id, "name": data.name}


@app.get("/api/projects/{project_id}", response_model=Dict)
def get_project(project_id: str):
    project = db.get_project(project_id)
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    return project


@app.put("/api/projects/{project_id}", response_model=Dict)
def update_project(project_id: str, data: ProjectUpdate):
    db.update_project(project_id, data.name, data.workspace_path)
    return {"id": project_id}


@app.delete("/api/projects/{project_id}")
def delete_project(project_id: str):
    db.delete_project(project_id)
    return {"status": "deleted"}


@app.get("/api/projects/{project_id}/columns", response_model=List[Dict])
def get_columns(project_id: str):
    project = db.get_project(project_id)
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    return db.get_columns(project_id)


@app.post("/api/projects/{project_id}/columns", response_model=Dict)
def create_column(project_id: str, data: ColumnCreate):
    project = db.get_project(project_id)
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    column_id = db.create_column(project_id, data.name, data.position, data.color)
    column = db.get_column(column_id)
    return column


@app.post("/api/projects/{project_id}/columns/batch", response_model=List[Dict])
def create_columns_batch(project_id: str, data: List[ColumnCreate]):
    """批量创建列（用于导入或初始化）"""
    project = db.get_project(project_id)
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    results = []
    for i, col in enumerate(data):
        position = col.position if col.position is not None else i
        column_id = db.create_column(project_id, col.name, position, col.color)
        column = db.get_column(column_id)
        results.append(column)
    return results


@app.get("/api/columns/{column_id}", response_model=Dict)
def get_column(column_id: str):
    column = db.get_column(column_id)
    if not column:
        raise HTTPException(status_code=404, detail="Column not found")
    return column


@app.put("/api/columns/{column_id}", response_model=Dict)
def update_column(column_id: str, data: ColumnUpdate):
    column = db.get_column(column_id)
    if not column:
        raise HTTPException(status_code=404, detail="Column not found")

    db.update_column(column_id, data.name, data.color)
    return db.get_column(column_id)


@app.delete("/api/columns/{column_id}")
def delete_column(
    column_id: str,
    move_to_column_id: Optional[str] = Query(
        None, description="Target column ID to move cards to"
    ),
):
    column = db.get_column(column_id)
    if not column:
        raise HTTPException(status_code=404, detail="Column not found")

    cards = db.get_cards_by_column(column_id)
    if cards and not move_to_column_id:
        raise HTTPException(
            status_code=400,
            detail=f"Column has {len(cards)} cards. Provide move_to_column_id or delete cards first",
        )

    if move_to_column_id:
        target_column = db.get_column(move_to_column_id)
        if not target_column:
            raise HTTPException(status_code=404, detail="Target column not found")
        if target_column["project_id"] != column["project_id"]:
            raise HTTPException(
                status_code=400,
                detail="Target column must belong to the same project",
            )

    db.delete_column(column_id, move_to_column_id)
    return {"status": "deleted"}


class ColumnPositionUpdate(BaseModel):
    positions: List[Dict[str, Any]]  # [{"id": "xxx", "position": 1}, ...]


@app.patch("/api/columns/{column_id}/position", response_model=Dict)
def reorder_columns(column_id: str, data: ColumnPositionUpdate):
    if not data.positions:
        raise HTTPException(status_code=400, detail="No positions provided")

    source_column = db.get_column(column_id)
    if not source_column:
        raise HTTPException(status_code=404, detail="Column not found")

    project_id = source_column["project_id"]

    # 验证所有列都属于同一项目
    for item in data.positions:
        col = db.get_column(item["id"])
        if not col:
            raise HTTPException(
                status_code=404, detail=f"Column {item['id']} not found"
            )
        if col["project_id"] != project_id:
            raise HTTPException(
                status_code=400, detail="All columns must belong to the same project"
            )

    db.reorder_columns(data.positions)
    return {"status": "reordered"}


@app.get("/api/columns/{column_id}/cards", response_model=List[Dict])
def get_column_cards(column_id: str):
    return db.get_cards_by_column(column_id)


@app.post("/api/cards", response_model=Dict)
def create_card(data: CardCreate):
    card_id = db.create_card(
        data.column_id, data.title, data.description, data.position
    )

    if embedding_service.is_available():
        emb = embedding_service.compute_card_embedding(
            data.title, data.description or ""
        )
        if emb:
            db.upsert_card_embedding(card_id, emb)

    return {"id": card_id, "title": data.title}


@app.get("/api/cards/{card_id}", response_model=Dict)
def get_card(card_id: str):
    card = db.get_card(card_id)
    if not card:
        raise HTTPException(status_code=404, detail="Card not found")
    return card


@app.put("/api/cards/{card_id}", response_model=Dict)
def update_card(card_id: str, data: CardUpdate):
    db.update_card(card_id, data.title, data.description)

    if embedding_service.is_available() and data.title:
        card = db.get_card(card_id)
        if card:
            emb = embedding_service.compute_card_embedding(
                data.title, data.description or ""
            )
            if emb:
                db.upsert_card_embedding(card_id, emb)

    return {"id": card_id}


@app.delete("/api/cards/{card_id}")
def delete_card(card_id: str):
    db.delete_card(card_id)
    return {"status": "deleted"}


@app.patch("/api/cards/{card_id}/move", response_model=Dict)
def move_card(card_id: str, data: CardMove):
    db.move_card(card_id, data.target_column_id, data.target_position)
    return {"id": card_id}


@app.get("/api/cards/{card_id}/session", response_model=List[Dict])
def get_session_history(card_id: str, limit: int = 50):
    return db.get_session_history(card_id, limit)


@app.post("/api/cards/{card_id}/session", response_model=Dict)
def add_session_message(card_id: str, data: SessionMessage):
    db.add_session_message(card_id, data.role, data.content, data.metadata)
    return {"status": "added"}


@app.get("/api/projects/{project_id}/timeline", response_model=List[Dict])
def get_timeline(project_id: str, limit: int = 100):
    return db.get_timeline(project_id, limit)


@app.post("/api/search", response_model=List[Dict])
def search_cards(data: SearchQuery):
    if data.mode == "semantic":
        if not embedding_service.is_available():
            raise HTTPException(
                status_code=503, detail="Embedding service not available"
            )
        emb = embedding_service.get_embedding(data.query)
        if not emb:
            raise HTTPException(status_code=500, detail="Failed to compute embedding")
        return db.search_cards_semantic(emb, data.project_id, data.limit)
    else:
        return db.search_cards_fts(data.query, data.project_id, data.limit)


@app.get("/api/projects/{project_id}/summaries", response_model=List[Dict])
def get_summaries(project_id: str):
    return db.get_all_summaries(project_id)


@app.post("/api/cards/{card_id}/summary", response_model=Dict)
def save_summary(card_id: str, summary: str):
    db.save_summary(card_id, summary)
    return {"status": "saved"}


@app.get("/api/cards/{card_id}/summary", response_model=Dict)
def get_summary(card_id: str):
    summary = db.get_summary(card_id)
    if not summary:
        raise HTTPException(status_code=404, detail="Summary not found")
    return summary


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
