from fastapi import APIRouter, HTTPException, Query, BackgroundTasks
from typing import Optional
import os
import json
from datetime import datetime
from src.logic.engine import SessionEngine, SummaryService
from src.transport.bus import bus
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

    target_column = validate_column_exists(request.column_id, db)

    try:
        # Phase 5.3 FIX: Respect column's provider setting
        # Use request provider if explicitly provided, otherwise use column's provider
        provider_id = request.acp_provider_id
        if provider_id is None:
            provider_id = target_column.get("acp_provider_id")

        if provider_id:
            providers = {p["id"]: p for p in _load_config().get("providers", [])}
            if provider_id not in providers:
                raise HTTPError(400, f"Unknown provider: {provider_id}")

        card_id = db.create_card(
            column_id=request.column_id,
            title=request.title,
            description=request.description or "",
            feature_id=request.feature_id,
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
            feature_id=request.feature_id,
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
        # Phase 5.3: Compare column providers directly as requested
        old_column_provider = source_column.get("acp_provider_id")
        target_column_provider = target_column.get("acp_provider_id")
        provider_changed = old_column_provider != target_column_provider

        # CRITICAL: Move the card first (must succeed)
        db.move_card(
            card_id=card_id,
            target_column_id=request.target_column_id,
            target_position=request.target_position,
        )

        # Update card provider to match target column
        db.update_card_provider(card_id, target_column_provider)

        # NON-CRITICAL: Session management - wrap in try/except so it doesn't break the move
        try:
            if provider_changed:
                # Clear session ID if provider changed to force re-initialization
                db.update_card_session_id(card_id, None)
                
                # Record milestone message about the change
                old_name = old_column_provider or "Default"
                new_name = target_column_provider or "Default"
                db.add_session_message(
                    card_id=card_id,
                    role="assistant",
                    content=f"🔄 **Agent switched** from `{old_name}` to `{new_name}` due to column move. A new session will be established on your next message.",
                    is_milestone=True
                )
                
            # Notify clients about the update
            bus.publish(card_id, {"type": "refresh"})

            # Phase 3: Trigger summary generation with transition context
            async def summarize_move_background(card_id: str, from_col: str, to_col: str):
                try:
                    await generate_card_summary_task(card_id)
                    db = get_db()
                    card = db.get_card(card_id)
                    if not card: return

                    summary_obj = db.summaries.get(card_id)
                    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
                    transition_header = f"> 🔄 Moved from **{from_col}** to **{to_col}** at {now_str}\n\n"
                    
                    if summary_obj:
                        wrapped_summary = f"{transition_header}{summary_obj['summary']}"
                    else:
                        # Fallback if no history yet
                        basic_info = f"Title: {card['title']}\nDescription: {card.get('description', '')}"
                        wrapped_summary = f"{transition_header}{basic_info}"
                    
                    # Sync to card display ONLY if NOT completed
                    sync_to_card = card.get("status") != "completed"
                    db.update_card_summary(card_id, wrapped_summary, sync_to_card=sync_to_card)
                    
                    if sync_to_card:
                        bus.publish(card_id, {"type": "refresh"})
                        
                except Exception as e:
                    print(f"[ERROR] Failed to generate summary for moved card {card_id}: {e}")

            background_tasks.add_task(summarize_move_background, card_id, source_column["name"], target_column["name"])
        except Exception as e:
            print(f"[WARN] Non-critical post-move operations failed: {e}")

        card = db.get_card(card_id)
        if not card:
            raise HTTPError(404, "Card not found after move")
        return format_card_response(card)
    except HTTPException:
        raise
    except HTTPError:
        raise
    except Exception as e:
        print(f"[ERROR] Card move failed: {e}")
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
    import asyncio
    from src.logger import setup_logger
    logger = setup_logger("CompleteCard")
    
    db = get_db()
    card = validate_card_exists(card_id, db)

    # Avoid redundant processing if already completed
    if card.get("status") == "completed":
        return format_card_response(card)

    try:
        db.complete_card(card_id)
        
        # Trigger summary generation in background (non-blocking)
        # Use asyncio.create_task to ensure it runs even in Bridge/Proxy mode
        async def generate_summary_bg():
            try:
                logger.info(f"[Complete Card] Starting summary generation for card {card_id}")
                await generate_card_summary_task(card_id, max_retries=2)
                
                # Fetch generated summary and ensure it's NOT synced to card front
                summary_obj = db.summaries.get(card_id)
                if summary_obj:
                    # Sync to card is FALSE for completed cards
                    db.update_card_summary(card_id, summary_obj['summary'], sync_to_card=False)
                    logger.info(f"[Complete Card] Summary generated and archived (not synced to UI) for card {card_id}")
                else:
                    logger.warning(f"[Complete Card] No summary generated for card {card_id}")
            except Exception as e:
                logger.error(f"[Complete Card] Error generating summary for card {card_id}: {e}")
        
        # Schedule the task to run in the background
        asyncio.create_task(generate_summary_bg())

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
        return {"card_id": card_id, "summary": ""}

    return summary


@router.put("/cards/{card_id}/summary", response_model=dict)
async def update_card_summary(card_id: str, request: dict):
    """
    Update the summary for a card manually.
    """
    db = get_db()
    validate_card_exists(card_id, db)

    summary_text = request.get("summary")
    if summary_text is None:
        raise HTTPError(400, "summary field is required")

    try:
        db.summaries.upsert(card_id, summary_text)
        return {"card_id": card_id, "summary": summary_text}
    except Exception as e:
        raise HTTPError(400, str(e))


@router.post("/cards/{card_id}/summary/generate", response_model=dict)
async def generate_card_summary_manual(card_id: str):
    """
    Manually trigger summary generation for a card.
    This endpoint waits for the summary generation to complete (with timeout).
    """
    import asyncio
    from src.logger import setup_logger
    logger = setup_logger("ManualSummary")
    
    db = get_db()
    validate_card_exists(card_id, db)

    try:
        logger.info(f"[Manual Summary] Starting summary generation for card {card_id}")
        
        # Run the summary generation task with a timeout
        await asyncio.wait_for(
            generate_card_summary_task(card_id, max_retries=2),
            timeout=60.0  # 60 second timeout
        )
        
        # Check if summary was generated
        summary_obj = db.summaries.get(card_id)
        if summary_obj:
            logger.info(f"[Manual Summary] Summary generated successfully for card {card_id}")
            return {"message": "Summary generated successfully", "summary": summary_obj.get("summary", "")}
        else:
            logger.warning(f"[Manual Summary] No summary generated for card {card_id} (possibly no messages)")
            return {"message": "No messages to summarize. Summary requires conversation history.", "summary": ""}
            
    except asyncio.TimeoutError:
        logger.error(f"[Manual Summary] Timeout generating summary for card {card_id}")
        raise HTTPError(504, "Summary generation timed out. Please try again.")
    except Exception as e:
        logger.error(f"[Manual Summary] Error generating summary for card {card_id}: {e}")
        raise HTTPError(500, f"Failed to generate summary: {str(e)}")


@router.get("/cards/{card_id}/related")
async def get_related_cards(
    card_id: str,
    limit: int = Query(5, ge=1, le=20),
):
    """
    Get related cards from the same project using semantic search if available.
    """
    from src.persistence.embedding import embedding_service
    
    db = get_db()
    card = validate_card_exists(card_id, db)
    project_id = card.get("project_id")
    if not project_id:
        return {"cards": [], "total": 0}

    related_cards = []
    
    # Try semantic search first
    if embedding_service.is_available():
        card_text = f"{card['title']} {card.get('description', '')}"
        query_vector = embedding_service.get_embedding(card_text)
        if query_vector:
            # Search in summaries for better semantic context
            results = db.summaries.search_semantic(query_vector, project_id, limit=limit + 1)
            # Map back to card details and exclude self
            for s in results:
                if s["card_id"] != card_id:
                    c = db.get_card(s["card_id"])
                    if c:
                        c["card_summary"] = s["summary"]
                        related_cards.append(c)
                if len(related_cards) >= limit:
                    break

    # Fallback to recent cards in project if semantic search didn't yield enough
    if len(related_cards) < limit:
        already_added = {c["id"] for c in related_cards}
        already_added.add(card_id)
        
        with db.get_connection() as conn:
            cursor = conn.execute(
                """SELECT c.id, c.title, c.description, c.status, c.column_id, c.position,
                        c.created_at, c.updated_at, col.name as column_name, col.project_id,
                        s.summary as card_summary
                FROM cards c
                JOIN columns col ON col.id = c.column_id
                LEFT JOIN summaries s ON s.card_id = c.id
                WHERE col.project_id = ? AND c.id NOT IN ({})
                ORDER BY s.updated_at DESC NULLS LAST, c.updated_at DESC
                LIMIT ?""".format(",".join(["?"] * len(already_added))),
                (project_id, *already_added, limit - len(related_cards)),
            )
            fallback_cards = [dict(row) for row in cursor.fetchall()]
            related_cards.extend(fallback_cards)

    return {
        "cards": [
            {
                "id": c["id"],
                "title": c["title"],
                "description": c.get("description", ""),
                "status": c.get("status", "active"),
                "column_id": c["column_id"],
                "column_name": c.get("column_name", ""),
                "summary": c.get("card_summary"),
                "updated_at": c["updated_at"],
            }
            for c in related_cards
        ],
        "total": len(related_cards),
    }
