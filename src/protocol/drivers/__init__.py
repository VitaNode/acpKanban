from .base import BaseAgentDriver
from .gemini import GeminiDriver
from .qwen import QwenDriver
from .opencode import OpenCodeDriver

def get_driver(provider_id: str) -> BaseAgentDriver:
    """
    Factory function to get the appropriate driver for a provider.
    """
    p_id = (provider_id or "").lower()
    
    if "qwen" in p_id:
        return QwenDriver(provider_id)
    elif "opencode" in p_id:
        return OpenCodeDriver(provider_id)
    elif "gemini" in p_id:
        return GeminiDriver(provider_id)
    
    # Default to base driver
    return BaseAgentDriver(provider_id)
