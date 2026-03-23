"""
ACP Protocol Adapter

Converts custom protocol (chat/message) to standard ACP protocol (session/prompt).

This allows Flutter App to use the same protocol for both:
- Path 2: Mobile → Relay → acp_bridge_relay → gemini --acp
- Path 3: Mobile → acp_server.py → LLM API

Usage:
    adapter = ACPProtocolAdapter(acp_client)
    result = await adapter.handle_request("chat/message", {"message": "Hello"})
"""

import json
import uuid
from pathlib import Path
from typing import Optional, Dict, Any


class ACPProtocolAdapter:
    """
    Protocol adapter that converts custom chat/message format to standard ACP session/prompt.
    
    This enables Flutter App to work with both Path 2 (gemini --acp) and Path 3 (acp_server.py)
    without any code changes on the Flutter side.
    """
    
    def __init__(self, acp_client, workspace_cwd: Optional[str] = None):
        """
        Initialize the adapter.
        
        Args:
            acp_client: ACPClient instance for communicating with gemini --acp
            workspace_cwd: Working directory for the ACP session (optional)
        """
        self.acp = acp_client
        self._workspace_cwd = workspace_cwd or str(Path.home())
        self._session_id: Optional[str] = None
    
    async def initialize(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle initialize request - adds protocolVersion for gemini --acp compatibility.
        
        Args:
            params: Initialize parameters from Flutter App
            
        Returns:
            Initialize response from gemini --acp
        """
        # Update workspace if provided
        if 'cwd' in params:
            self._workspace_cwd = params['cwd']
        
        # Add protocolVersion for standard ACP compliance
        acp_params = {
            "protocolVersion": 1,
            "clientInfo": params.get("clientInfo", {"name": "Unknown", "version": "1.0.0"})
        }
        
        response = await self.acp.request("initialize", acp_params)
        return response.get("result", {})
    
    async def chat_message(self, message: str) -> Dict[str, Any]:
        """
        Convert chat/message to session/prompt and forward to gemini --acp.
        
        Input format (from Flutter):
            {"message": "新建卡片"}
        
        Output format (to gemini --acp):
            {
                "sessionId": "xxx",
                "prompt": [{"role": "user", "content": "新建卡片"}]
            }
        
        Args:
            message: User's message text
            
        Returns:
            Response from gemini --acp with 'message' key
        """
        # Ensure session exists
        if not self._session_id:
            await self._create_session()
        
        # Send standard ACP request
        response = await self.acp.request("session/prompt", {
            "sessionId": self._session_id,
            "prompt": [
                {"role": "user", "content": message}
            ]
        })
        
        # Handle errors
        if "error" in response:
            return {"error": response["error"]}
        
        # Extract result
        result = response.get("result", {})
        
        # Handle different response formats
        if isinstance(result, dict):
            # Gemini --acp returns {text: "..."}
            return {"message": result.get("text", str(result))}
        else:
            return {"message": str(result)}
    
    async def health(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Forward health check to gemini --acp.
        
        Args:
            params: Health check parameters (usually empty)
            
        Returns:
            Health status from gemini --acp
        """
        response = await self.acp.request("health", params)
        return response.get("result", {"status": "healthy"})
    
    async def _create_session(self) -> str:
        """
        Create a new ACP session with gemini --acp.
        
        Returns:
            Session ID string
        """
        response = await self.acp.request("session/new", {
            "cwd": self._workspace_cwd,
            "mcpServers": []
        })
        
        if "error" in response:
            raise Exception(f"Session creation failed: {response['error']}")
        
        self._session_id = response.get("result", {}).get("sessionId")
        return self._session_id
    
    async def handle_request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Unified entry point - routes requests to appropriate handler.
        
        Args:
            method: RPC method name (e.g., "chat/message", "initialize")
            params: Method parameters
            
        Returns:
            Response from the appropriate handler
        """
        if method == "initialize":
            return await self.initialize(params)
        elif method == "chat/message":
            return await self.chat_message(params.get("message", ""))
        elif method == "health":
            return await self.health(params)
        else:
            # Unknown method - forward directly to ACP (for future extensibility)
            response = await self.acp.request(method, params)
            return response.get("result", {})
    
    def get_session_id(self) -> Optional[str]:
        """Get current session ID (for debugging)."""
        return self._session_id
    
    def reset_session(self):
        """Reset session ID to force creation of new session."""
        self._session_id = None
