from typing import Dict, Any, Optional

class AGUIMapper:
    """
    Maps ACP protocol messages to AG-UI compliant events.
    Reference: https://docs.ag-ui.com/
    """
    
    @staticmethod
    def map_notification(acp_data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """
        Converts an ACP session/update notification to an AG-UI event.
        """
        if acp_data.get("method") != "session/update":
            return None
            
        update = acp_data.get("params", {}).get("update", {})
        update_type = update.get("sessionUpdate")
        
        # 1. Content Chunks -> content_block
        if update_type == "agent_message_chunk":
            content = update.get("content", {})
            text = content.get("text", "") if isinstance(content, dict) else ""
            return {
                "type": "ag_ui/content_block",
                "payload": {
                    "delta": text,
                    "kind": "text"
                }
            }
            
        # 2. Tool Calls -> progress_update or input_request
        elif update_type == "tool_call":
            return {
                "type": "ag_ui/progress_update",
                "payload": {
                    "status": "in_progress",
                    "label": f"Calling tool: {update.get('name') or update.get('tool')}",
                    "id": update.get("toolCallId")
                }
            }
            
        # 3. Request Permission -> input_request (Requires Approval)
        elif acp_data.get("method") == "session/request_permission":
            return {
                "type": "ag_ui/input_request",
                "payload": {
                    "id": acp_data.get("id"),
                    "kind": "confirmation",
                    "title": "Approval Required",
                    "message": f"Agent wants to perform an action: {update.get('message', '')}"
                }
            }
            
        # 4. Stop -> turn_end
        elif update_type == "stop":
            return {
                "type": "ag_ui/turn_end",
                "payload": {
                    "reason": update.get("reason", "complete")
                }
            }
            
        return None
