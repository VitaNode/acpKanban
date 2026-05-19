import json
import traceback
from functools import wraps
from typing import Optional
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from src.persistence.database import KanbanDB


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


from src.config.manager import config

from starlette.requests import HTTPConnection

def require_api_token(request: HTTPConnection):
    # Check for X-API-Token header or token query parameter
    # Works for both Request (HTTP) and WebSocket (WS)
    token = request.headers.get("X-API-Token") or request.query_params.get("token")
    
    if token != config.api_token:
        raise HTTPException(status_code=401, detail="Unauthorized")

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
        "status": card.get("status") or "active",
        "plan_status": card.get("plan_status") or "plan",
        "feature_id": card.get("feature_id"),
        "completed_at": card.get("completed_at"),
        "parent_id": card.get("parent_id"),
        "session_count": card.get("session_count", 0),
        "acp_session_id": card.get("acp_session_id"),
        "acp_provider_id": card.get("acp_provider_id"),
        "input_tokens": card.get("input_tokens", 0),
        "output_tokens": card.get("output_tokens", 0),
        "summary": card.get("last_summary"),
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
        "is_complete": msg.get("is_complete", True),
        "seq_id": msg.get("seq_id"),
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


from src.utils.error_codes import ErrorCode

class HTTPError(HTTPException):
    def __init__(self, status_code: int, detail: str, error_code: ErrorCode = ErrorCode.INTERNAL_ERROR):
        super().__init__(status_code=status_code, detail=detail)
        self.error_code = error_code


async def http_exception_handler(request: Request, exc: HTTPException):
    error_code = getattr(exc, "error_code", ErrorCode.INTERNAL_ERROR)
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": "HTTPException",
            "message": exc.detail,
            "error_code": error_code
        },
    )


async def general_exception_handler(request: Request, exc: Exception):
    _logger = logging.getLogger("Kanban")
    _logger.error(f"Unhandled exception for {request.method} {request.url.path}\n{traceback.format_exc()}")

    return JSONResponse(
        status_code=500,
        content={
            "error": "InternalServerError",
            "message": str(exc),
            "error_code": ErrorCode.INTERNAL_ERROR
        },
    )


def error_response(status_code: int, message: str, error_code: ErrorCode):
    """Helper to return standardized error JSONResponse."""
    return JSONResponse(
        status_code=status_code,
        content={
            "error": "APIError",
            "message": message,
            "error_code": error_code
        }
    )
