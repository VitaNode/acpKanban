from fastapi import FastAPI, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional
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
    """Lifecycle events for the API."""
    logger.info("API Server Starting Up...")
    
    # Check if we should start the integrated bridge
    # For standalone API, this is usually False unless specifically enabled
    if os.getenv("START_INTEGRATED_BRIDGE") == "true" or True:
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
        asyncio.create_task(bridge.start(run_forever=False))
        
    yield
    
    logger.info("API Server Shutting Down...")
    await task_manager.shutdown()

app = FastAPI(
    title="acpKanban API",
    description="Backend for Agent-integrated Kanban system",
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

# Include Routers
app.include_router(cards_router, dependencies=[Depends(require_api_token)])
app.include_router(projects_router, dependencies=[Depends(require_api_token)])
app.include_router(sessions_router, dependencies=[Depends(require_api_token)])
app.include_router(providers_router, dependencies=[Depends(require_api_token)])

@app.middleware("http")
async def add_request_id(request: Request, call_next):
    request_id = str(asyncio.current_task().get_name())
    set_request_id(request_id)
    try:
        response = await call_next(request)
        return response
    finally:
        clear_context()

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


class SystemConfigRequest(BaseModel):
    api_key: Optional[str] = None
    base_url: Optional[str] = None
    summary_model: Optional[str] = None
    embedding_model: Optional[str] = None


@app.post("/api/system/config")
async def update_system_config(
    request: SystemConfigRequest, 
    token_valid: bool = Depends(require_api_token)
):
    """Update server-side system configuration."""
    from src.config.manager import config
    logger.info(f"Updating system_agent config: {request.model_dump(exclude_unset=True)}")
    config.update_system_agent(
        api_key=request.api_key,
        base_url=request.base_url,
        summary_model=request.summary_model,
        embedding_model=request.embedding_model
    )
    return {"status": "ok"}


@app.get("/api/system/config")
async def get_system_config(token_valid: bool = Depends(require_api_token)):
    """Expose system configuration via REST (useful when Bridge/WebSocket is not connected)."""
    # Prefer ConfigManager as the source of truth
    from src.config.manager import config
    
    api_key = config.system_agent_api_key
    
    return {
        "provider_id": "openai",
        "api_key": api_key,
        "base_url": config.system_agent_base_url,
        "summary_model": config.summary_model,
        "embedding_model": config.embedding_model,
        # Keep providers for compatibility
        "providers": config.get("providers.list", []),
        "default_provider": config.get("providers.default", "gemini")
    }


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
        if projects is None: overall_healthy = False
    except Exception as e:
        health["subsystems"]["database"] = f"error: {str(e)}"
        overall_healthy = False

    bridge = run_bridge.bridge_instance
    if bridge:
        health["subsystems"]["bridge"] = "connected" if bridge.relay_ws else "idle"
        if bridge.relay_url:
            health["subsystems"]["relay"] = bridge.relay_url

    if not overall_healthy:
        health["status"] = "degraded"
    
    return health
health
