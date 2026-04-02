import json
from functools import wraps
from typing import Optional
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from database import KanbanDB


db_instance: Optional[KanbanDB] = None


def get_db() -> KanbanDB:
    global db_instance
    if db_instance is None:
        db_instance = KanbanDB()
    return db_instance


def validate_project_exists(project_id: str, db: KanbanDB):
    project = db.get_project(project_id)
    if not project:
        raise HTTPException(404, f"Project '{project_id}' not found")
    return project


def validate_column_exists(column_id: str, db: KanbanDB):
    column = db.get_column(column_id)
    if not column:
        raise HTTPException(404, f"Column '{column_id}' not found")
    return column


def validate_card_exists(card_id: str, db: KanbanDB):
    card = db.get_card(card_id)
    if not card:
        raise HTTPException(404, f"Card '{card_id}' not found")
    return card


def parse_metadata(metadata_str: Optional[str]) -> Optional[dict]:
    if not metadata_str:
        return None
    try:
        return json.loads(metadata_str)
    except (json.JSONDecodeError, TypeError):
        return None


def format_card_response(card: dict) -> dict:
    return {
        "id": card.get("id"),
        "column_id": card.get("column_id"),
        "title": card.get("title"),
        "description": card.get("description") or "",
        "position": card.get("position", 0),
        "session_count": card.get("session_count", 0),
        "acp_session_id": card.get("acp_session_id"),
        "acp_provider_id": card.get("acp_provider_id"),
        "created_at": card.get("created_at"),
        "updated_at": card.get("updated_at"),
        "column_name": card.get("column_name"),
        "project_id": card.get("project_id"),
    }


def format_session_message(msg: dict) -> dict:
    return {
        "id": msg.get("id"),
        "card_id": msg.get("card_id"),
        "role": msg.get("role"),
        "content": msg.get("content") or "",
        "metadata": parse_metadata(msg.get("metadata")),
        "created_at": msg.get("created_at"),
    }


def format_timeline_event(event: dict) -> dict:
    return {
        "id": event.get("id"),
        "project_id": event.get("project_id"),
        "card_id": event.get("card_id"),
        "card_title": event.get("card_title"),
        "event_type": event.get("event_type"),
        "content": event.get("content"),
        "metadata": parse_metadata(event.get("metadata")),
        "timestamp": event.get("timestamp"),
    }


class HTTPError(HTTPException):
    def __init__(self, status_code: int, detail: str):
        super().__init__(status_code=status_code, detail=detail)


async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": "HTTPException", "message": exc.detail},
    )


async def general_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={
            "error": "InternalServerError",
            "message": str(exc),
        },
    )
