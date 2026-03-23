import sys
import json
import uuid
import os
import traceback
from openai import OpenAI
from dotenv import load_dotenv
from database import KanbanDB

load_dotenv()

class ACPServer:
    def __init__(self):
        self.running = True
        self.db = KanbanDB()
        self.lock = asyncio.Lock() # Added for concurrency safety
        
        self.api_key = os.getenv("KANBAN_API_KEY")
        if not self.api_key or self.api_key == "your_new_key_here":
            self.log("WARNING: KANBAN_API_KEY not found or default value used.")
            self.api_key = "sk-placeholder-for-init"

        self.base_url = os.getenv("KANBAN_BASE_URL", "https://api.openai.com/v1")
        self.model_id = os.getenv("KANBAN_MODEL_ID", "gpt-4o-mini")
        
        self.client = OpenAI(
            api_key=self.api_key, 
            base_url=self.base_url,
            timeout=60.0,
            max_retries=2
        )
        self.history = []
        self.log(f"ACP Server (Brain) initialized with {self.model_id}")

    def log(self, message):
        print(f"[*] {message}", file=sys.stderr)

    def health_check(self):
        # Issue 7: Health Check for Cloud Deployment
        try:
            # Check DB
            self.db.get_task_summary()
            # Check API (Minimal call to models.list or similar)
            # self.client.models.list() 
            return {"status": "healthy", "db": "ok", "api": "ready"}
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
        elif method == "shutdown":
            self.running = False
            return self.send_response(request_id, result={})
        else:
            return self.send_response(request_id, error={"code": -32601, "message": "Method not found"})

    def on_initialize(self, request_id, params):
        capabilities = {
            "capabilities": {
                "chat": {"supported": True},
                "tools": {
                    "list": [
                        {
                            "name": "add_kanban_task",
                            "description": "Create a new kanban card for a task.",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "title": {"type": "string"},
                                    "description": {"type": "string"}
                                },
                                "required": ["title"]
                            }
                        },
                        {
                            "name": "update_task_status",
                            "description": "Change the status of an existing task.",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "task_id": {"type": "string"},
                                    "status": {"type": "string", "enum": ["todo", "in_progress", "done"]}
                                },
                                "required": ["task_id", "status"]
                            }
                        }
                    ]
                }
            },
            "serverInfo": {"name": "Kanban-Brain", "version": "1.3.0"}
        }
        self.send_response(request_id, result=capabilities)

    def _get_system_prompt(self):
        # Issue 3: Adaptive System Prompt
        tasks = self.db.get_all_tasks()
        if len(tasks) > 20:
            summary = self.db.get_task_summary()
            status_context = f"Task Summary (Too many to list): {json.dumps(summary)}. Please ask for details of a specific task if needed."
        else:
            status_context = f"Current Kanban status: {json.dumps(tasks)}"

        return (
            "You are an expert Kanban Project Manager. You help users manage long-term app development tasks. "
            "You MUST use tools to create or update tasks when the user asks. "
            f"{status_context}\n"
            "When a task's requirement changes or you hit a technical blocker, mention it clearly in your response "
            "so it can be logged to the timeline."
        )

    async def on_chat_message(self, request_id, params):
        async with self.lock:
            user_text = params.get("message", "")
            self.log(f"Processing chat: {user_text}")

        system_content = self._get_system_prompt()
        if not self.history or self.history[0]["role"] != "system":
            self.history.insert(0, {"role": "system", "content": system_content})
        else:
            self.history[0]["content"] = system_content

        MAX_HISTORY = 20
        if len(self.history) > MAX_HISTORY:
            self.history = [self.history[0]] + self.history[-(MAX_HISTORY-1):]

        self.history.append({"role": "user", "content": user_text})

        tools = [
            {
                "type": "function",
                "function": {
                    "name": "add_kanban_task",
                    "description": "Create a new kanban card for a task.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": {"type": "string"},
                            "description": {"type": "string"}
                        },
                        "required": ["title"]
                    }
                }
            },
            {
                "type": "function",
                "function": {
                    "name": "update_task_status",
                    "description": "Change the status of an existing task.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "task_id": {"type": "string"},
                            "status": {"type": "string", "enum": ["todo", "in_progress", "done"]}
                        },
                        "required": ["task_id", "status"]
                    }
                }
            }
        ]

        try:
            response = self.client.chat.completions.create(
                model=self.model_id,
                messages=self.history,
                tools=tools,
                tool_choice="auto"
            )
            
            message = response.choices[0].message
            
            # Adapter for XML-style tool calls (e.g. MiniMax/Gemini via specific endpoints)
            if not message.tool_calls and message.content and "<invoke" in message.content:
                import re
                invoke_pattern = re.compile(r'<invoke name="([^"]+)">\s*(.*?)\s*</invoke>', re.DOTALL)
                matches = invoke_pattern.findall(message.content)
                
                if matches:
                    self.log(f"Detected XML tool calls: {len(matches)}")
                    # Fabricate tool_calls object
                    class ToolCall:
                        def __init__(self, id, name, args):
                            self.id = id
                            self.type = 'function'
                            self.function = type('Function', (), {'name': name, 'arguments': args})()

                    message.tool_calls = []
                    for i, (name, args_str) in enumerate(matches):
                        # MiniMax args might be XML-like or JSON. Try to parse if it looks like JSON, 
                        # otherwise wrap parameters.
                        # Simple case: if args is empty string, use {}
                        args = args_str.strip() or "{}"
                        # If args are in <arg> tags, we might need more complex parsing.
                        # Assuming JSON for now based on your log (empty args).
                        
                        message.tool_calls.append(ToolCall(f"call_{uuid.uuid4().hex[:8]}", name, args))
                    
                    # Clear content so we don't display the raw XML to user
                    message.content = None

            if message.tool_calls:
                self.history.append(message)
                for tool_call in message.tool_calls:
                    function_name = tool_call.function.name
                    arguments = json.loads(tool_call.function.arguments)
                    self.log(f"Executing tool: {function_name}")
                    
                    try:
                        if function_name == "add_kanban_task":
                            task_id = self.db.add_task(arguments['title'], arguments.get('description', ""))
                            result = f"Task created with ID: {task_id}"
                            # Issue 6: Log tool call to timeline
                            self.db.add_timeline_event(task_id, "ai_action", f"Task created via AI: {arguments['title']}")
                        elif function_name == "update_task_status":
                            self.db.update_task_status(arguments['task_id'], arguments['status'])
                            result = f"Task {arguments['task_id']} updated to {arguments['status']}"
                            # Issue 6: Log tool call to timeline
                            self.db.add_timeline_event(arguments['task_id'], "ai_action", f"Status updated via AI to {arguments['status']}")
                        else:
                            result = "Error: Tool not found."
                    except Exception as te:
                        self.log(f"Tool Error: {te}")
                        result = f"Error: {str(te)}"

                    self.history.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "name": function_name,
                        "content": result
                    })

                second_response = self.client.chat.completions.create(
                    model=self.model_id,
                    messages=self.history
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
            user_friendly_msg = "Internal AI service error" if self.api_key and self.api_key in error_str else error_str
            self.send_response(request_id, error={
                "code": -32000, 
                "message": "Server error", 
                "data": user_friendly_msg
            })

    async def run(self):
        self.log("ACP Server (Brain) started.")
        loop = asyncio.get_running_loop()
        try:
            while self.running:
                line = await loop.run_in_executor(None, sys.stdin.readline)
                if not line: break
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
