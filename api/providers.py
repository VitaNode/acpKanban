import json
import os
from fastapi import APIRouter, Query, Path
from api.models import ProviderListResponse
from api.dependencies import HTTPError

router = APIRouter(prefix="/api", tags=["providers"])


def _load_config():
    config_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "config.json"
    )
    config_path = os.path.normpath(config_path)
    try:
        with open(config_path, "r") as f:
            config = json.load(f)
        providers_config = config.get("providers", {})
        return {
            "providers": providers_config.get("list", []),
            "default_provider": providers_config.get("default", "gemini"),
        }
    except Exception as e:
        raise HTTPError(500, f"Failed to load provider config: {e}")


@router.get("/providers", response_model=ProviderListResponse)
async def get_providers():
    config = _load_config()
    return {
        "providers": config.get("providers", []),
        "default_provider": config.get("default_provider", "gemini"),
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
