import asyncio
import sys
import json
import uuid
import os
import traceback
from openai import OpenAI
from dotenv import load_dotenv
from database import KanbanDB
from embedding import embedding_service

load_dotenv()


class ACPServer:
    def __init__(self):
        self.running = True
        self.db = KanbanDB()
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
        self.history = []
        self.current_project_id = None
        self.log(f"ACP Server (Brain) initialized with {self.model_id}")

    def log(self, message):
        print(f"[*] {message}", file=sys.stderr)

    def health_check(self):
        try:
            self.db.get_projects()
            return {
                "status": "healthy",
                "db": "ok",
                "embedding": embedding_service.is_available(),
            }
        except Exception as e:
            return {"status": "unhealthy", "error": str(e)}

    def send_response(self, response_id, result=None, error=None):
        response = {"jsonrpc": "2.0", "id": response_id}
        if error:
            response["error"] = error
        else:
            response["result"] = result
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()

    async def handle_request(self, request):
        method = request.get("method")
        params = request.get("params", {})
        request_id = request.get("id")

        if method == "initialize":
            return self.on_initialize(request_id, params)
        elif method == "chat/message":
            return await self.on_chat_message(request_id, params)
        elif method == "health":
            return self.send_response(request_id, result=self.health_check())
        elif method == "set_project":
            project_id = params.get("project_id")
            if project_id:
                self.current_project_id = project_id
            return self.send_response(request_id, result={"project_id": project_id})
        elif method == "shutdown":
            self.running = False
            return self.send_response(request_id, result={})
        else:
            return self.send_response(
                request_id, error={"code": -32601, "message": "Method not found"}
            )

    def on_initialize(self, request_id, params):
        project_id = params.get("project_id")
        if project_id:
            self.current_project_id = project_id

        capabilities = {
            "capabilities": {
                "chat": {"supported": True},
                "tools": {"list": self._get_tools(self.current_project_id)},
            },
            "serverInfo": {"name": "Kanban-Brain", "version": "2.0.0"},
        }
        self.send_response(request_id, result=capabilities)

    def _get_tools(self, project_id: str = None):
        columns = []
        if project_id:
            try:
                columns = self.db.get_columns(project_id)
            except Exception:
                pass

        column_names = (
            [c["name"] for c in columns] if columns else ["Todo", "In Progress", "Done"]
        )

        return [
            {
                "name": "create_card",
                "description": "Create a new kanban card in a specified column.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "column_name": {"type": "string", "enum": column_names},
                        "title": {"type": "string"},
                        "description": {"type": "string"},
                    },
                    "required": ["column_name", "title"],
                },
            },
            {
                "name": "move_card",
                "description": "Move a kanban card to another column.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "card_id": {"type": "string"},
                        "target_column_name": {"type": "string", "enum": column_names},
                    },
                    "required": ["card_id", "target_column_name"],
                },
            },
            {
                "name": "update_card",
                "description": "Update an existing kanban card's title or description.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "card_id": {"type": "string"},
                        "title": {"type": "string"},
                        "description": {"type": "string"},
                    },
                    "required": ["card_id"],
                },
            },
            {
                "name": "delete_card",
                "description": "Delete a kanban card.",
                "parameters": {
                    "type": "object",
                    "properties": {"card_id": {"type": "string"}},
                    "required": ["card_id"],
                },
            },
            {
                "name": "search_cards",
                "description": "Search kanban cards by keyword (FTS) or semantic similarity.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "mode": {"type": "string", "enum": ["fts", "semantic"]},
                    },
                    "required": ["query"],
                },
            },
            {
                "name": "get_column_cards",
                "description": "Get all cards in a specific column.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "column_name": {"type": "string", "enum": column_names}
                    },
                    "required": ["column_name"],
                },
            },
        ]

    def _get_system_prompt(self, project_id: str = None):
        if project_id is None:
            projects = self.db.get_projects()
            if projects:
                project_id = projects[0]["id"]

        if project_id:
            columns = self.db.get_columns(project_id)
            project = self.db.get_project(project_id)
            kanban_status = []
            for col in columns:
                cards = self.db.get_cards_by_column(col["id"])
                kanban_status.append(
                    {
                        "column": col["name"],
                        "cards": [{"id": c["id"], "title": c["title"]} for c in cards],
                    }
                )
            status_context = f"Project: {project['name']}\nKanban: {json.dumps(kanban_status, ensure_ascii=False)}"
        else:
            status_context = "No project exists. Ask user to create a project first."

        return (
            "You are an expert Kanban Project Manager. You help users manage long-term app development tasks. "
            "You MUST use tools to create or update cards when the user asks. "
            f"{status_context}\n"
            "When a task's requirement changes or you hit a technical blocker, mention it clearly in your response."
        )

    def _get_column_id_by_name(self, column_name: str) -> str:
        if not self.current_project_id:
            return None
        columns = self.db.get_columns(self.current_project_id)
        for col in columns:
            if col["name"] == column_name:
                return col["id"]
        return None

    async def on_chat_message(self, request_id, params):
        async with self.lock:
            user_text = params.get("message", "")
            self.log(f"Processing chat: {user_text}")

        system_content = self._get_system_prompt(self.current_project_id)
        if not self.history or self.history[0]["role"] != "system":
            self.history.insert(0, {"role": "system", "content": system_content})
        else:
            self.history[0]["content"] = system_content

        MAX_HISTORY = 20
        if len(self.history) > MAX_HISTORY:
            self.history = [self.history[0]] + self.history[-(MAX_HISTORY - 1) :]

        self.history.append({"role": "user", "content": user_text})

        tools = self._get_tools(self.current_project_id)

        try:
            response = self.client.chat.completions.create(
                model=self.model_id,
                messages=self.history,
                tools=tools,
                tool_choice="auto",
            )

            message = response.choices[0].message

            # Adapter for XML-style tool calls (e.g. MiniMax/Gemini via specific endpoints)
            if (
                not message.tool_calls
                and message.content
                and "<invoke" in message.content
            ):
                import re

                invoke_pattern = re.compile(
                    r'<invoke name="([^"]+)">\s*(.*?)\s*</invoke>', re.DOTALL
                )
                matches = invoke_pattern.findall(message.content)

                if matches:
                    self.log(f"Detected XML tool calls: {len(matches)}")

                    # Fabricate tool_calls object
                    class ToolCall:
                        def __init__(self, id, name, args):
                            self.id = id
                            self.type = "function"
                            self.function = type(
                                "Function", (), {"name": name, "arguments": args}
                            )()

                    message.tool_calls = []
                    for i, (name, args_str) in enumerate(matches):
                        # MiniMax args might be XML-like or JSON. Try to parse if it looks like JSON,
                        # otherwise wrap parameters.
                        # Simple case: if args is empty string, use {}
                        args = args_str.strip() or "{}"
                        # If args are in <arg> tags, we might need more complex parsing.
                        # Assuming JSON for now based on your log (empty args).

                        message.tool_calls.append(
                            ToolCall(f"call_{uuid.uuid4().hex[:8]}", name, args)
                        )

                    # Clear content so we don't display the raw XML to user
                    message.content = None

            if message.tool_calls:
                self.history.append(message)
                for tool_call in message.tool_calls:
                    function_name = tool_call.function.name
                    arguments = json.loads(tool_call.function.arguments)
                    self.log(f"Executing tool: {function_name}")

                    try:
                        if function_name == "create_card":
                            column_id = self._get_column_id_by_name(
                                arguments["column_name"]
                            )
                            if not column_id:
                                result = (
                                    f"Column '{arguments['column_name']}' not found"
                                )
                            else:
                                card_id = self.db.create_card(
                                    column_id,
                                    arguments["title"],
                                    arguments.get("description", ""),
                                )
                                result = f"Card created with ID: {card_id}"
                                if embedding_service.is_available():
                                    emb = embedding_service.compute_card_embedding(
                                        arguments["title"],
                                        arguments.get("description", ""),
                                    )
                                    if emb:
                                        self.db.upsert_card_embedding(card_id, emb)

                        elif function_name == "move_card":
                            target_column_id = self._get_column_id_by_name(
                                arguments["target_column_name"]
                            )
                            if not target_column_id:
                                result = f"Column '{arguments['target_column_name']}' not found"
                            else:
                                self.db.move_card(
                                    arguments["card_id"], target_column_id
                                )
                                result = f"Card {arguments['card_id']} moved to '{arguments['target_column_name']}'"

                        elif function_name == "update_card":
                            self.db.update_card(
                                arguments["card_id"],
                                arguments.get("title"),
                                arguments.get("description"),
                            )
                            result = f"Card {arguments['card_id']} updated"

                        elif function_name == "delete_card":
                            self.db.delete_card(arguments["card_id"])
                            result = f"Card {arguments['card_id']} deleted"

                        elif function_name == "search_cards":
                            mode = arguments.get("mode", "fts")
                            if mode == "semantic" and embedding_service.is_available():
                                emb = embedding_service.get_embedding(
                                    arguments["query"]
                                )
                                if emb:
                                    results = self.db.search_cards_semantic(
                                        emb, self.current_project_id
                                    )
                                else:
                                    results = []
                            else:
                                results = self.db.search_cards_fts(
                                    arguments["query"], self.current_project_id
                                )
                            result = json.dumps(results, ensure_ascii=False)

                        elif function_name == "get_column_cards":
                            column_id = self._get_column_id_by_name(
                                arguments["column_name"]
                            )
                            if not column_id:
                                result = (
                                    f"Column '{arguments['column_name']}' not found"
                                )
                            else:
                                cards = self.db.get_cards_by_column(column_id)
                                result = json.dumps(cards, ensure_ascii=False)

                        else:
                            result = "Error: Tool not found."
                    except Exception as te:
                        self.log(f"Tool Error: {te}")
                        result = f"Error: {str(te)}"

                    self.history.append(
                        {
                            "role": "tool",
                            "tool_call_id": tool_call.id,
                            "name": function_name,
                            "content": result,
                        }
                    )

                second_response = self.client.chat.completions.create(
                    model=self.model_id, messages=self.history
                )
                final_text = second_response.choices[0].message.content
                self.history.append({"role": "assistant", "content": final_text})
            else:
                final_text = message.content
                self.history.append({"role": "assistant", "content": final_text})

            self.send_response(request_id, result={"message": final_text})

        except Exception as e:
            error_str = str(e)
            self.log(f"Internal error: {error_str}\n{traceback.format_exc()}")
            user_friendly_msg = (
                "Internal AI service error"
                if self.api_key and self.api_key in error_str
                else error_str
            )
            self.send_response(
                request_id,
                error={
                    "code": -32000,
                    "message": "Server error",
                    "data": user_friendly_msg,
                },
            )

    async def run(self):
        self.log("ACP Server (Brain) started.")
        loop = asyncio.get_running_loop()
        try:
            while self.running:
                line = await loop.run_in_executor(None, sys.stdin.readline)
                if not line:
                    break
                try:
                    request = json.loads(line)
                    await self.handle_request(request)
                except Exception as e:
                    self.log(f"JSON-RPC Error: {e}")
                    continue
        except Exception as e:
            self.log(f"Critical Error: {e}")


if __name__ == "__main__":
    import asyncio

    server = ACPServer()
    asyncio.run(server.run())
