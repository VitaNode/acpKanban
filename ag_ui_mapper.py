from typing import Dict, Any, Optional

class AGUIMapper:
    """
    Maps ACP protocol messages to AG-UI compliant events.
    Reference: https://docs.ag-ui.com/
    """
    
    @staticmethod
    def map_notification(acp_data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """
        Converts an ACP notification to an AG-UI event.
        """
        method = acp_data.get("method")
        
        # 1. Request Permission -> input_request (Requires Approval)
        # ACP sends this as a request, so it has an 'id' and 'method'
        if method == "session/request_permission":
            params = acp_data.get("params", {})
            return {
                "type": "ag_ui/input_request",
                "payload": {
                    "id": acp_data.get("id"),
                    "kind": "confirmation",
                    "title": "Approval Required",
                    "message": params.get("message", "Agent wants to perform an action.")
                }
            }

        # Remaining events are mostly notifications (no id)
        if method != "session/update":
            return None
            
        update = acp_data.get("params", {}).get("update", {})
        update_type = update.get("sessionUpdate")
        
        # 2. Content Chunks -> content_block
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
            
        # 3. Tool Calls -> progress_update
        elif update_type == "tool_call":
            return {
                "type": "ag_ui/progress_update",
                "payload": {
                    "status": "in_progress",
                    "label": f"Calling tool: {update.get('name') or update.get('tool')}",
                    "id": update.get("toolCallId")
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
