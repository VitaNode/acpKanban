import sys
import copy
from pathlib import Path
from typing import List, Dict, Any
from src.config.manager import config

class ToolRegistry:
    """Registry for managing internal and external MCP tools."""
    def __init__(self):
        self._mcp_servers: List[Dict[str, Any]] = []
        self._setup_internal_tools()
        self._load_external_mcp()

    def _setup_internal_tools(self):
        """Register the built-in Kanban MCP server."""
        # Fix: ACP/MCP expects 'command' as string, 'args' as list.
        # Adding 'env' as an empty list based on the error log 'expected array'.
        self._mcp_servers.append({
            "name": "kanban-tools",
            "command": sys.executable,
            "args": [str(Path(__file__).parent / "mcp_kanban.py")],
            "env": [] # Based on error log: 'expected array'
        })

    def _load_external_mcp(self):
        """Load external MCP servers from the central configuration."""
        raw_servers = config.get("mcp_servers", [])
        
        # If mcp_servers is a dict (standard MCP config format), convert to list
        if isinstance(raw_servers, dict):
            for name, cfg in raw_servers.items():
                server = copy.deepcopy(cfg)
                server["name"] = name
                self._normalize_server(server)
                self._mcp_servers.append(server)
        elif isinstance(raw_servers, list):
            for cfg in raw_servers:
                server = copy.deepcopy(cfg)
                self._normalize_server(server)
                self._mcp_servers.append(server)

    def _normalize_server(self, server: Dict[str, Any]):
        """Ensure the server config matches the strict expectations of ACP CLI."""
        # 1. Handle command as list
        if isinstance(server.get("command"), list) and len(server["command"]) > 0:
            cmd_list = server["command"]
            server["command"] = cmd_list[0]
            server["args"] = cmd_list[1:] + server.get("args", [])
        
        # 2. Ensure args is a list
        if "args" not in server or server["args"] is None:
            server["args"] = []
            
        # 3. Ensure env is a list (based on log: 'expected array, received undefined')
        if "env" not in server or not isinstance(server["env"], list):
            server["env"] = []

    def get_mcp_servers(self) -> List[Dict[str, Any]]:
        return self._mcp_servers

# Global registry instance
tool_registry = ToolRegistry()
