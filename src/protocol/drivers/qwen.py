from typing import Dict, Any, Optional
from .base import BaseAgentDriver

class QwenDriver(BaseAgentDriver):
    """
    Driver for Qwen-based agents.
    """
    def map_notification(self, n: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        method = n.get("method")
        params = n.get("params", {})
        card_id = params.get("card_id")
        
        # Qwen specific slash commands
        if method == "_qwencode/slash_command":
            return {
                "type": "ag_ui_event",
                "card_id": card_id,
                "event": "message_chunk",
                "role": "assistant",
                "text": params.get("message", ""),
                "timestamp": params.get("timestamp")
            }
        return None

    def translate_ui_result(self, method: str, ui_result: Dict[str, Any], original_params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Qwen/OpenClaw often expect simple boolean 'allow' for some requests,
        but standardized outcome for session/request_permission.
        """
        # Call base to get standardized 'outcome': {'outcome': 'selected', 'optionId': ...}
        return super().translate_ui_result(method, ui_result, original_params)

    def extract_chunk_text(self, n: Dict[str, Any]) -> Optional[str]:
        if n.get("method") == "_qwencode/slash_command":
            return n.get("params", {}).get("message", "")
        return None
