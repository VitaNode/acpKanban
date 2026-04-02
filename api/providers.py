import json
import os
from fastapi import APIRouter
from api.models import ProviderListResponse
from api.dependencies import HTTPError

router = APIRouter(prefix="/api", tags=["providers"])


def _load_config():
    config_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "acp_config.json"
    )
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
