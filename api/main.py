from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from contextlib import asynccontextmanager
import sys
import os

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
    try:
        db = get_db()
        db.get_projects()
        print("[*] Kanban API started successfully")
    except Exception as e:
        print(f"[!] Failed to initialize database: {e}")
    yield
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
