import asyncio
import sys
import json
import uuid
import os
import traceback
from datetime import datetime
from typing import Dict, Any, List, Optional, Set
from openai import OpenAI
from dotenv import load_dotenv
from src.persistence.database import KanbanDB
from src.persistence.embedding import embedding_service

load_dotenv()

class ACPServer:
    def __init__(self):
        self.running = True
        self.db = KanbanDB()
        self.db.init_db()
        self.lock = asyncio.Lock()

        self.api_key = os.getenv("KANBAN_API_KEY")
        if not self.api_key or self.api_key == "your_new_key_here":
            self.log("WARNING: KANBAN_API_KEY not found or default value used.")
            self.api_key = "sk-placeholder-for-init"

        self.base_url = os.getenv("KANBAN_BASE_URL", "https://api.openai.com/v1")
        self.model_id = os.getenv("KANBAN_MODEL_ID", "gpt-4o-mini")

        self.client = OpenAI(
            api_key=self.api_key, base_url=self.base_url, timeout=60.0, max_retries=2
        )

        # Sessions: {session_id: {"card_id": str, "project_id": str, "history": list, "cwd": str, "updated_at": str, "active_task": Task}}
        self._sessions: Dict[str, Dict[str, Any]] = {}
        self._responded_ids: Set[Any] = set() # N4: Deduplication
        self.allowed_workspaces: List[str] = [] 
        self.log(f"ACP Server (Brain) initialized with {self.model_id}")

    def log(self, message):
        print(f"[*] {message}", file=sys.stderr)

    def send_response(self, response_id, result=None, error=None):
        # N4: Ensure only one response per request ID
        if response_id in self._responded_ids:
            return
        
        response = {"jsonrpc": "2.0", "id": response_id}
        if error:
            response["error"] = error
        else:
            response["result"] = result
        
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()
        self._responded_ids.add(response_id)

    def send_notification(self, method: str, params: Dict[str, Any]):
        notification = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        }
        sys.stdout.write(json.dumps(notification, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    async def handle_request(self, request):
        method = request.get("method")
        params = request.get("params", {})
        request_id = request.get("id")

        try:
            if method == "initialize":
                return self.on_initialize(request_id, params)
            elif method == "session/new":
                return self.on_session_new(request_id, params)
            elif method == "session/prompt":
                session_id = params.get("sessionId")
                task = asyncio.create_task(self.on_session_prompt(request_id, params))
                if session_id in self._sessions:
                    self._sessions[session_id]["active_task"] = task
                try:
                    return await task
                finally:
                    if session_id in self._sessions:
                        self._sessions[session_id]["active_task"] = None
            elif method == "session/load":
                return await self.on_session_load(request_id, params)
            elif method == "session/list":
                return self.on_session_list(request_id)
            elif method == "session/cancel":
                return self.on_session_cancel(request_id, params)
            elif method == "health":
                return self.send_response(request_id, result={"status": "healthy"})
            elif method == "shutdown":
                self.running = False
                return self.send_response(request_id, result={})
            elif method == "chat/message":
                self.log("DEPRECATED: 'chat/message' is used. Please switch to 'session/prompt'.")
                return await self.on_session_prompt(request_id, {
                    "sessionId": params.get("card_id", "default"),
                    "prompt": [{"type": "text", "text": params.get("message", "")}]
                })
            else:
                return self.send_response(
                    request_id, error={"code": -32601, "message": f"Method {method} not found"}
                )
        except asyncio.CancelledError:
            self.log(f"Request {request_id} ({method}) was cancelled.")
            # N4: Handled by send_response deduplication
            self.send_response(request_id, error={"code": -32000, "message": "Request cancelled"})
        except Exception as e:
            self.log(f"Error handling {method}: {str(e)}\n{traceback.format_exc()}")
            self.send_response(request_id, error={"code": -32603, "message": str(e)})

    def on_initialize(self, request_id, params):
        client_version = params.get("protocolVersion", 1)
        server_version = 1 
        version = min(client_version, server_version)

        initial_cwd = params.get("cwd") or params.get("workspace_path")
        if initial_cwd:
            self.allowed_workspaces.append(os.path.abspath(initial_cwd))
            self.log(f"Anchored workspace to: {initial_cwd}")

        result = {
            "protocolVersion": version,
            "agentCapabilities": {
                "prompts": {"supported": True},
                "tools": {"list": self._get_tools_definitions()},
                "resources": {"supported": False}
            },
            "agentInfo": {
                "name": "Kanban-Brain",
                "title": "Agent Kanban Brain",
                "version": "2.0.0"
            },
            "authMethods": []
        }
        self.send_response(request_id, result=result)

    def on_session_new(self, request_id, params):
        session_id = str(uuid.uuid4())
        cwd = params.get("cwd") or os.getcwd()
        abs_cwd = os.path.abspath(cwd)

        if self.allowed_workspaces and not any(abs_cwd.startswith(w) for w in self.allowed_workspaces):
            return self.send_response(request_id, error={
                "code": -32001, 
                "message": f"Security Error: CWD {cwd} is outside allowed workspaces."
            })

        meta = params.get("_meta", {})
        card_id = None
        session_key = meta.get("sessionKey", "")
        if "kanban:" in session_key:
            card_id = session_key.split("kanban:")[-1]

        project_id = None
        if card_id:
            card = self.db.get_card(card_id)
            if card:
                project_id = card.get("project_id")

        self._sessions[session_id] = {
            "card_id": card_id,
            "project_id": project_id,
            "history": [],
            "cwd": abs_cwd,
            "status": "active",
            "updated_at": datetime.now().isoformat(),
            "active_task": None
        }
        
        self.log(f"Created session {session_id} for card {card_id} in project {project_id}")
        self.send_response(request_id, result={"sessionId": session_id})

    async def on_session_load(self, request_id, params):
        session_id = params.get("sessionId")
        
        if session_id not in self._sessions:
            with self.db.get_connection() as conn:
                cursor = conn.execute("""
                    SELECT c.id, c.project_id, p.workspace_path 
                    FROM cards c 
                    JOIN projects p ON p.id = c.project_id 
                    WHERE c.acp_session_id = ?
                """, (session_id,))
                row = cursor.fetchone()
                if row:
                    card_id, project_id, workspace_path = row[0], row[1], row[2]
                    db_history = self.db.get_session_history(card_id)
                    # N5: Recover metadata
                    history = []
                    for msg in db_history:
                        m = {
                            "role": msg["role"], 
                            "content": msg["content"]
                        }
                        if msg.get("metadata"):
                            try:
                                m["metadata"] = json.loads(msg["metadata"])
                            except: pass
                        history.append(m)

                    self._sessions[session_id] = {
                        "card_id": card_id,
                        "project_id": project_id,
                        "history": history,
                        "cwd": os.path.abspath(workspace_path or os.getcwd()),
                        "status": "active",
                        "updated_at": datetime.now().isoformat(),
                        "active_task": None
                    }
                    self.log(f"Restored session {session_id} from database (Card {card_id})")
                else:
                    return self.send_response(request_id, error={"code": -32602, "message": "Session not found"})
        
        session = self._sessions[session_id]
        history = session.get("history", [])
        
        for msg in history:
            role = msg.get("role")
            if role == "system": continue
            
            # N1: Correct nested structure
            update_type = "user_message_chunk" if role == "user" else "agent_message_chunk"
            self.send_notification("session/update", {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": update_type,
                    "content": {"type": "text", "text": msg.get("content", "")}
                }
            })
            # N2: Optional updated_at refresh
            session["updated_at"] = datetime.now().isoformat()
            
        self.send_response(request_id, result=None)

    def on_session_list(self, request_id):
        sessions = [
            {
                "sessionId": sid, 
                "title": data.get("card_id", "General Task"),
                "status": data.get("status", "active"),
                "lastUpdatedAt": data.get("updated_at")
            }
            for sid, data in self._sessions.items()
        ]
        self.send_response(request_id, result={"sessions": sessions})

    def on_session_cancel(self, request_id, params):
        session_id = params.get("sessionId")
        if session_id in self._sessions:
            task = self._sessions[session_id].get("active_task")
            if task and not task.done():
                task.cancel()
                self.log(f"Cancelled active task for session {session_id}")
                return self.send_response(request_id, result=None)
        
        return self.send_response(request_id, error={"code": -32602, "message": "No active prompt task found for session"})

    async def on_session_prompt(self, request_id, params):
        session_id = params.get("sessionId")
        prompt_blocks = params.get("prompt", [])
        
        if session_id not in self._sessions:
            return self.send_response(request_id, error={"code": -32602, "message": f"Session {session_id} not found."})

        session = self._sessions[session_id]
        session["updated_at"] = datetime.now().isoformat()
        card_id = session["card_id"]
        project_id = session["project_id"]
        
        user_text = " ".join([b.get("text", "") for b in prompt_blocks if b.get("type") == "text"])
        
        history = session["history"]
        
        system_content = self._get_system_prompt(project_id)
        if not history or history[0].get("role") != "system":
            history.insert(0, {"role": "system", "content": system_content})
        else:
            history[0]["content"] = system_content

        history.append({"role": "user", "content": user_text})
        if card_id:
            self.db.add_session_message(card_id, "user", user_text)

        try:
            tools = self._get_tools_definitions(project_id)
            response = self.client.chat.completions.create(
                model=self.model_id,
                messages=history,
                tools=tools,
                tool_choice="auto",
            )

            message = response.choices[0].message
            
            if message.tool_calls:
                history.append(message)
                for tool_call in message.tool_calls:
                    self._notify_tool_status(session_id, tool_call.id, tool_call.function.name, "running")
                    
                    result = await self._execute_tool(
                        tool_call.function.name, 
                        json.loads(tool_call.function.arguments), 
                        project_id
                    )
                    
                    history.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "name": tool_call.function.name,
                        "content": result,
                    })
                    
                    self._notify_tool_status(session_id, tool_call.id, tool_call.function.name, "completed", result)

                second_response = self.client.chat.completions.create(
                    model=self.model_id, messages=history
                )
                final_text = second_response.choices[0].message.content
                history.append({"role": "assistant", "content": final_text})
            else:
                final_text = message.content
                history.append({"role": "assistant", "content": final_text})

            if card_id:
                self.db.add_session_message(card_id, "assistant", final_text or "")

            self.send_response(request_id, result={
                "text": final_text,
                "stopReason": "end_turn"
            })

        except asyncio.CancelledError:
            raise
        except Exception as e:
            self.log(f"AI Completion Error: {str(e)}")
            self.send_response(request_id, error={"code": -32000, "message": str(e)})

    def _notify_tool_status(self, session_id, tool_id, name, status, output=None):
        params = {
            "sessionId": session_id,
            "update": {
                "sessionUpdate": "tool_call", # N1: Unified format
                "tool_call": {
                    "id": tool_id,
                    "name": name,
                    "status": status
                }
            }
        }
        if output:
            params["update"]["tool_call"]["output"] = output[:500]
        self.send_notification("session/update", params)

    async def _execute_tool(self, name: str, args: Dict[str, Any], project_id: Optional[str]) -> str:
        # N3: Scope check early
        if not project_id and name in ["create_card", "move_card", "update_card", "delete_card", "search_cards"]:
            return "Error: No project associated with this session. Please initialize or link a project card first."

        try:
            if "card_id" in args:
                target_card = self.db.get_card(args["card_id"])
                if project_id and target_card and target_card.get("project_id") != project_id:
                    return f"Error: Card {args['card_id']} does not belong to the current project."

            if name == "create_card":
                column_id = self._get_column_id_by_name(args["column_name"], project_id)
                if not column_id: return f"Error: Column '{args['column_name']}' not found"
                card_id = self.db.create_card(column_id, args["title"], args.get("description", ""))
                return f"Card created with ID: {card_id}"
            
            elif name == "move_card":
                target_col_id = self._get_column_id_by_name(args["target_column_name"], project_id)
                if not target_col_id: return f"Error: Column '{args['target_column_name']}' not found"
                self.db.move_card(args["card_id"], target_col_id)
                return f"Card {args['card_id']} moved to '{args['target_column_name']}'"
            
            elif name == "update_card":
                self.db.update_card(args["card_id"], args.get("title"), args.get("description"))
                return f"Card {args['card_id']} updated"
            
            elif name == "delete_card":
                self.db.delete_card(args["card_id"])
                return f"Card {args['card_id']} deleted"
            
            elif name == "search_cards":
                results = self.db.search_cards_fts(args["query"], project_id)
                return json.dumps(results, ensure_ascii=False)
            
            return f"Error: Tool {name} not implemented."
        except Exception as e:
            return f"Error executing tool {name}: {str(e)}"

    def _get_tools_definitions(self, project_id: str = None):
        column_names = ["Todo", "In Progress", "Done"]
        if project_id:
            try:
                cols = self.db.get_columns(project_id)
                if cols: column_names = [c["name"] for c in cols]
            except: pass

        return [
            {
                "type": "function",
                "function": {
                    "name": "create_card",
                    "description": "Create a new kanban card.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "column_name": {"type": "string", "enum": column_names},
                            "title": {"type": "string"},
                            "description": {"type": "string"}
                        },
                        "required": ["column_name", "title"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "move_card",
                    "description": "Move a card to another column.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "card_id": {"type": "string"},
                            "target_column_name": {"type": "string", "enum": column_names}
                        },
                        "required": ["card_id", "target_column_name"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "update_card",
                    "description": "Update card title or description.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "card_id": {"type": "string"},
                            "title": {"type": "string"},
                            "description": {"type": "string"}
                        },
                        "required": ["card_id"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "delete_card",
                    "description": "Delete a card.",
                    "parameters": {
                        "type": "object",
                        "properties": {"card_id": {"type": "string"}},
                        "required": ["card_id"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "search_cards",
                    "description": "Search cards.",
                    "parameters": {
                        "type": "object",
                        "properties": {"query": {"type": "string"}},
                        "required": ["query"]
                    }
                }
            }
        ]

    def _get_system_prompt(self, project_id: str = None):
        status_context = "No active project context."
        if project_id:
            project = self.db.get_project(project_id)
            if project:
                status_context = f"Project: {project['name']}\nWorking Dir: {project.get('workspace_path')}"

        return (
            "You are an expert Kanban Project Manager AI. "
            "You manage tasks using a Kanban board. Use tools to sync your actions with the board. "
            f"Current Context:\n{status_context}"
        )

    def _get_column_id_by_name(self, name: str, project_id: str) -> Optional[str]:
        if not project_id: return None
        cols = self.db.get_columns(project_id)
        for c in cols:
            if c["name"] == name: return c["id"]
        return None

    async def run(self):
        self.log("ACP Server (Brain) started.")
        loop = asyncio.get_running_loop()
        while self.running:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line: break
            try:
                request = json.loads(line)
                await self.handle_request(request)
            except Exception as e:
                self.log(f"RPC Process Error: {e}")

if __name__ == "__main__":
    server = ACPServer()
    asyncio.run(server.run())
