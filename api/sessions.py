import json
import asyncio
import uuid
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
                notif = await queue.get()
                await websocket.send_text(json.dumps(notif))
                queue.task_done()
        except asyncio.CancelledError:
            pass
        except WebSocketDisconnect:
            pass
        except Exception as e:
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
                config_opts = db.get_card_config_options(card_id)
                response = {
                    "type": "history",
                    "messages": [format_session_message(m) for m in history]
                }
                # Include config options if available from DB
                if config_opts:
                    try:
                        response["config_options"] = json.loads(config_opts)
                    except:
                        pass
                await websocket.send_text(json.dumps(response))
            
            elif msg_type == "send_message":
                role = message.get("role", "user")
                content = message.get("content", "")
                print(f"DEBUG: Received message for card {card_id}: {content[:30]}...")
                
                # We no longer add message to DB here, Dispatcher will handle it
                # to avoid duplication.
                
                # Forward to Bridge Dispatcher for AI processing
                try:
                    import run_bridge
                    bridge_instance = run_bridge.bridge_instance
                    if bridge_instance:
                        # Construct the dispatcher request
                        prompt_data = {
                            "jsonrpc": "2.0",
                            "id": str(uuid.uuid4()), # Need an ID for tracking
                            "method": "session/prompt",
                            "params": {
                                "card_id": card_id,
                                "message": content,
                            }
                        }
                        # Run in background task
                        async def process_with_bridge():
                            try:
                                # The Dispatcher's forward_notif already calls bus.publish()
                                # for each notification. The on_output callback is used for
                                # UI requests (tool permissions). We pass a no-op that only
                                # handles actual UI requests, not regular notifications.
                                async def _bridge_ui_output(msg_or_method, *args):
                                    # Support both bridge.py (dict) and dispatcher.py (method, params) calls
                                    if args:
                                        method, params = msg_or_method, args[0]
                                    elif isinstance(msg_or_method, dict):
                                        method = msg_or_method.get("method")
                                        params = msg_or_method.get("params", {})
                                    else:
                                        return # Ignore unknown formats

                                    if method == "session/request_permission" or method.startswith("fs/") or method.startswith("terminal/"):
                                        rid = params.get("id") or str(uuid.uuid4())
                                        fut = asyncio.get_event_loop().create_future()
                                        bridge_instance._pending_ui_requests[rid] = fut
                                        print(f"DEBUG: Publishing UI request {method} (rid: {rid}) to bus for card {card_id}")
                                        bus.publish(card_id, {
                                            "type": "ui_request",
                                            "id": rid,
                                            "method": method,
                                            "params": params
                                        })
                                        try:
                                            return await asyncio.wait_for(fut, timeout=300.0)
                                        except asyncio.TimeoutError:
                                            bridge_instance._pending_ui_requests.pop(rid, None)
                                            return {"error": {"code": -32000, "message": "UI Request Timeout"}}
                                    # Regular notifications - ignore (already handled by bus.publish)

                                await bridge_instance.handle_rpc(
                                    prompt_data,
                                    _bridge_ui_output
                                )
                            except Exception as e:
                                import traceback
                                print(f"\n❌ Bridge processing error:\n{traceback.format_exc()}")
                                bus.publish(card_id, {"type": "error", "message": str(e)})
                        asyncio.create_task(process_with_bridge())
                except Exception as e:
                    print(f"DEBUG: Failed to forward to bridge: {e}")
            
            elif msg_type == "set_config_option":
                # Phase 5.2: Route config change to dispatcher (CRIT-2 FIX)
                from src.transport.bridge import UnifiedBridge
                name = message.get("name")
                value = message.get("value")
                
                import run_bridge
                bridge_instance = run_bridge.bridge_instance
                if bridge_instance:
                    await bridge_instance.dispatcher.handle_set_config_option(card_id, name, value)

            elif msg_type == "rpc_response":
                # Phase 3.2: Forward response back to the specific bridge/dispatcher request
                import run_bridge
                bridge_instance = run_bridge.bridge_instance
                rid = message.get("id")
                result = message.get("result")
                if bridge_instance and rid:
                    # The dispatcher manages pending tool/permission requests
                    # and will resolve the future associated with this ID
                    await bridge_instance.on_ui_response(rid, result)

            elif msg_type == "session_init":
                import run_bridge
                bridge_instance = run_bridge.bridge_instance
                if bridge_instance:
                    try:
                        # 1. Start engine in Quiet mode (discovery only)
                        # Phase 5.3 FIX: Must pass is_quiet=True to the creation method as well
                        engine, _ = await bridge_instance.dispatcher._get_or_create_engine(card_id, is_quiet=True)
                        res = await engine.start(is_quiet=True)
                        
                        # 2. Notify client (Milestone will be added on first prompt)
                        await websocket.send_text(json.dumps({
                            "type": "session_info",
                            "sessionId": engine.acp_session_id,
                            "config_options": engine.current_config_options,
                            "is_alive": True
                        }))
                    except Exception as e:
                        print(f"ERROR in session_init: {e}")
                        await websocket.send_text(json.dumps({
                            "type": "error",
                            "message": f"Initialization failed: {str(e)}"
                        }))

            elif msg_type == "get_context":
                import run_bridge
                bridge_instance = run_bridge.bridge_instance
                if bridge_instance:
                    try:
                        engine = bridge_instance.dispatcher.engines.get(card_id)
                        column_prompt = None
                        if engine and engine.column_id:
                            column = await asyncio.to_thread(db.columns.get_by_id, engine.column_id)
                            if column:
                                column_prompt = column.get("prompt_template")
                        
                        context = await bridge_instance.dispatcher.context_builder.build_initial_context(card_id, column_prompt=column_prompt)
                        await websocket.send_text(json.dumps({
                            "type": "context_data",
                            "card_id": card_id,
                            "context": context
                        }))
                    except Exception as e:
                        print(f"ERROR in get_context: {e}")
                        await websocket.send_text(json.dumps({
                            "type": "error",
                            "message": f"Failed to get context: {str(e)}"
                        }))

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
