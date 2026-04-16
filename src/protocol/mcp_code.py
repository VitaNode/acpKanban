import sys
import json
import asyncio
from typing import Dict, Any, List, Optional
from src.persistence.database import KanbanDB
from src.persistence.embedding import embedding_service

class MCPCodeServer:
    """A lightweight MCP server for codebase indexing and retrieval."""
    def __init__(self):
        self.db = KanbanDB()

    def list_tools(self) -> List[Dict[str, Any]]:
        return [
            {
                "name": "get_project_outline",
                "description": "Returns a structural outline of the codebase (classes and functions) by file.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "project_id": {"type": "string", "description": "The current project ID."},
                        "file_filter": {"type": "string", "description": "Optional glob-style filter for files."}
                    },
                    "required": ["project_id"]
                }
            },
            {
                "name": "get_symbol_code",
                "description": "Retrieves the full source code for a specific class or function.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "project_id": {"type": "string"},
                        "symbol_name": {"type": "string", "description": "Name of the class or function to retrieve."}
                    },
                    "required": ["project_id", "symbol_name"]
                }
            },
            {
                "name": "search_code",
                "description": "Searches for code symbols by natural language intent using semantic or keyword search.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "project_id": {"type": "string"},
                        "query": {"type": "string", "description": "Natural language query, e.g., 'user authentication logic'"}
                    },
                    "required": ["project_id", "query"]
                }
            }
        ]

    async def call_tool(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        project_id = arguments.get("project_id")
        
        if name == "get_project_outline":
            symbols = self.db.code_symbols.get_by_project(project_id)
            # Group by file_path
            outline = {}
            for s in symbols:
                fp = s["file_path"]
                if fp not in outline:
                    outline[fp] = []
                outline[fp].append(f"{s['symbol_type']} {s['symbol_name']} ({s['signature']})")
            
            return {"content": [{"type": "text", "text": json.dumps(outline, indent=2)}]}

        elif name == "get_symbol_code":
            symbol_name = arguments.get("symbol_name")
            symbols = self.db.code_symbols.get_by_project(project_id)
            match = next((s for s in symbols if s["symbol_name"] == symbol_name), None)
            if match:
                return {"content": [{"type": "text", "text": f"--- {match['file_path']} ---\n{match['code_content']}"}]}
            return {"content": [{"type": "text", "text": f"Error: Symbol '{symbol_name}' not found."}], "isError": True}

        elif name == "search_code":
            query = arguments.get("query")
            results = []
            
            # 1. Try semantic search if available
            if embedding_service.is_available():
                # For now, simplistic implementation of semantic search matches Top 5
                symbols = self.db.code_symbols.get_by_project(project_id)
                # In a real scenario, this would use vector distance
                # Here we just use keyword as a placeholder for this step
                pass

            # 2. Keyword fallback (Search in symbol_name and documentation)
            symbols = self.db.code_symbols.get_by_project(project_id)
            matches = [s for s in symbols if query.lower() in s["symbol_name"].lower() or (s["documentation"] and query.lower() in s["documentation"].lower())]
            
            if matches:
                results = [f"{s['file_path']}: {s['symbol_type']} {s['symbol_name']}" for s in matches[:10]]
                return {"content": [{"type": "text", "text": "Matches (Top 10):\n" + "\n".join(results)}]}
            
            return {"content": [{"type": "text", "text": "No symbols found matching the query."}], "isError": False}

        except Exception as e:
            logger.error(f"MCP Tool Execution Error ({name}): {str(e)}", exc_info=True)
            return {"content": [{"type": "text", "text": f"Internal Error: {str(e)}"}], "isError": True}

async def run_mcp():
    server = MCPCodeServer()
    logger.info("MCP Code Server started.")
    while True:
        try:
            line = await asyncio.get_event_loop().run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            
            request = json.loads(line)
            method = request.get("method")
            params = request.get("params", {})
            req_id = request.get("id")

            if method == "initialize":
                response = {"id": req_id, "result": {"protocolVersion": "2024-11-05", "capabilities": {}}}
            elif method == "list_tools":
                response = {"id": req_id, "result": {"tools": server.list_tools()}}
            elif method == "call_tool":
                result = await server.call_tool(params.get("name"), params.get("arguments", {}))
                response = {"id": req_id, "result": result}
            else:
                response = {"id": req_id, "error": {"code": -32601, "message": f"Method {method} not found"}}

            print(json.dumps(response), flush=True)
        except json.JSONDecodeError:
            continue
        except Exception as e:
            logger.error(f"MCP RPC Loop Error: {str(e)}", exc_info=True)
            continue

if __name__ == "__main__":
    asyncio.run(run_mcp())
