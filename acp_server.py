import asyncio
import sys
import json
import uuid
import os
import traceback
from typing import Dict, Any, List, Optional
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

        # Sessions: {session_id: {"card_id": str, "history": list, "cwd": str}}
        self._sessions: Dict[str, Dict[str, Any]] = {}
        self.current_project_id = None
        self.current_workspace_path = None
        self.log(f"ACP Server (Brain) initialized with {self.model_id}")

    def log(self, message):
        print(f"[*] {message}", file=sys.stderr)

    def send_response(self, response_id, result=None, error=None):
        response = {"jsonrpc": "2.0", "id": response_id}
        if error:
            response["error"] = error
        else:
            response["result"] = result
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()

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
                return await self.on_session_prompt(request_id, params)
            elif method == "session/load":
                return self.on_session_load(request_id, params)
            elif method == "session/list":
                return self.on_session_list(request_id)
            elif method == "health":
                return self.send_response(request_id, result={"status": "healthy"})
            elif method == "shutdown":
                self.running = False
                return self.send_response(request_id, result={})
            # Legacy support
            elif method == "chat/message":
                return await self.on_session_prompt(request_id, {
                    "sessionId": params.get("card_id", "default"),
                    "prompt": [{"type": "text", "text": params.get("message", "")}]
                })
            else:
                return self.send_response(
                    request_id, error={"code": -32601, "message": f"Method {method} not found"}
                )
        except Exception as e:
            self.log(f"Error handling {method}: {str(e)}\n{traceback.format_exc()}")
            return self.send_response(request_id, error={"code": -32603, "message": str(e)})

    def on_initialize(self, request_id, params):
        # Official ACP initialize response
        result = {
            "protocolVersion": 1,
            "agentCapabilities": {
                "prompts": {"supported": True},
                "tools": {"list": self._get_tools_definitions()},
                "resources": {"supported": False}
            },
            "agentInfo": {
                "name": "Kanban-Brain",
                "version": "2.0.0"
            }
        }
        self.send_response(request_id, result=result)

    def on_session_new(self, request_id, params):
        session_id = str(uuid.uuid4())
        cwd = params.get("cwd", self.current_workspace_path or os.getcwd())
        
        # Metadata handling (e.g., card_id)
        meta = params.get("_meta", {})
        card_id = None
        session_key = meta.get("sessionKey", "")
        if "kanban:" in session_key:
            card_id = session_key.split("kanban:")[-1]

        self._sessions[session_id] = {
            "card_id": card_id,
            "history": [],
            "cwd": cwd
        }
        
        self.log(f"Created session {session_id} for card {card_id}")
        self.send_response(request_id, result={"sessionId": session_id})

    def on_session_load(self, request_id, params):
        session_id = params.get("sessionId")
        if session_id not in self._sessions:
            # Attempt to restore from DB if card_id is known
            return self.send_response(request_id, error={"code": -32602, "message": "Session not found"})
        
        self.send_response(request_id, result={"sessionId": session_id})

    def on_session_list(self, request_id):
        sessions = [
            {"sessionId": sid, "title": data.get("card_id", "General")}
            for sid, data in self._sessions.items()
        ]
        self.send_response(request_id, result={"sessions": sessions})

    async def on_session_prompt(self, request_id, params):
        session_id = params.get("sessionId")
        prompt_blocks = params.get("prompt", [])
        
        if session_id not in self._sessions:
            # Fallback for card_id as session_id (Legacy/Bridge simplification)
            if session_id and len(session_id) < 50: # Assume it's a card_id
                self._sessions[session_id] = {"card_id": session_id, "history": [], "cwd": os.getcwd()}
            else:
                return self.send_response(request_id, error={"code": -32602, "message": "Invalid sessionId"})

        session = self._sessions[session_id]
        card_id = session["card_id"]
        
        # Combine text from all blocks
        user_text = " ".join([b.get("text", "") for b in prompt_blocks if b.get("type") == "text"])
        
        async with self.lock:
            self.log(f"Session {session_id} (Card {card_id}) Prompt: {user_text[:50]}...")

        # Load project info for card
        project_id = None
        if card_id:
            card = self.db.get_card(card_id)
            if card:
                project_id = card.get("project_id")

        history = session["history"]
        if not history:
            # Injected system context
            system_content = self._get_system_prompt(project_id)
            history.append({"role": "system", "content": system_content})
            
            # If card exists, load some DB history as context (optional, based on Level 3 Focus)
            # history.extend(self._load_session_from_db(card_id))

        history.append({"role": "user", "content": user_text})
        if card_id:
            self._save_message_to_db(card_id, "user", user_text)

        try:
            # Tool-enabled completion
            tools = self._get_tools_definitions(project_id)
            response = self.client.chat.completions.create(
                model=self.model_id,
                messages=history,
                tools=tools,
                tool_choice="auto",
            )

            message = response.choices[0].message
            
            # Handle tool calls
            if message.tool_calls:
                history.append(message)
                for tool_call in message.tool_calls:
                    # Notify UI about tool execution
                    self.send_notification("session/update", {
                        "sessionId": session_id,
                        "update": {
                            "type": "tool_call",
                            "tool_call": {
                                "id": tool_call.id,
                                "name": tool_call.function.name,
                                "status": "running"
                            }
                        }
                    })
                    
                    result = await self._execute_tool(tool_call.function.name, json.loads(tool_call.function.arguments), project_id)
                    
                    history.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "name": tool_call.function.name,
                        "content": result,
                    })
                    
                    # Notify UI about tool result
                    self.send_notification("session/update", {
                        "sessionId": session_id,
                        "update": {
                            "type": "tool_call",
                            "tool_call": {
                                "id": tool_call.id,
                                "name": tool_call.function.name,
                                "status": "completed",
                                "output": result[:200] + "..." if len(result) > 200 else result
                            }
                        }
                    })

                second_response = self.client.chat.completions.create(
                    model=self.model_id, messages=history
                )
                final_text = second_response.choices[0].message.content
                history.append({"role": "assistant", "content": final_text})
            else:
                final_text = message.content
                history.append({"role": "assistant", "content": final_text})

            if card_id:
                self._save_message_to_db(card_id, "assistant", final_text or "")

            # Stream content via notification (optional but recommended)
            self.send_notification("session/update", {
                "sessionId": session_id,
                "update": {
                    "type": "content",
                    "content": {"type": "text", "text": final_text}
                }
            })

            self.send_response(request_id, result={"text": final_text})

        except Exception as e:
            self.log(f"AI Completion Error: {str(e)}")
            self.send_response(request_id, error={"code": -32000, "message": str(e)})

    async def _execute_tool(self, name: str, args: Dict[str, Any], project_id: Optional[str]) -> str:
        """Executes a tool and returns the result as string."""
        self.log(f"Executing tool: {name} with args {args}")
        try:
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
        # Dynamic enum for columns
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

    def _save_message_to_db(self, card_id: str, role: str, content: str):
        try:
            self.db.add_session_message(card_id, role, content)
        except Exception as e:
            self.log(f"DB Save Error: {e}")

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
