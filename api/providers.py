import json
import os
from fastapi import APIRouter
from api.models import ProviderListResponse
from api.dependencies import HTTPError

router = APIRouter(prefix="/api", tags=["providers"])


def _load_config():
    config_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "acp_config.json"
    )
    config_path = os.path.normpath(config_path)
    try:
        with open(config_path, "r") as f:
            return json.load(f)
    except Exception as e:
        raise HTTPError(500, f"Failed to load acp_config.json: {e}")


@router.get("/providers", response_model=ProviderListResponse)
async def get_providers():
    config = _load_config()
    return {
        "providers": config.get("providers", []),
        "default_provider": config.get("default_provider", "gemini"),
    }


@router.get("/providers/init-status")
async def get_provider_init_status(project_id: str):
    import run_bridge
    bridge = run_bridge.bridge_instance
    if not bridge:
        raise HTTPError(503, "Bridge not connected")
    return await bridge.dispatcher._handle_provider_init_status({"project_id": project_id}, None)


@router.post("/providers/{provider_id}/initialize")
async def initialize_provider(provider_id: str):
    import run_bridge
    bridge = run_bridge.bridge_instance
    if not bridge:
        raise HTTPError(503, "Bridge not connected")
    return await bridge.dispatcher.initialize_provider(provider_id)
