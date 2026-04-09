"""
MyBot - AI Agent Kanban Bridge

分层架构:
  - transport:    WebSocket, E2EE, mDNS, Relay
  - orchestration: Dispatcher, CommandRegistry, TaskRegistry
  - logic:        SessionEngine, ContextBuilder, MCP Tools
  - protocol:     ACP Adapter, ACP Client, AG-UI Mapper
  - persistence:  Database, Repositories, Embeddings
  - config:       Configuration Manager
"""

__version__ = "0.2.0"
