from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from contextlib import asynccontextmanager
import sys
import os
import asyncio

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from api.cards import router as cards_router
from api.projects import router as projects_router
from api.sessions import router as sessions_router
from api.providers import router as providers_router
from api.dependencies import (
    get_db,
    http_exception_handler,
    general_exception_handler,
    HTTPError,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Performance Optimization: Only initialize if needed
    try:
        db = get_db()
        # Ensure all tables exist (including settings, summaries, etc.)
        db.init_db()
        print("[*] Kanban API started successfully (DB Connected)")
        
        # Phase 5.1: Integrated Bridge Startup
        # This ensures the API and Bridge share the same NotificationBus
        import run_bridge
        from src.transport.bridge import UnifiedBridge
        
        # In a real app, these would come from config or env
        user_id = os.getenv("MYBOT_USER_ID", "test_user")
        relay_url = os.getenv("MYBOT_RELAY_URL", "ws://35.211.219.123:8766")
        token = os.getenv("MYBOT_TOKEN", "8c939a7d-e31b-4e1d-b26c-57b4589519e1")
        workspace_cwd = os.getenv("MYBOT_WORKSPACE_CWD")
        
        print(f"[*] Starting Integrated Bridge for user: {user_id}")
        bridge = UnifiedBridge(user_id, relay_url, token=token, workspace_cwd=workspace_cwd)
        # Set the global bridge_instance so sessions.py can find it
        run_bridge.bridge_instance = bridge
        
        # Start bridge without blocking
        asyncio.create_task(bridge.start(run_forever=False))
        
    except Exception as e:
        print(f"[!] Startup initialization failed: {e}")
        import traceback
        traceback.print_exc()
        
    yield
    
    # Shutdown logic
    import run_bridge
    from api.projects import index_task_manager
    
    # 1. Cancel all background indexing tasks
    print("[*] Cleaning up background indexing tasks...")
    for pid in list(index_task_manager._tasks.keys()):
        await index_task_manager.cancel_task(pid)

    if run_bridge.bridge_instance:
        print("[*] Stopping Integrated Bridge...")
        await run_bridge.bridge_instance.shutdown()
        await run_bridge.bridge_instance.stop()
    print("[*] Kanban API shutdown")


app = FastAPI(
    title="Kanban API",
    description="Agent Kanban REST API - Card Management",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_exception_handler(HTTPError, http_exception_handler)
app.add_exception_handler(Exception, general_exception_handler)

app.include_router(cards_router)
app.include_router(projects_router)
app.include_router(sessions_router)
app.include_router(providers_router)


@app.get("/")
async def root():
    return {
        "service": "Kanban API",
        "version": "1.0.0",
        "endpoints": {
            "projects": "/api/projects",
            "cards": "/api/cards",
            "columns": "/api/columns/{id}/cards",
            "timeline": "/api/projects/{id}/timeline",
            "health": "/health",
        },
    }


@app.get("/api/system/config")
async def get_system_config():
    """Expose system configuration via REST (useful when Bridge/WebSocket is not connected)."""
    db = get_db()
    config_str = db.get_setting("system_config", "{}")
    try:
        import json
        config = json.loads(config_str)
        # Mask API key for security if needed, but here it's used for validation
        # Actually, for validation we just need to know if it exists
        return config
    except:
        return {}


@app.get("/health")
async def health_check():
    try:
        db = get_db()
        db.get_projects()
        return {"status": "healthy", "service": "kanban-api", "database": "ok"}
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content={"status": "unhealthy", "service": "kanban-api", "error": str(e)},
        )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
