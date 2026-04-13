from fastapi import APIRouter, HTTPException, Query, BackgroundTasks
from typing import Optional
import os
import json
from src.logic.engine import SummaryService
from api.models import (
    CardCreateRequest,
    CardUpdateRequest,
    CardMoveRequest,
    CardResponse,
    CardListResponse,
    SessionMessageRequest,
    SessionMessageResponse,
    SessionHistoryResponse,
    ProjectTimelineResponse,
    TimelineEventResponse,
    SuccessResponse,
)
from api.dependencies import (
    get_db,
    validate_card_exists,
    validate_column_exists,
    validate_project_exists,
    format_card_response,
    format_session_message,
    format_timeline_event,
    HTTPError,
)
from api.tasks import generate_card_summary_task

router = APIRouter(prefix="/api", tags=["cards"])


def _load_config():
    config_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "acp_config.json"
    )
    config_path = os.path.normpath(config_path)
    try:
        with open(config_path, "r") as f:
            return json.load(f)
    except Exception:
        return {"default_provider": "gemini", "providers": []}


@router.post("/cards", response_model=CardResponse, status_code=201)
async def create_card(request: CardCreateRequest):
    """
    Create a new card in a specified column.
    """
    db = get_db()

    validate_column_exists(request.column_id, db)

    try:
        provider_id = request.acp_provider_id
        if not provider_id:
            config = _load_config()
            provider_id = config.get("default_provider", "gemini")

        providers = {p["id"]: p for p in _load_config().get("providers", [])}
        if provider_id not in providers:
            raise HTTPError(400, f"Unknown provider: {provider_id}")

        card_id = db.create_card(
            column_id=request.column_id,
            title=request.title,
            description=request.description or "",
        )
        db.update_card_provider(card_id, provider_id)

        card = db.get_card(card_id)
        if not card:
            raise HTTPError(500, "Failed to create card")
        return format_card_response(card)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/cards/{card_id}", response_model=CardResponse)
async def get_card(card_id: str):
    """
    Get a card by ID.
    """
    db = get_db()
    card = validate_card_exists(card_id, db)
    return format_card_response(card)


@router.put("/cards/{card_id}", response_model=CardResponse)
async def update_card(card_id: str, request: CardUpdateRequest):
    """
    Update a card's title and/or description.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    try:
        db.update_card(
            card_id=card_id,
            title=request.title,
            description=request.description,
        )
        card = db.get_card(card_id)
        if not card:
            raise HTTPError(404, "Card not found after update")
        return format_card_response(card)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.delete("/cards/{card_id}")
async def delete_card(card_id: str):
    """
    Delete a card.
    """
    db = get_db()
    card = validate_card_exists(card_id, db)

    try:
        db.delete_card(card_id)
        return {"message": f"Card '{card['title']}' deleted successfully"}
    except Exception as e:
        raise HTTPError(400, str(e))

@router.patch("/cards/{card_id}/move", response_model=CardResponse)
async def move_card(card_id: str, request: CardMoveRequest, background_tasks: BackgroundTasks):
    """
    Move a card to a different column and/or position.
    """
    db = get_db()
    card = validate_card_exists(card_id, db)
    target_column = validate_column_exists(request.target_column_id, db)

    source_column = db.get_column(card["column_id"])
    if source_column["project_id"] != target_column["project_id"]:
        raise HTTPError(400, "Card and target column must belong to the same project")

    try:
        db.move_card(
            card_id=card_id,
            target_column_id=request.target_column_id,
            target_position=request.target_position,
        )

        # Phase 3: Trigger summary generation in background
        summary_service = SummaryService(db)
        background_tasks.add_task(summary_service.generate_and_save_summary, card_id)

        card = db.get_card(card_id)
        if not card:
            raise HTTPError(404, "Card not found after move")
        return card
        return format_card_response(card)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPError(400, str(e))


@router.put("/cards/{card_id}/acp-session", response_model=dict)
async def update_card_acp_session(card_id: str, request: dict):
    """
    Update the ACP session ID associated with a card.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    session_id = request.get("session_id")
    if not session_id:
        raise HTTPError(400, "session_id is required")

    try:
        db.update_card_session_id(card_id, session_id)
        card = db.get_card(card_id)
        return {
            "card_id": card_id,
            "acp_session_id": card.get("acp_session_id"),
        }
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/cards/{card_id}/session", response_model=SessionHistoryResponse)
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


@router.post("/cards/{card_id}/session", response_model=SessionMessageResponse)
async def add_session_message(card_id: str, request: SessionMessageRequest):
    """
    Add a message to the card's conversation history.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    try:
        db.add_session_message(
            card_id=card_id,
            role=request.role.value,
            content=request.content,
            metadata=request.metadata,
        )
        messages = db.get_session_history(card_id, 1)
        if not messages:
            raise HTTPError(500, "Failed to add message")
        return format_session_message(messages[0])
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/projects/{project_id}/timeline", response_model=ProjectTimelineResponse)
async def get_project_timeline(
    project_id: str,
    limit: int = Query(100, ge=1, le=500),
    card_id: Optional[str] = Query(None, description="Filter by card ID"),
):
    """
    Get the timeline events for a project (read-only).
    """
    db = get_db()
    project = validate_project_exists(project_id, db)

    events = db.get_timeline(project_id, limit)

    if card_id:
        events = [e for e in events if e.get("card_id") == card_id]

    return {
        "project_id": project_id,
        "project_name": project.get("name"),
        "events": [format_timeline_event(e) for e in events],
        "total": len(events),
    }


@router.get("/columns/{column_id}/cards", response_model=CardListResponse)
async def get_cards_by_column(
    column_id: str,
    include_completed: bool = Query(False),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    """
    Get all cards in a specific column.
    """
    db = get_db()
    validate_column_exists(column_id, db)

    cards = db.get_cards_by_column(column_id, include_completed=include_completed)
    total = len(cards)
    cards = cards[offset : offset + limit]

    return {
        "cards": [format_card_response(c) for c in cards],
        "total": total,
    }


@router.patch("/cards/{card_id}/complete", response_model=CardResponse)
async def complete_card(card_id: str, background_tasks: BackgroundTasks):
    """
    Mark a card as completed and trigger summary generation.
    """
    db = get_db()
    card = validate_card_exists(card_id, db)

    # Avoid redundant processing if already completed
    if card.get("status") == "completed":
        return format_card_response(card)

    try:
        db.complete_card(card_id)
        background_tasks.add_task(generate_card_summary_task, card_id)

        updated_card = db.get_card(card_id)
        return format_card_response(updated_card)
    except Exception as e:
        raise HTTPError(400, str(e))


@router.patch("/cards/{card_id}/uncomplete", response_model=CardResponse)
async def uncomplete_card(card_id: str):
    """
    Mark a card as active again.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    try:
        db.uncomplete_card(card_id)
        updated_card = db.get_card(card_id)
        return format_card_response(updated_card)
    except Exception as e:
        raise HTTPError(400, str(e))


@router.get("/cards/{card_id}/summary", response_model=dict)
async def get_card_summary(card_id: str):
    """
    Get the summary generated for a card.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    summary = db.get_summary(card_id)
    if not summary:
        raise HTTPError(404, "Summary not found for this card")

    return summary


@router.get("/cards/{card_id}/related", response_model=CardListResponse)
async def get_related_cards(
    card_id: str,
    limit: int = Query(5, ge=1, le=20),
):
    """
    Get related cards based on summary embedding similarity.
    """
    db = get_db()
    card = validate_card_exists(card_id, db)

    summary_obj = db.get_summary(card_id)
    if not summary_obj:
        # If no summary, try semantic search with card title/description
        from src.persistence.embedding import embedding_service
        emb = embedding_service.compute_card_embedding(card['title'], card.get('description', ''))
    else:
        from src.persistence.embedding import embedding_service
        emb = embedding_service.get_embedding(summary_obj['summary'])

    if not emb:
        return {"cards": [], "total": 0}

    related = db.search_cards_semantic(emb, project_id=card.get('project_id'), limit=limit + 1)
    # Filter out current card
    filtered_related = [c for c in related if c['id'] != card_id][:limit]

    return {
        "cards": [format_card_response(c) for c in filtered_related],
        "total": len(filtered_related),
    }
