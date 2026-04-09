from fastapi import APIRouter, HTTPException, Query
from typing import Optional
from pydantic import BaseModel, Field
from api.dependencies import (
    get_db,
    validate_card_exists,
    format_session_message,
    HTTPError,
)

router = APIRouter(prefix="/api", tags=["sessions"])


class SessionMessageRequest(BaseModel):
    role: str = Field(..., pattern="^(user|assistant|system)$")
    content: str = Field(..., min_length=1)
    metadata: Optional[dict] = None


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1)
    card_id: Optional[str] = None


class ChatResponse(BaseModel):
    message: str
    card_id: Optional[str] = None


@router.get("/cards/{card_id}/session", response_model=dict)
async def get_session_history(
    card_id: str,
    limit: int = Query(50, ge=1, le=200),
):
    """
    Get the conversation history for a card.
    """
    db = get_db()
    card = validate_card_exists(card_id, db)

    messages = db.get_session_history(card_id, limit)
    return {
        "card_id": card_id,
        "card_title": card.get("title"),
        "messages": [format_session_message(msg) for msg in messages],
        "total": len(messages),
    }


@router.post("/cards/{card_id}/session", response_model=dict)
async def add_session_message(card_id: str, request: SessionMessageRequest):
    """
    Add a message to the card's conversation history.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    try:
        db.add_session_message(
            card_id=card_id,
            role=request.role,
            content=request.content,
            metadata=request.metadata,
        )
        messages = db.get_session_history(card_id, 1)
        if not messages:
            raise HTTPError(500, "Failed to add message")
        return format_session_message(messages[0])
    except Exception as e:
        raise HTTPError(400, str(e))


@router.delete("/cards/{card_id}/session")
async def clear_session(card_id: str):
    """
    Clear the session history for a card (from database only).
    """
    db = get_db()
    card = validate_card_exists(card_id, db)

    try:
        with db.get_connection() as conn:
            conn.execute("DELETE FROM card_sessions WHERE card_id = ?", (card_id,))
            conn.commit()
        return {"message": f"Session history cleared for card '{card['title']}'"}
    except Exception as e:
        raise HTTPError(400, str(e))


@router.delete("/projects/{project_id}/sessions")
async def clear_project_sessions(project_id: str):
    """
    Clear all session histories for cards in a project.
    """
    db = get_db()
    from api.projects import validate_project_exists

    validate_project_exists(project_id, db)

    try:
        with db.get_connection() as conn:
            cursor = conn.execute(
                """
                DELETE FROM card_sessions 
                WHERE card_id IN (
                    SELECT c.id FROM cards c 
                    JOIN columns col ON col.id = c.column_id 
                    WHERE col.project_id = ?
                )
            """,
                (project_id,),
            )
            conn.commit()
            deleted_count = cursor.rowcount
            return {"message": f"Cleared {deleted_count} session messages from project"}
    except Exception as e:
        raise HTTPError(400, str(e))
