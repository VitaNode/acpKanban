from typing import Dict, Any, Optional
import re

class AGUIMapper:
    """
    Maps standard ACP notifications to AG-UI events.
    Ensures semantic continuity across different UI protocols.
    """
    
    # Regex pattern for extracting tool call markers from legacy content
    # Matches: 🛠️ tool_name(args): result
    TOOL_MARKER_PATTERN = re.compile(r'🛠️\s+(\w+)\(([^)]*)\):\s*(.+)')
    
    @staticmethod
    def map_history_message(msg: Dict[str, Any]) -> Dict[str, Any]:
        """
        Maps legacy history message format to AG-UI bundled event.
        
        Supports:
        - Plain text messages
        - Messages with thought metadata
        - Smart extraction of tool call markers from content
        
        Args:
            msg: Legacy message dict with keys: role, content, metadata, created_at, is_complete
            
        Returns:
            AG-UI bundled event dict
        """
        role = msg.get("role", "assistant")
        content = msg.get("content", "")
        metadata = msg.get("metadata") or {}
        created_at = msg.get("created_at", "")
        is_complete = msg.get("is_complete", True)
        
        # Base event structure
        ag_event = {
            "event": "message_bundled",
            "role": role,
            "text": content,
            "timestamp": created_at,
            "is_complete": is_complete
        }
        
        # Extract thought from metadata if present
        thought = metadata.get("thought")
        if thought:
            ag_event["reasoning"] = thought
        
        # Smart tool extraction from content (Scheme B: Intelligent parsing)
        tool_calls = []
        clean_text = content
        
        for match in AGUIMapper.TOOL_MARKER_PATTERN.finditer(content):
            tool_name = match.group(1)
            tool_args = match.group(2)
            tool_result = match.group(3)
            
            tool_calls.append({
                "tool": tool_name,
                "args": tool_args,
                "result": tool_result,
                "status": "completed"  # Historical messages are always completed
            })
            
            # Remove the tool marker from clean text
            clean_text = clean_text.replace(match.group(0), f"[{tool_name} completed]")
        
        if tool_calls:
            ag_event["tool_calls"] = tool_calls
            ag_event["text"] = clean_text
        
        return ag_event
    
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
        elif utype == "tool_call_update":
            ag_event.update({
                "event": "tool_status_update",
                "tool_id": update.get("toolCallId"),
                "status": update.get("status"),
                "content": update.get("content", [])
            })
        elif utype == "session_info_update":
            info = update.get("info", {})
            ag_event.update({
                "event": "session_info_update",
                "title": info.get("title"),
                "description": info.get("description"),
                "updated_at": info.get("updatedAt")
            })
        elif utype == "stop":
            ag_event.update({"event": "session_stop"})
        else:
            return None

        return ag_event
