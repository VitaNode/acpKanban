import sys
import json
import traceback
from typing import Dict, Any
from database import KanbanDB

class KanbanMCPServer:
    def __init__(self):
        self.db = KanbanDB()
        self.project_id = None

    def log(self, message):
        print(f"[*] [MCP-Kanban] {message}", file=sys.stderr)

    def send_response(self, request_id, result=None, error=None):
        response = {"jsonrpc": "2.0", "id": request_id}
        if error:
            response["error"] = error
        else:
            response["result"] = result
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()

    def _get_column_id(self, column_name: str) -> str:
        if not self.project_id:
            projects = self.db.projects.get_all()
            if projects:
                self.project_id = projects[0]['id']
        
        if self.project_id:
            cols = self.db.columns.get_by_project(self.project_id)
            for c in cols:
                if c['name'].lower() == column_name.lower():
                    return c['id']
        return None

    async def handle_request(self, request):
        method = request.get("method")
        params = request.get("params", {})
        request_id = request.get("id")

        try:
            if method == "initialize":
                # Save project context if provided in initialization
                return self.send_response(request_id, result={
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "Kanban-Tools", "version": "1.0.0"}
                })
            
            elif method == "tools/list":
                tools = [
                    {
                        "name": "create_card",
                        "description": "Create a new card in the kanban board.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "title": {"type": "string"},
                                "column_name": {"type": "string", "description": "e.g. Todo, In Progress, Done"},
                                "description": {"type": "string"}
                            },
                            "required": ["title", "column_name"]
                        }
                    },
                    {
                        "name": "move_card",
                        "description": "Move a card to a different column.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "card_id": {"type": "string"},
                                "target_column_name": {"type": "string"}
                            },
                            "required": ["card_id", "target_column_name"]
                        }
                    }
                ]
                return self.send_response(request_id, result={"tools": tools})

            elif method == "tools/call":
                name = params.get("name")
                args = params.get("arguments", {})
                
                if name == "create_card":
                    col_id = self._get_column_id(args['column_name'])
                    if not col_id:
                        return self.send_response(request_id, result={"content": [{"type": "text", "text": f"Error: Column {args['column_name']} not found"}], "isError": True})
                    
                    card_id = self.db.cards.create(col_id, args['title'], args.get('description', ''))
                    return self.send_response(request_id, result={"content": [{"type": "text", "text": f"Card created with ID: {card_id}"}]})

                elif name == "move_card":
                    target_col_id = self._get_column_id(args['target_column_name'])
                    if not target_col_id:
                        return self.send_response(request_id, result={"content": [{"type": "text", "text": f"Error: Column {args['target_column_name']} not found"}], "isError": True})
                    
                    # Note: Need move_card implemented in CardRepository or KanbanDB
                    # For now using a direct execute if repo doesn't have it
                    with self.db.get_connection() as conn:
                        conn.execute("UPDATE cards SET column_id = ? WHERE id = ?", (target_col_id, args['card_id']))
                    
                    return self.send_response(request_id, result={"content": [{"type": "text", "text": f"Card {args['card_id']} moved to {args['target_column_name']}"}]})

                else:
                    return self.send_response(request_id, error={"code": -32601, "message": f"Tool {name} not found"})

            elif method == "notifications/initialized":
                return # No response needed

            else:
                return self.send_response(request_id, error={"code": -32601, "message": "Method not found"})

        except Exception as e:
            self.log(f"Error: {e}\n{traceback.format_exc()}")
            return self.send_response(request_id, error={"code": -32000, "message": str(e)})

    async def run(self):
        import asyncio
        loop = asyncio.get_event_loop()
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            try:
                data = json.loads(line)
                await self.handle_request(data)
            except Exception as e:
                self.log(f"JSON Error: {e}")

if __name__ == "__main__":
    import asyncio
    server = KanbanMCPServer()
    asyncio.run(server.run())
