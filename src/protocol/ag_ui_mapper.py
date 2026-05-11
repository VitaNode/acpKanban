import json
from typing import Dict, Any, Optional
import re
from datetime import datetime

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
        
        # Ensure metadata is a dict
        raw_metadata = msg.get("metadata")
        metadata = {}
        if isinstance(raw_metadata, str):
            try:
                metadata = json.loads(raw_metadata)
            except:
                metadata = {}
        elif isinstance(raw_metadata, dict):
            metadata = raw_metadata
            
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
            # Map tool_call to tool_call_start/tool_call_result based on status
            status = update.get("status", "pending")
            if status in ("pending", "running"):
                event_type = "tool_call_start"
            elif status in ("completed", "success"):
                event_type = "tool_call_result"
            else:  # failed, cancelled, etc.
                event_type = "tool_call_result"
            
            # Extract args from rawInput (contains the tool parameters)
            args_text = None
            raw_input = update.get("rawInput")
            if raw_input and isinstance(raw_input, dict):
                # Convert rawInput dict to a readable string representation
                # Prioritize 'content' field for file operations
                if "content" in raw_input:
                    args_text = f"content: {raw_input['content']}"
                    if "filePath" in raw_input:
                        args_text += f"\nfilePath: {raw_input['filePath']}"
                elif "path" in raw_input:
                    args_text = f"path: {raw_input['path']}"
                # Fallback: convert entire dict to JSON string
                if not args_text:
                    try:
                        args_text = json.dumps(raw_input, indent=2)
                    except:
                        args_text = str(raw_input)
            
            # Extract result from content array or rawOutput
            result_text = None
            content = update.get("content", [])
            if content and isinstance(content, list):
                # Extract text from content blocks
                text_parts = []
                for item in content:
                    if isinstance(item, dict):
                        item_content = item.get("content", {})
                        if isinstance(item_content, dict) and "text" in item_content:
                            text_parts.append(item_content["text"])
                if text_parts:
                    result_text = "\n".join(text_parts)
            
            # Fallback to rawOutput.output if no content extracted
            if not result_text:
                raw_output = update.get("rawOutput")
                if raw_output and isinstance(raw_output, dict):
                    output = raw_output.get("output")
                    if output:
                        result_text = output
            
            ag_event.update({
                "event": event_type,
                "tool_id": update.get("toolCallId"),
                "tool": update.get("tool"),
                "name": update.get("title") or update.get("tool"),
                "status": AGUIMapper._map_tool_status(status),
                "args": args_text,
                "result": result_text
            })
        elif utype == "tool_call_update":
            status = update.get("status", "running")
            
            # Extract args from rawInput if available (may be missing if already sent in tool_call)
            args_text = None
            raw_input = update.get("rawInput")
            if raw_input and isinstance(raw_input, dict):
                if "content" in raw_input:
                    args_text = f"content: {raw_input['content']}"
                    if "filePath" in raw_input:
                        args_text += f"\nfilePath: {raw_input['filePath']}"
                elif "path" in raw_input:
                    args_text = f"path: {raw_input['path']}"
                if not args_text:
                    try:
                        args_text = json.dumps(raw_input, indent=2)
                    except:
                        args_text = str(raw_input)
            
            # Extract result from content array or rawOutput
            result_text = None
            content = update.get("content", [])
            if content and isinstance(content, list):
                text_parts = []
                for item in content:
                    if isinstance(item, dict):
                        item_content = item.get("content", {})
                        if isinstance(item_content, dict) and "text" in item_content:
                            text_parts.append(item_content["text"])
                if text_parts:
                    result_text = "\n".join(text_parts)
            
            if not result_text:
                raw_output = update.get("rawOutput")
                if raw_output and isinstance(raw_output, dict):
                    output = raw_output.get("output")
                    if output:
                        result_text = output
            
            ag_event.update({
                "event": "tool_call_update",
                "tool_id": update.get("toolCallId"),
                "status": AGUIMapper._map_tool_status(status),
                "args": args_text,
                "result": result_text
            })
        elif utype == "agent_thought_chunk":
            ag_event.update({
                "event": "reasoning_message",
                "role": "assistant",
                "reasoning": update.get("content", {}).get("text", ""),
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
    
    @staticmethod
    def map_request(method: str, params: Dict[str, Any], request_id: str) -> Dict[str, Any]:
        """
        Maps an ACP request (from agent to UI) to an AG-UI interactive event.
        Used for permissions, questions, etc.
        """
        card_id = params.get("card_id")
        timestamp = params.get("timestamp") or datetime.now().isoformat()
        
        ag_event = {
            "type": "ag_ui_event",
            "card_id": card_id,
            "event": "interactive_request",
            "method": method,
            "requestId": request_id,
            "timestamp": timestamp,
            "title": params.get("title", "Action Required"),
            "text": params.get("message", ""),
            "options": params.get("options", [
                {"id": "allow", "label": "Allow", "primary": True},
                {"id": "deny", "label": "Deny", "primary": False}
            ])
        }
        
        # If there's a plan or arguments, include them in the text or metadata
        arguments = params.get("arguments")
        if arguments:
            if isinstance(arguments, dict):
                try:
                    args_str = json.dumps(arguments, indent=2)
                except:
                    args_str = str(arguments)
            else:
                args_str = str(arguments)
            
            # Append details to text if not already present
            if args_str not in ag_event["text"]:
                ag_event["text"] += f"\n\n```json\n{args_str}\n```"
        
        return ag_event
    
    @staticmethod
    def _map_tool_status(backend_status: str) -> str:
        """
        Map backend tool status to frontend-compatible status.
        
        Backend uses: pending, running, completed, failed
        Frontend expects: running, success, failed
        """
        status_map = {
            "pending": "running",
            "running": "running",
            "completed": "success",
            "success": "success",
            "failed": "failed",
            "cancelled": "failed",
            "error": "failed"
        }
        return status_map.get(backend_status, "running")
