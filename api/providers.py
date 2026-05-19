import json
import os
from fastapi import APIRouter, Query, Path
from api.models import ProviderListResponse
from api.dependencies import HTTPError
from src.config.manager import config

router = APIRouter(prefix="/api", tags=["providers"])


@router.get("/providers", response_model=ProviderListResponse)
async def get_providers():
    providers_list = config.get("providers.list", [])
    default_provider = config.get("providers.default", "gemini")
    return {
        "providers": providers_list,
        "default_provider": default_provider,
    }


@router.get("/providers/init-status")
async def get_provider_init_status(
    project_id: str = Query(..., min_length=1, max_length=50, description="The ID of the project to check")
):
    import run_bridge
    bridge = run_bridge.bridge_instance
    if not bridge:
        raise HTTPError(503, "Bridge not connected")
    return await bridge.dispatcher._handle_provider_init_status({"project_id": project_id}, None)


@router.post("/providers/{provider_id}/initialize")
async def initialize_provider(
    provider_id: str = Path(..., min_length=1, max_length=50, description="The ID of the provider to initialize")
):
    import run_bridge
    bridge = run_bridge.bridge_instance
    if not bridge:
        raise HTTPError(503, "Bridge not connected")
    return await bridge.dispatcher.initialize_provider(provider_id)
