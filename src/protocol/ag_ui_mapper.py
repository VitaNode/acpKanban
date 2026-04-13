from typing import Dict, Any, Optional

class AGUIMapper:
    """
    Maps standard ACP notifications to AG-UI events.
    Ensures semantic continuity across different UI protocols.
    """
    @staticmethod
    def map_notification(acp_notif: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        method = acp_notif.get("method")
        params = acp_notif.get("params", {})
        update = params.get("update", {})
        utype = update.get("sessionUpdate")
        card_id = params.get("card_id")

        if not utype:
            return None

        # Base mapping
        ag_event = {
            "type": "ag_ui_event",
            "card_id": card_id,
            "timestamp": params.get("timestamp")
        }

        if utype == "agent_message_chunk":
            ag_event.update({
                "event": "message_chunk",
                "role": "assistant",
                "text": update.get("content", {}).get("text", "")
            })
        elif utype == "plan":
            ag_event.update({
                "event": "plan_update",
                "steps": [
                    {
                        "label": e.get("content", ""),
                        "status": e.get("status", "pending"),
                        "priority": e.get("priority", "medium")
                    } for e in update.get("entries", [])
                ]
            })
        elif utype == "config_option_update":
            ag_event.update({
                "event": "config_update",
                "options": [
                    {
                        "id": o.get("id"),
                        "name": o.get("name"),
                        "value": o.get("currentValue")
                    } for o in update.get("availableOptions", [])
                ]
            })
        elif utype == "available_commands_update":
            ag_event.update({
                "event": "commands_update",
                "commands": update.get("availableCommands", [])
            })
        elif utype == "tool_call":
            ag_event.update({
                "event": "tool_status",
                "tool_id": update.get("toolCallId"),
                "name": update.get("title") or update.get("tool"),
                "status": update.get("status", "pending")
            })
        elif utype == "stop":
            ag_event.update({"event": "session_stop"})
        else:
            return None

        return ag_event
