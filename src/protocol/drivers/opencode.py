from typing import Dict, Any, Optional
from .base import BaseAgentDriver

class OpenCodeDriver(BaseAgentDriver):
    """
    Driver for OpenCode agents.
    """
    def translate_ui_result(self, method: str, ui_result: Dict[str, Any], original_params: Dict[str, Any]) -> Dict[str, Any]:
        if method == "session/request_permission":
            # The UI might return a simplified outcome or one from a standard set.
            # We need to make sure we return what the agent expects based on the options it provided.
            outcome = ui_result.get("outcome", {})
            option_id = outcome.get("optionId")
            
            # If the option_id is one of our standard ones (allow, deny, once), 
            # but the agent provided different IDs (like 'allow-once'), we should map them.
            agent_options = original_params.get("options", [])
            
            if option_id in ("allow", "once", "allow_once"):
                # Find the agent's "allow" option
                for opt in agent_options:
                    if opt.get("kind") in ("allow_once", "allow_always", "allow") or \
                       "allow" in (opt.get("optionId") or "").lower() or \
                       opt.get("optionId") == "once":
                        return {"outcome": {"optionId": opt.get("optionId")}}
            
            if option_id in ("deny", "reject", "reject_once"):
                 for opt in agent_options:
                    if opt.get("kind") in ("reject_once", "reject") or \
                       "reject" in (opt.get("optionId") or "").lower() or \
                       "deny" in (opt.get("optionId") or "").lower():
                        return {"outcome": {"optionId": opt.get("optionId")}}

            # If no mapping found, return as is
            return ui_result
            
        return ui_result
