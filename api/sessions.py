import json
import asyncio
from fastapi import APIRouter, HTTPException, Query, WebSocket, WebSocketDisconnect
from typing import Optional, List, Dict
from pydantic import BaseModel, Field
from api.dependencies import (
    get_db,
    validate_card_exists,
    format_session_message,
    HTTPError,
)
from src.transport.bus import bus

router = APIRouter(prefix="/api", tags=["sessions"])

class SessionMessageRequest(BaseModel):
    role: str = Field(..., pattern="^(user|assistant|system)$")
    content: str = Field(..., min_length=1)
    metadata: Optional[dict] = None

@router.websocket("/ws/session/{card_id}")
async def session_websocket(websocket: WebSocket, card_id: str):
    await websocket.accept()
    db = get_db()
    
    # Subscribe to the notification bus for THIS card
    queue = bus.subscribe(card_id)
    
    async def listen_to_bus():
        try:
            while True:
                # Get message from bus
                notif = await queue.get()
                # Send to Flutter
                await websocket.send_text(json.dumps(notif))
                queue.task_done()
        except Exception:
            pass

    # Start background listener for bus
    bus_task = asyncio.create_task(listen_to_bus())

    try:
        while True:
            # Handle incoming client messages (heartbeat, history req, etc)
            data = await websocket.receive_text()
            message = json.loads(data)
            msg_type = message.get("type")

            if msg_type == "get_history":
                history = db.get_session_history(card_id)
                await websocket.send_text(json.dumps({
                    "type": "history",
                    "messages": [format_session_message(m) for m in history]
                }))
            
            elif msg_type == "send_message":
                role = message.get("role", "user")
                content = message.get("content", "")
                db.add_session_message(card_id, role, content)
                # No need to send message_added, history reload will handle it via refresh notif
            
            elif msg_type == "ping":
                await websocket.send_text(json.dumps({"type": "pong"}))

    except WebSocketDisconnect:
        pass
    finally:
        bus_task.cancel()
        bus.unsubscribe(card_id, queue)

@router.get("/cards/{card_id}/session", response_model=dict)
async def get_session_history(card_id: str, limit: int = Query(50, ge=1, le=200)):
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
    db = get_db()
    validate_card_exists(card_id, db)
    try:
        db.add_session_message(card_id=card_id, role=request.role, content=request.content, metadata=request.metadata)
        messages = db.get_session_history(card_id, 1)
        if not messages: raise HTTPError(500, "Failed to add message")
        # Notify via bus so active WebSockets refresh
        bus.publish(card_id, {"type": "refresh"})
        return format_session_message(messages[0])
    except Exception as e: raise HTTPError(400, str(e))

@router.delete("/cards/{card_id}/session")
async def clear_session(card_id: str):
    db = get_db()
    card = validate_card_exists(card_id, db)
    try:
        with db.get_connection() as conn:
            conn.execute("DELETE FROM card_sessions WHERE card_id = ?", (card_id,))
            conn.commit()
        bus.publish(card_id, {"type": "refresh"})
        return {"message": f"Session cleared"}
    except Exception as e: raise HTTPError(400, str(e))
