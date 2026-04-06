import sys
from pathlib import Path
from typing import List, Dict, Any
from config_manager import config

class ToolRegistry:
    """Registry for managing internal and external MCP tools."""
    def __init__(self):
        self._mcp_servers: List[Dict[str, Any]] = []
        self._setup_internal_tools()
        self._load_external_mcp()

    def _setup_internal_tools(self):
        """Register the built-in Kanban MCP server."""
        # ACP/MCP expects 'command' as string and 'args' as list
        self._mcp_servers.append({
            "name": "kanban-tools",
            "type": "stdio", # Ensure type is specified
            "command": sys.executable,
            "args": [str(Path(__file__).parent / "mcp_kanban.py")]
        })

    def _load_external_mcp(self):
        """Load external MCP servers from the central configuration."""
        external_mcp = config.get("mcp_servers", [])
        for server in external_mcp:
            # Basic normalization for standard MCP format
            if isinstance(server.get("command"), list) and len(server["command"]) > 0:
                cmd_list = server["command"]
                server["command"] = cmd_list[0]
                server["args"] = cmd_list[1:] + server.get("args", [])
            self._mcp_servers.append(server)

    def get_mcp_servers(self) -> List[Dict[str, Any]]:
        return self._mcp_servers

# Global registry instance
tool_registry = ToolRegistry()
