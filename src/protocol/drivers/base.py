import json
from typing import Dict, Any, Optional, List
from datetime import datetime

class BaseAgentDriver:
    """
    Base class for agent-specific drivers.
    Encapsulates quirks in ACP implementation for different providers.
    """
    def __init__(self, provider_id: str):
        self.provider_id = provider_id

    def extract_usage(self, data: Dict[str, Any]) -> tuple[int, int]:
        """Extract input and output tokens from response data."""
        in_val, out_val = 0, 0
        
        def get_tokens(u):
            i = u.get("input_tokens") or u.get("inputTokens") or u.get("prompt_tokens") or 0
            o = u.get("output_tokens") or u.get("outputTokens") or u.get("completion_tokens") or 0
            return i, o

        # Check nested structures
        result = data.get("result") if isinstance(data.get("result"), dict) else {}
        usage = result.get("usage") or data.get("usage") or {}
        meta = result.get("_meta") or data.get("_meta") or {}

        if usage:
            i, o = get_tokens(usage)
            in_val = max(in_val, i)
            out_val = max(out_val, o)
        
        if meta:
            # Check meta usage (Common for Qwen/OpenClaw)
            m_usage = meta.get("usage", {})
            if m_usage:
                i, o = get_tokens(m_usage)
                in_val = max(in_val, i)
                out_val = max(out_val, o)
        
        return in_val, out_val

    def map_notification(self, n: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """
        Map standard ACP notification to AG-UI event.
        Overridden by specific drivers for custom message types.
        """
        return None

    def map_request(self, method: str, params: Dict[str, Any], rid: str) -> Optional[Dict[str, Any]]:
        """
        Map ACP request to AG-UI interactive event.
        """
        return None

    def translate_ui_result(self, method: str, ui_result: Dict[str, Any], original_params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Translate UI response back to the format expected by the Agent.
        
        Default implementation (ACP 1.0 style):
        Returns the result as-is.
        """
        if method == "session/request_permission":
            # 0. Check if it's an error response
            if isinstance(ui_result, dict) and "code" in ui_result and "message" in ui_result:
                # If the UI returned an error, return it as-is for the bridge to wrap
                return ui_result

            # Normalize UI results to standard ACP outcome structure
            outcome = ui_result.get("outcome", {}) if isinstance(ui_result, dict) else {}
            if outcome.get("cancelled"):
                return self.build_cancel_response()
            
            option_id = outcome.get("optionId")
            if option_id:
                return self.build_permission_response(option_id)
        
        return ui_result

    def build_permission_response(self, option_id: str) -> Dict[str, Any]:
        """
        Construct a standard ACP permission response.
        Ensures 'outcome': 'selected' is present.
        """
        return {
            "outcome": {
                "outcome": "selected",
                "optionId": option_id
            }
        }

    def build_cancel_response(self) -> Dict[str, Any]:
        """
        Construct a standard ACP cancel response.
        """
        return {
            "outcome": {
                "outcome": "cancelled"
            }
        }

    def get_yolo_option(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Return the result to be used in YOLO mode (auto-approval).
        """
        if method == "session/request_permission":
            options = params.get("options", [])
            selected_id = None
            # Prefer 'always' then 'once' then 'allow'
            for kind in ["allow_always", "allow_once", "allow"]:
                for opt in options:
                    if opt.get("kind") == kind or kind in (opt.get("optionId") or ""):
                        selected_id = opt.get("optionId")
                        break
                if selected_id: break
            
            # Fallback to first option if nothing matched
            if not selected_id and options:
                selected_id = options[0].get("optionId")
            
            if not selected_id:
                selected_id = "allow"
                
            return self.build_permission_response(selected_id)
        
        return {"status": "success"}

    def extract_chunk_text(self, n: Dict[str, Any]) -> Optional[str]:
        """Extract text from a notification chunk if it's non-standard."""
        return None
