from typing import Dict, Any
from .base import BaseAgentDriver

class GeminiDriver(BaseAgentDriver):
    """
    Driver for Gemini-based agents.
    """
    def extract_usage(self, data: Dict[str, Any]) -> tuple[int, int]:
        in_val, out_val = super().extract_usage(data)
        
        # Gemini specific: _meta.quota.token_count
        result = data.get("result") if isinstance(data.get("result"), dict) else {}
        meta = result.get("_meta") or data.get("_meta") or {}
        
        quota = meta.get("quota", {})
        tc = quota.get("token_count", {})
        if tc:
            i = tc.get("input_tokens") or tc.get("prompt_tokens") or 0
            o = tc.get("output_tokens") or tc.get("completion_tokens") or 0
            in_val = max(in_val, i)
            out_val = max(out_val, o)
            
        return in_val, out_val
