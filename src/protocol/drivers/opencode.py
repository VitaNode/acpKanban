import logging
from typing import Dict, Any, Optional
from .base import BaseAgentDriver

logger = logging.getLogger("OpenCodeDriver")

class OpenCodeDriver(BaseAgentDriver):
    """
    Driver for OpenCode agents.
    """
    def translate_ui_result(self, method: str, ui_result: Dict[str, Any], original_params: Dict[str, Any]) -> Dict[str, Any]:
        if method == "session/request_permission":
            # 0. Check if it's an error response
            if isinstance(ui_result, dict) and "code" in ui_result and "message" in ui_result:
                return ui_result

            outcome = ui_result.get("outcome", {}) if isinstance(ui_result, dict) else {}
            
            if outcome.get("cancelled"):
                logger.info("[OpenCodeDriver] UI returned cancelled")
                return self.build_cancel_response()

            option_id = outcome.get("optionId")
            agent_options = original_params.get("options", [])
            
            logger.debug(f"[OpenCodeDriver] Translating UI result: optionId={option_id}, agent_options={[o.get('optionId') for o in agent_options]}")
            
            # 1. Exact match priority
            for opt in agent_options:
                if opt.get("optionId") == option_id:
                    logger.info(f"[OpenCodeDriver] Exact match found for {option_id}")
                    return self.build_permission_response(option_id)

            # 2. Semantic mapping (kind-based)
            # Map standard UI 'once' to agent's 'allow_once' kind, etc.
            target_kind = None
            if option_id in ("allow", "once", "allow_once"):
                target_kind = "allow_once"
            elif option_id in ("always", "allow_always"):
                target_kind = "allow_always"
            elif option_id in ("deny", "reject", "reject_once"):
                target_kind = "reject_once"

            if target_kind:
                for opt in agent_options:
                    if opt.get("kind") == target_kind:
                        logger.info(f"[OpenCodeDriver] Semantic match found: mapped {option_id} to {opt.get('optionId')} (kind: {target_kind})")
                        return self.build_permission_response(opt.get("optionId"))

            # 3. Fallback semantic mapping (keyword-based)
            if option_id:
                normalized_id = str(option_id).lower()
                for opt in agent_options:
                    opt_id = str(opt.get("optionId", "")).lower()
                    if normalized_id in opt_id or opt_id in normalized_id:
                        logger.info(f"[OpenCodeDriver] Keyword match found: mapped {option_id} to {opt.get('optionId')}")
                        return self.build_permission_response(opt.get("optionId"))

            # 4. Final fallback: Use original result but wrapped
            if option_id:
                logger.warning(f"[OpenCodeDriver] No mapping found for {option_id}, returning as-is (wrapped)")
                return self.build_permission_response(option_id)
            
            logger.error(f"[OpenCodeDriver] Completely unhandled UI result: {ui_result}")
            # Use base class for final wrapping of whatever we have
            return super().translate_ui_result(method, ui_result, original_params)
            
        return ui_result
