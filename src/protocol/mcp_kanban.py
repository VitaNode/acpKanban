import sys
import json
import asyncio
import uuid
from typing import Dict, Any, List, Optional
from src.persistence.database import KanbanDB
from src.logger import setup_logger

logger = setup_logger("MCPKanbanServer")

class MCPKanbanServer:
    """Internal MCP server for Kanban board operations."""
    def __init__(self):
        self.db = KanbanDB()

    def list_tools(self) -> List[Dict[str, Any]]:
        return [
            {
                "name": "kanban_create_card",
                "description": "Creates a new card in a specified column.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "column_id": {"type": "string", "description": "The target column ID."},
                        "title": {"type": "string", "description": "The title of the card."},
                        "description": {"type": "string", "description": "Optional description for the card."},
                        "acp_provider_id": {"type": "string", "description": "Optional provider for the card."}
                    },
                    "required": ["column_id", "title"]
                }
            },
            {
                "name": "kanban_move_card",
                "description": "Moves a card to a different column and/or position.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "card_id": {"type": "string", "description": "The card ID to move."},
                        "target_column_id": {"type": "string", "description": "The destination column ID."},
                        "position": {"type": "integer", "description": "Target position index (optional)."}
                    },
                    "required": ["card_id", "target_column_id"]
                }
            },
            {
                "name": "kanban_update_card",
                "description": "Updates a card's details.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "card_id": {"type": "string", "description": "The card ID to update."},
                        "title": {"type": "string", "description": "New title."},
                        "description": {"type": "string", "description": "New description."}
                    },
                    "required": ["card_id"]
                }
            },
            {
                "name": "kanban_get_board",
                "description": "Retrieves the full board state (columns and cards) for a project.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "project_id": {"type": "string", "description": "The project ID."}
                    },
                    "required": ["project_id"]
                }
            }
        ]

    async def call_tool(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        try:
            if name == "kanban_create_card":
                col_id = arguments.get("column_id")
                title = arguments.get("title")
                desc = arguments.get("description", "")
                provider = arguments.get("acp_provider_id")
                
                card_id = self.db.cards.create(col_id, title, description=desc, acp_provider_id=provider)
                if card_id:
                    return {"content": [{"type": "text", "text": f"Successfully created card '{title}' (ID: {card_id}) in column {col_id}"}]}
                return {"content": [{"type": "text", "text": "Failed to create card."}], "isError": True}

            elif name == "kanban_move_card":
                card_id = arguments.get("card_id")
                col_id = arguments.get("target_column_id")
                pos = arguments.get("position", 0)
                
                success = self.db.cards.move(card_id, col_id, pos)
                if success:
                    return {"content": [{"type": "text", "text": f"Successfully moved card {card_id} to column {col_id}."}]}
                return {"content": [{"type": "text", "text": f"Failed to move card {card_id}."}], "isError": True}

            elif name == "kanban_update_card":
                card_id = arguments.get("card_id")
                title = arguments.get("title")
                desc = arguments.get("description")
                
                success = self.db.cards.update(card_id, title=title, description=desc)
                if success:
                    return {"content": [{"type": "text", "text": f"Successfully updated card {card_id}."}]}
                return {"content": [{"type": "text", "text": f"Failed to update card {card_id}."}], "isError": True}

            elif name == "kanban_get_board":
                proj_id = arguments.get("project_id")
                columns = self.db.columns.get_by_project(proj_id)
                board_state = []
                for col in columns:
                    cards = self.db.cards.get_by_column(col["id"])
                    board_state.append({
                        "id": col["id"],
                        "name": col["name"],
                        "cards": [{"id": c["id"], "title": c["title"], "status": c["status"]} for c in cards]
                    })
                return {"content": [{"type": "text", "text": json.dumps(board_state, indent=2)}]}

            return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True}

        except Exception as e:
            logger.error(f"Kanban MCP Tool Execution Error ({name}): {str(e)}")
            return {"content": [{"type": "text", "text": f"Internal Error: {str(e)}"}], "isError": True}

async def run_mcp():
    server = MCPKanbanServer()
    while True:
        try:
            line = await asyncio.get_event_loop().run_in_executor(None, sys.stdin.readline)
            if not line: break
            
            request = json.loads(line)
            method = request.get("method")
            params = request.get("params", {})
            req_id = request.get("id")

            if method == "initialize":
                response = {"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": "2024-11-05", "capabilities": {}}}
            elif method == "list_tools":
                response = {"jsonrpc": "2.0", "id": req_id, "result": {"tools": server.list_tools()}}
            elif method == "call_tool":
                result = await server.call_tool(params.get("name"), params.get("arguments", {}))
                response = {"jsonrpc": "2.0", "id": req_id, "result": result}
            else:
                response = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"Method {method} not found"}}

            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
        except EOFError: break
        except Exception as e:
            logger.error(f"Kanban MCP RPC Loop Error: {str(e)}")

if __name__ == "__main__":
    asyncio.run(run_mcp())
