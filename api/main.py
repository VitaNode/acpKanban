from fastapi import FastAPI, Request, Depends
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
    require_api_token,
)
from src.config.manager import config


from src.logger import setup_logger, set_request_id, clear_context
from src.utils.error_codes import ErrorCode
from src.utils.task_manager import task_manager

logger = setup_logger("API")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Performance Optimization: Only initialize if needed
    try:
        db = get_db()
        # Ensure all tables exist (including settings, summaries, etc.)
        db.init_db()
        logger.info("Kanban API started successfully (DB Connected)")
        
        # Phase 5.1: Integrated Bridge Startup
        # This ensures the API and Bridge share the same NotificationBus
        import run_bridge
        from src.transport.bridge import UnifiedBridge
        
        # Pull credentials from central ConfigManager
        # Prefer env vars for All-in-One launcher support
        user_id = os.getenv("USER_ID") or config.user_id
        relay_url = os.getenv("RELAY_URL") or config.relay_url
        token = os.getenv("RELAY_TOKEN") or config.relay_token
        workspace_cwd = os.getenv("MYBOT_WORKSPACE_CWD")
        
        logger.info(f"Starting Integrated Bridge for user: {user_id} (Relay: {relay_url or 'None'})")
        bridge = UnifiedBridge(user_id, relay_url, token=token, workspace_cwd=workspace_cwd)
        # Set the global bridge_instance so sessions.py can find it
        run_bridge.bridge_instance = bridge
        
        # Start bridge without blocking
        task_manager.start_task("bridge", bridge.start(run_forever=False))

        # Phase: Global Optimization - Pre-warm providers for the current project on startup
        current_project_id = db.get_setting("current_project_id")
        if current_project_id:
            logger.info(f"Proactively pre-warming providers for current project: {current_project_id}")
            task_manager.start_task("pre_warm", bridge.dispatcher.pre_warm_providers(current_project_id))
        
    except Exception as e:
        logger.error(f"Startup initialization failed: {e}", exc_info=True)
        
    yield
    
    # Shutdown logic
    import run_bridge
    
    # 1. Cancel all background tasks via TaskManager
    logger.info("Cleaning up background tasks...")
    await task_manager.shutdown()

    if run_bridge.bridge_instance:
        logger.info("Stopping Integrated Bridge...")
        await run_bridge.bridge_instance.shutdown()
        await run_bridge.bridge_instance.stop()
    logger.info("Kanban API shutdown")


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

# Apply global API token protection to all functional routes
app.include_router(cards_router, dependencies=[Depends(require_api_token)])
app.include_router(projects_router, dependencies=[Depends(require_api_token)])
app.include_router(sessions_router, dependencies=[Depends(require_api_token)])
app.include_router(providers_router, dependencies=[Depends(require_api_token)])


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
async def get_system_config(token_valid: bool = Depends(require_api_token)):
    """Expose system configuration via REST (useful when Bridge/WebSocket is not connected)."""
    db = get_db()
    config_str = db.get_setting("system_config", "{}")
    try:
        import json
        config = json.loads(config_str)
        # Mask API key for security if needed, but here it's used for validation
        # Actually, for validation we just need to know if it exists
        return config
    except (json.JSONDecodeError, KeyError):
        return {}


@app.get("/health")
async def health_check():
    import run_bridge
    import src.persistence.database as db_mod

    health = {
        "status": "healthy",
        "service": "kanban-api",
        "subsystems": {
            "database": "unknown",
            "bridge": "disconnected",
            "relay": "unknown"
        }
    }
    overall_healthy = True
    try:
        db = get_db()
        projects = db.get_projects()
        health["subsystems"]["database"] = "ok" if projects is not None else "error"
        if projects is None:
            overall_healthy = False
    except Exception as e:
        health["subsystems"]["database"] = f"error: {e}"
        overall_healthy = False

    try:
        if run_bridge.bridge_instance:
            bridge = run_bridge.bridge_instance
            health["subsystems"]["bridge"] = "connected"
            health["subsystems"]["relay"] = "connected" if hasattr(bridge, '_running') and bridge._running else "disconnected"
        else:
            health["subsystems"]["bridge"] = "not_initialized"
    except Exception as e:
        health["subsystems"]["bridge"] = f"error: {e}"
        overall_healthy = False

    if not overall_healthy:
        return JSONResponse(
            status_code=503,
            content={
                "status": "unhealthy",
                "service": "kanban-api",
                "subsystems": health["subsystems"],
                "error_code": ErrorCode.INTERNAL_ERROR
            },
        )

    health["status"] = "healthy"
    return health


if __name__ == "__main__":
    import uvicorn

    # Use host from config (defaults to 127.0.0.1 for security)
    uvicorn.run(app, host=config.api_bind_host, port=8000)
