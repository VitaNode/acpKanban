import json
from typing import Dict, Any, Optional
import re
from datetime import datetime

class AGUIMapper:
    """
    Maps standard ACP notifications to AG-UI events.
    Ensures semantic continuity across different UI protocols.
    """
    
    @staticmethod
    def map_history_message(msg: Dict[str, Any]) -> Dict[str, Any]:
        """
        Maps legacy history message format to AG-UI bundled event.
        """
        role = msg.get("role", "assistant")
        content = msg.get("content", "")
        
        raw_metadata = msg.get("metadata")
        metadata = {}
        if isinstance(raw_metadata, str):
            try:
                metadata = json.loads(raw_metadata)
            except Exception:
                metadata = {}
        elif isinstance(raw_metadata, dict):
            metadata = raw_metadata
            
        created_at = msg.get("created_at", "")
        is_complete = msg.get("is_complete", True)
        
        # Handle role='tool' messages
        if role == "tool":
            tc_name = metadata.get("name") or metadata.get("tool", "unknown")
            tc_args = metadata.get("arguments")
            result = content
            
            cmd_preview = metadata.get("command_preview")
            file_targets = metadata.get("file_targets", [])
            op_kind = metadata.get("op_kind", "other")
            diff = metadata.get("diff")
            
            if not cmd_preview:
                extracted = AGUIMapper._extract_tool_metadata(tc_name, tc_args)
                cmd_preview = extracted.get("command_preview")
                file_targets = extracted.get("file_targets", [])
                op_kind = extracted.get("op_kind", "other")
                diff = extracted.get("diff")
            
            tool_call = {
                "tool_id": metadata.get("tool_id"),
                "tool": tc_name,
                "name": cmd_preview or tc_name,
                "args": tc_args,
                "result": result,
                "status": metadata.get("status", "completed"),
                "command_preview": cmd_preview,
                "file_targets": file_targets,
                "op_kind": op_kind,
                "diff": diff,
            }
            
            return {
                "event": "message_bundled",
                "role": "tool",
                "text": "",
                "timestamp": created_at,
                "is_complete": is_complete,
                "tool_calls": [tool_call]
            }
        
        ag_event = {
            "event": "message_bundled",
            "role": role,
            "text": content,
            "timestamp": created_at,
            "is_complete": is_complete
        }
        
        if metadata.get("type") == "reasoning":
            ag_event["reasoning"] = content
            ag_event["text"] = ""
        
        thought = metadata.get("thought")
        if thought:
            if ag_event.get("reasoning"):
                ag_event["reasoning"] += "\n" + thought
            else:
                ag_event["reasoning"] = thought
        
        tool_calls = []
        
        meta_tool_calls = metadata.get("tool_calls")
        if meta_tool_calls and isinstance(meta_tool_calls, list):
            for tc in meta_tool_calls:
                tc_args = tc.get("arguments") or tc.get("args")
                extracted = AGUIMapper._extract_tool_metadata(tc.get("tool") or tc.get("name"), tc_args)
                
                tool_calls.append({
                    "tool_id": tc.get("tool_id"),
                    "tool": tc.get("tool") or tc.get("name"),
                    "name": tc.get("name") or extracted.get("command_preview") or tc.get("tool"),
                    "args": tc_args,
                    "result": tc.get("result"),
                    "status": tc.get("status", "completed"),
                    **extracted
                })
        
        if tool_calls:
            ag_event["tool_calls"] = tool_calls
        
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
                        "content": e.get("content", ""),
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
                        "category": o.get("category", "general"),
                        "type": o.get("type", "select"),
                        "currentValue": o.get("currentValue"),
                        "options": o.get("options", [])
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
            if status in ("pending", "running", "in_progress"):
                event_type = "tool_call_start"
            elif status in ("completed", "success"):
                event_type = "tool_call_result"
            else:  # failed, cancelled, etc.
                event_type = "tool_call_result"
            
            # Extract args from rawInput (contains the tool parameters)
            args_dict = update.get("rawInput")
            args_text = None
            if args_dict and isinstance(args_dict, dict):
                try:
                    args_text = json.dumps(args_dict, indent=2)
                except Exception:
                    args_text = str(args_dict)
            
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
                        elif "text" in item:
                            text_parts.append(item["text"])
                if text_parts:
                    result_text = "\n".join(text_parts)
            
            # Fallback to rawOutput.output if no content extracted
            if not result_text:
                raw_output = update.get("rawOutput")
                if raw_output and isinstance(raw_output, dict):
                    output = raw_output.get("output")
                    if output:
                        result_text = output
            
            tool_name = update.get("tool")
            extracted = AGUIMapper._extract_tool_metadata(tool_name, args_dict or args_text)
            
            ag_event.update({
                "event": event_type,
                "tool_id": update.get("toolCallId"),
                "tool": tool_name,
                "name": update.get("title") or extracted.get("command_preview") or tool_name,
                "status": AGUIMapper._map_tool_status(status),
                "args": args_text,
                "result": result_text,
                **extracted
            })
        elif utype == "tool_call_update":
            status = update.get("status", "running")
            
            # Extract args from rawInput if available
            args_dict = update.get("rawInput")
            args_text = None
            if args_dict and isinstance(args_dict, dict):
                try:
                    args_text = json.dumps(args_dict, indent=2)
                except Exception:
                    args_text = str(args_dict)
            
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
                        elif "text" in item:
                            text_parts.append(item["text"])
                if text_parts:
                    result_text = "\n".join(text_parts)
            
            if not result_text:
                raw_output = update.get("rawOutput")
                if raw_output and isinstance(raw_output, dict):
                    output = raw_output.get("output")
                    if output:
                        result_text = output
            
            tool_name = update.get("tool")
            extracted = AGUIMapper._extract_tool_metadata(tool_name, args_dict or args_text)
            
            ag_event.update({
                "event": "tool_call_update",
                "tool_id": update.get("toolCallId"),
                "tool": tool_name,
                "name": update.get("title") or extracted.get("command_preview") or tool_name,
                "status": AGUIMapper._map_tool_status(status),
                "args": args_text,
                "result": result_text,
                **extracted
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
    def _extract_tool_metadata(tool_name: Optional[str], args: Any) -> Dict[str, Any]:
        """
        Extract structured metadata from tool arguments.
        Returns: {command_preview, file_targets, op_kind, diff}
        """
        metadata = {
            "command_preview": None,
            "file_targets": [],
            "op_kind": "other",
            "diff": None
        }
        
        if not tool_name:
            return metadata
            
        # Parse args if it's a string
        args_dict = {}
        if isinstance(args, str):
            try:
                args_dict = json.loads(args)
            except Exception:
                pass
        elif isinstance(args, dict):
            args_dict = args
            
        tn = tool_name.lower()
        
        # Determine op_kind and extract fields
        if any(x in tn for x in ["read", "cat", "view", "get_file"]):
            metadata["op_kind"] = "read"
            path = args_dict.get("path") or args_dict.get("file_path") or args_dict.get("filePath")
            if path: metadata["file_targets"] = [path]
            metadata["command_preview"] = f"Read {path}" if path else "Read file"
            
        elif any(x in tn for x in ["search", "grep", "find", "glob", "list_dir"]):
            metadata["op_kind"] = "search"
            pattern = args_dict.get("pattern") or args_dict.get("query") or args_dict.get("include_pattern")
            path = args_dict.get("path") or args_dict.get("dir_path") or args_dict.get("dirPath")
            metadata["command_preview"] = f"Search '{pattern}'" if pattern else "Search"
            if path: metadata["file_targets"] = [path]
            
        elif any(x in tn for x in ["edit", "write", "replace", "apply", "patch"]):
            metadata["op_kind"] = "edit"
            path = args_dict.get("path") or args_dict.get("file_path") or args_dict.get("filePath")
            if path: metadata["file_targets"] = [path]
            
            # Extract diff info if available
            old_text = args_dict.get("old_string") or args_dict.get("oldText")
            new_text = args_dict.get("new_string") or args_dict.get("newText") or args_dict.get("content")
            if old_text or new_text:
                metadata["diff"] = {"path": path, "old": old_text, "new": new_text}
                
            metadata["command_preview"] = f"Edit {path}" if path else "Edit file"
            
        elif any(x in tn for x in ["exec", "run", "terminal", "shell", "bash"]):
            metadata["op_kind"] = "execute"
            cmd = args_dict.get("command") or args_dict.get("script") or args_dict.get("cmd")
            metadata["command_preview"] = cmd
            metadata["file_targets"] = [] # Shell commands might not have clear file targets
            
        # Specific tool handling: ACP common tools
        if tn == "glob":
            pattern = args_dict.get("pattern")
            metadata["command_preview"] = f"Glob: '{pattern}'"
        elif tn == "grep_search":
            pattern = args_dict.get("pattern")
            metadata["command_preview"] = f"Grep: '{pattern}'"
            
        return metadata

    @staticmethod
    def map_request(method: str, params: Dict[str, Any], request_id: str) -> Dict[str, Any]:
        """
        Maps an ACP request (from agent to UI) to an AG-UI interactive event.
        Used for permissions, questions, etc.
        """
        card_id = params.get("card_id")
        timestamp = params.get("timestamp") or datetime.now().isoformat()
        
        # Extract meaningful text from params
        text = params.get("message") or params.get("title") or ""
        title = params.get("title", "Action Required")
        
        ag_event = {
            "type": "ag_ui_event",
            "card_id": card_id,
            "event": "interactive_request",
            "method": method,
            "requestId": request_id,
            "timestamp": timestamp,
            "title": title,
            "text": text,
            "options": []
        }
        
        # === 新增：特殊处理 session/request_permission ===
        if method == "session/request_permission":
            tool_call = params.get("toolCall", {})
            
            # 提取标题
            if tool_call.get("title") and (title == "Action Required" or not title):
                title = tool_call.get("title")
                ag_event["title"] = title
            
            # 提取工具调用的详细内容
            tool_kind = tool_call.get("kind", "unknown")
            
            if tool_kind == "edit":
                # 文件编辑操作
                content_list = tool_call.get("content", [])
                for item in content_list:
                    if item.get("type") == "diff":
                        path = item.get("path", "unknown file")
                        old_text = item.get("oldText", "")
                        new_text = item.get("newText", "")
                        
                        # 构建可读的文本描述
                        edit_text = f"\n\n### File Operation: Edit\n\n**File:** `{path}`\n\n"
                        if old_text:
                            edit_text += f"**Current Content:**\n```\n{old_text}\n```\n"
                        edit_text += f"**New Content:**\n```\n{new_text}\n```\n"
                        if edit_text not in text:
                            text += edit_text
                        break
            
            elif tool_kind == "execute":
                # 命令执行操作
                raw_input = tool_call.get("rawInput", {})
                command = raw_input.get("command", raw_input.get("script", ""))
                exec_text = f"\n\n### Command Execution\n\n```bash\n{command}\n```\n"
                if exec_text not in text:
                    text += exec_text
            
            # --- Phase 4 Enhancement: Better details for 'other' kind ---
            elif tool_kind == "other" or tool_kind == "unknown":
                raw_input = tool_call.get("rawInput", {})
                if raw_input:
                    detail_text = "\n\n### Tool Call Details\n"
                    # Try to extract common fields
                    path = raw_input.get("filePath") or raw_input.get("path") or raw_input.get("filepath")
                    if path:
                        detail_text += f"**Target Path:** `{path}`\n"
                    
                    parent = raw_input.get("parentDir") or raw_input.get("cwd")
                    if parent:
                        detail_text += f"**Location:** `{parent}`\n"
                    
                    # If nothing else extracted, or just to be safe, show JSON
                    if len(detail_text) < 30: # Only header present
                        try:
                            detail_text += f"\n```json\n{json.dumps(raw_input, indent=2)}\n```"
                        except Exception:
                            detail_text += f"\n{raw_input}"
                    
                    if detail_text not in text:
                        text += detail_text
            # ----------------------------------------------------------

            # === 特殊处理：如果是 Plan 或具有 content blocks 的通用工具调用 ===
            tool_content = tool_call.get("content", [])
            extracted_text = ""
            if isinstance(tool_content, list) and tool_content:
                for item in tool_content:
                    # Support both item['content']['text'] and item['text']
                    c = item.get("content")
                    if isinstance(c, dict) and "text" in c:
                        extracted_text += c["text"]
                    elif isinstance(item, dict) and item.get("type") == "text":
                        extracted_text += item.get("text", "")
                    elif isinstance(item, dict) and "text" in item:
                        extracted_text += item.get("text", "")
            
            # 优先从 arguments 提取 Plan (通常最完整)
            plan_from_args = ""
            arguments = params.get("arguments")
            if isinstance(arguments, dict):
                plan_from_args = arguments.get("plan") or arguments.get("description") or ""
            
            # 合并提取的内容，避免重复
            source_text = plan_from_args or extracted_text
            if source_text:
                source_text = source_text.strip()
                # 如果当前 text 只是通用的标题，直接替换
                if not text or text.strip() == title:
                    text = source_text
                # 如果 text 中还不包含这段内容，则追加
                elif source_text not in text:
                    text += f"\n\n{source_text}"
            
            # 添加原始输入作为参考 (仅当没有提取到任何有效描述时)
            if not source_text and tool_kind == "unknown":
                raw_input = tool_call.get("rawInput", {})
                if raw_input and not any(k in text for k in (raw_input.keys() or [])):
                    try:
                        text += f"\n\n**Details:**\n```json\n{json.dumps(raw_input, indent=2)}\n```"
                    except Exception:
                        pass
        # ============================================
        
        # Map options correctly
        raw_options = params.get("options", [])
        if not raw_options:
            ag_event["options"] = [
                {"id": "allow", "label": "Allow", "primary": True},
                {"id": "deny", "label": "Deny", "primary": False}
            ]
        else:
            for opt in raw_options:
                opt_id = opt.get("id") or opt.get("optionId") or ""
                opt_label = opt.get("label") or opt.get("name") or "Option"
                ag_event["options"].append({
                    "id": opt_id,
                    "label": opt_label,
                    "primary": opt.get("primary", False) or "proceed" in opt_id or "allow" in opt_id or "restore" in opt_id
                })
        
        # If there's a plan or arguments, include them in the text
        arguments = params.get("arguments")
        if arguments:
            plan_text = ""
            if isinstance(arguments, dict):
                plan_text = arguments.get("plan") or arguments.get("description") or ""
                # Remove the plan from arguments so we don't show it twice
                other_args = {k: v for k, v in arguments.items() if k not in ("plan", "description")}
                
                if plan_text:
                    if not text or text.strip() == title:
                        text = plan_text
                    else:
                        text += f"\n\n### Proposed Plan\n{plan_text}"
                
                if other_args and not any(k in text for k in (other_args.keys() or [])):
                    try:
                        text += f"\n\n**Arguments:**\n```json\n{json.dumps(other_args, indent=2)}\n```"
                    except Exception:
                        text += f"\n\n**Arguments:** {other_args}"
            else:
                text += f"\n\n{arguments}"
        
        ag_event["text"] = text
        ag_event["title"] = title
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