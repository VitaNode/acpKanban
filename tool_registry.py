import sys
from pathlib import Path
from typing import List, Dict, Any
from config_manager import config

class ToolRegistry:
    """Registry for managing internal and external MCP tools (P2-3 FIX)."""
    def __init__(self):
        self._mcp_servers: List[Dict[str, Any]] = []
        self._setup_internal_tools()
        self._load_external_mcp()

    def _setup_internal_tools(self):
        """Register the built-in Kanban MCP server."""
        self._mcp_servers.append({
            "name": "kanban-tools",
            "command": [sys.executable, str(Path(__file__).parent / "mcp_kanban.py")]
        })

    def _load_external_mcp(self):
        """Load external MCP servers from the central configuration."""
        external_mcp = config.get("mcp_servers", [])
        if external_mcp:
            self._mcp_servers.extend(external_mcp)

    def get_mcp_servers(self) -> List[Dict[str, Any]]:
        return self._mcp_servers

# Global registry instance
tool_registry = ToolRegistry()
