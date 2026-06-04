# acpKanban

<p align="center">
  <img src="acpKanban.png" width="128" alt="acpKanban Logo">
</p>

<p align="center">
  <strong>English</strong> | <a href="README_cn.md"><strong>中文</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/python-3.10+-blue?logo=python" alt="Python 3.10+">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter" alt="Flutter 3.x">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/status-alpha-yellow" alt="Alpha">
</p>

---

- [Introduction](#-introduction)
- [Core Features](#-core-features)
- [Project Status](#-project-status)
- [Supported ACP Agents](#-supported-acp-agent-client-protocol-agents)
- [System Architecture](#-system-architecture)
- [Quick Start](#-quick-start)
- [Configuration](#-configuration)
- [Development Guide](#-development-guide)
- [FAQ](#-faq)
- [Resources](#-resources)
- [License](#-license)

---

## 📖 Introduction

**acpKanban** is a kanban task management system that integrates ACP Agents directly into your workflow. It is designed for:

- **Consolidating fragmented sessions** — View the progress of all tasks in one interface
- **Using multiple agents** — Different tasks, different agents, different free tiers
- **Trying different vendors** — Compare system prompts + loop + harness from various providers
- **Task orchestration** — Automatically execute tasks when a card is moved to a configured column

## ✨ Core Features

- 🔄 **Real-time bidirectional communication** — Flutter App ⇄ Bridge ⇄ ACP Agent
- 🔐 **End-to-end encryption** — E2EE (X25519 + AES-256-GCM), keeping your data private and secure
- 🌐 **Three-tier connection strategy** — mDNS → Cloud Relay → Cloud SaaS, with intelligent fallback
- 🤖 **Multi-Agent support** — Gemini CLI, Qwen Code, OpenClaw, Cline CLI, 30+ agents
- 📋 **Card-level session isolation** — Each card has its own independent session; cross-card linking supported
- 🔍 **Hybrid search** — SQLite FTS5 + sqlite-vec semantic search
- 🎨 **Visual column management** — Drag-and-drop sorting, custom column names and colors
- ⏱️ **Project Roadmap** — Global timeline view aggregating all card events
- 📄 **AG-UI protocol integration** — Structured message rendering, tool call status capsules, collapsible reasoning display

## 📌 Project Status

| Module | Status | Description |
|--------|--------|-------------|
| Kanban CRUD | ✅ Done | Basic CRUD for cards, columns, and projects |
| Multi-Agent Connection | ✅ Done | Support for 30+ ACP Agent integrations |
| AG-UI Rendering | ✅ Done | Structured messages, tool calls, reasoning display |
| E2EE Encryption | ✅ Done | X25519 + AES-256-GCM |
| Three-tier Connection (mDNS/Relay/Cloud) | ✅ Done | Intelligent fallback strategy |
| Hybrid Search | ✅ Done | FTS5 + semantic search |
| A2A Protocol Integration | 🚧 Planned | Agent registration, discovery, and task orchestration |
| Auto-execute Cards | 🚧 Planned | Trigger agent when card is moved to a specific column |

## 🤖 Supported ACP (Agent Client Protocol) Agents

* [AgentPool](https://phil65.github.io/agentpool/advanced/acp-integration/)
* [Augment Code](https://docs.augmentcode.com/cli/acp)
* [AutoDev](https://github.com/phodal/auto-dev)
* [Blackbox AI](https://docs.blackbox.ai/features/blackbox-cli/introduction)
* [Claude Agent](https://platform.claude.com/docs/en/agent-sdk/overview) (via [Zed's SDK adapter](https://github.com/zed-industries/claude-agent-acp))
* [Cline](https://cline.bot/)
* [Codex CLI](https://developers.openai.com/codex/cli) (via [Zed's adapter](https://github.com/zed-industries/codex-acp))
* [Code Assistant](https://github.com/stippi/code-assistant?tab=readme-ov-file#configuration)
* [crow-cli](https://crow-ai.dev)
* [Cursor](https://cursor.com/docs/cli/acp)
* [Docker's cagent](https://github.com/docker/cagent)
* [fast-agent](https://fast-agent.ai/acp)
* [Factory Droid](https://factory.ai/)
* [fount](https://github.com/steve02081504/fount)
* [Gemini CLI](https://github.com/google-gemini/gemini-cli)
* [GitHub Copilot](https://github.com/features/copilot) ([public preview](https://github.blog/changelog/2026-01-28-acp-support-in-copilot-cli-is-now-in-public-preview/))
* [Goose](https://block.github.io/goose/docs/guides/acp-clients)
* [Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp)
* [Junie by JetBrains](https://junie.jetbrains.com/)
* [Kimi CLI](https://github.com/MoonshotAI/kimi-cli)
* [Kiro CLI](https://kiro.dev/docs/cli/acp/)
* [Minion Code](https://github.com/femto/minion-code)
* [Mistral Vibe](https://github.com/mistralai/mistral-vibe)
* [OpenClaw](https://docs.openclaw.ai/cli/acp)
* [OpenCode](https://github.com/sst/opencode)
* [OpenHands](https://docs.openhands.dev/openhands/usage/run-openhands/acp)
* [Pi](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent) (via [pi-acp adapter](https://github.com/svkozak/pi-acp))
* [Poolside](https://github.com/poolsideai/pool)
* [Qoder CLI](https://docs.qoder.com/cli/acp)
* [Qwen Code](https://github.com/QwenLM/qwen-code)
* [Stakpak](https://github.com/stakpak/agent?tab=readme-ov-file#agent-client-protocol-acp)
* [stdio Bus](https://github.com/stdiobus/stdiobus)
* [VT Code](https://github.com/vinhnx/vtcode/blob/main/README.md#zed-ide-integration-agent-client-protocol)

---

## 🏗️ System Architecture

### End-to-End Data Flow

```
┌───────────────────────────────────────────────────────────────────────┐
│                         Flutter App (iPhone / Mac)                    │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │ Kanban View│  │ Card Detail  │  │ Connections  │  │ Timeline   │  │
│  └────▲───────┘  └──────▲───────┘  └──────▲───────┘  └──────▲─────┘  │
│       │                 │                 │                 │          │
│  ┌────┴─────────────────┴─────────────────┴─────────────────┴────┐   │
│  │                   Smart Connect Manager                        │   │
│  │    mDNS (LAN)        Relay (Cloud)        Cloud (SaaS)         │   │
│  └────────────────────────────▲──────────────────────────────────┘   │
│                               │ E2EE (X25519 + AES-256-GCM)          │
└───────────────────────────────┼──────────────────────────────────────┘
                                │ WebSocket
┌───────────────────────────────┼──────────────────────────────────────┐
│                    Mac Bridge (Python Backend)                       │
│                               │                                      │
│  ┌────────────────────────────┴──────────────────────────────┐      │
│  │                     ACP Bridge                             │      │
│  │  ┌──────────┐  ┌──────────────┐  ┌──────────────┐        │      │
│  │  │ E2EE     │  │ Session Mgmt │  │ Access Ctrl  │        │      │
│  │  └──────────┘  └──────────────┘  └──────────────┘        │      │
│  └────────────────────────▲─────────────────────────────────┘      │
│                           │                                        │
│  ┌────────────────────────┴──────────────────────────────────┐     │
│  │                  AG-UI Mapper                              │    │
│  │    ACP Events  ←→  AG-UI Structured Messages              │    │
│  │                  (Thinking/Tools/Text)                     │    │
│  └────────────────────────▲──────────────────────────────────┘     │
│                           │                                        │
│  ┌────────────────────────┴──────────────────────────────────┐     │
│  │                    REST API (FastAPI)                     │     │
│  │  /api/projects  /api/cards  /api/columns  /api/sessions   │     │
│  └────────────────────────▲──────────────────────────────────┘     │
│                           │                                        │
│  ┌────────────────────────┴──────────────────────────────────┐     │
│  │               Hybrid Database (SQLite)                    │     │
│  │  FTS5 Full-Text  │  sqlite-vec Semantic  │  WAL Mode      │     │
│  └──────────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
            ┌───────▼───────┐       ┌───────▼───────┐
            │  ACP Agent    │       │  MCP Server   │
            │ (Gemini/Qwen) │       │ (tree-sitter) │
            └───────────────┘       └───────────────┘
```

### Data Layer Design

| Layer | Content | Update Frequency |
|-------|---------|------------------|
| **Level 1: Global** | Project summary, agent.md, all card summaries | Loaded on card creation |
| **Level 2: Related** | Summaries of linked cards | Dynamic query |
| **Level 3: Focus** | Full conversation and execution history of the current card | Real-time |

### Port Reference

| Service | Default Port | Description |
|---------|-------------|-------------|
| FastAPI (API) | `8000` | REST API + auto docs `/docs` |
| Bridge WebSocket | `8001` | Flutter App connection port |
| mDNS | `5353` (UDP) | LAN service discovery |
| Relay | `8766` | Cloud relay service |

### Directory Structure

```
acpkanban/
├── api/                    # FastAPI endpoints
│   ├── main.py             # API entry point
│   ├── cards.py            # Card CRUD
│   ├── columns.py          # Column management
│   ├── projects.py         # Project management
│   ├── sessions.py         # Session management
│   ├── providers.py        # ACP Provider
│   └── ...
├── src/
│   ├── logic/              # Workflow/session logic
│   │   ├── context.py      # Context building
│   │   └── tools/          # Built-in tools
│   ├── persistence/        # SQLite + indexing + embeddings
│   │   ├── database.py     # Database core
│   │   ├── embedding.py    # Vector embeddings
│   │   └── indexer.py      # Incremental indexing
│   ├── protocol/           # ACP / AG-UI protocols
│   │   ├── adapter.py      # ACP protocol adapter
│   │   ├── ag_ui_mapper.py # ACP → AG-UI mapping
│   │   ├── mcp_code.py     # Code tools (MCP)
│   │   ├── mcp_kanban.py   # Kanban tools (MCP)
│   │   └── drivers/        # ACP drivers
│   ├── transport/          # Network transport
│   │   ├── bridge.py       # ACP Bridge core
│   │   ├── bridge_ws.py    # WebSocket transport
│   │   ├── e2ee.py         # End-to-end encryption
│   │   ├── mdns.py         # mDNS service discovery
│   │   └── relay_server.py # Relay server
│   ├── config/             # Configuration management
│   └── utils/              # Utility functions
├── flutter_prototype/      # Flutter frontend
│   ├── lib/
│   │   ├── main.dart       # App entry point
│   │   ├── screens/        # Pages (Kanban/Card Detail/Connections)
│   │   ├── widgets/        # Widgets
│   │   ├── services/       # Service layer
│   │   ├── models/         # Data models
│   │   ├── theme/          # Theme
│   │   └── utils/          # Utilities
│   └── test/               # Flutter tests
├── scripts/
│   ├── setup.sh            # One-click setup script
│   ├── install_relay.sh    # Remote Relay installation
│   └── relay/              # Relay deployment files
├── tests/                  # Python tests
├── start.sh                # (Generated) All-in-one launcher
├── start_api.sh            # (Generated) API-only launcher
├── start_dev.sh            # (Generated) Dev mode launcher
├── run_all.py              # One-click start (API + Bridge + Relay)
├── run_bridge.py           # Bridge standalone start
├── acp_server.py           # Standalone ACP Server
├── install.sh              # Remote one-click installer
└── config.json             # Runtime configuration
```

---

## 🚀 Quick Start

### Prerequisites

- Python 3.10+
- Flutter SDK 3.x
- SQLite (with FTS5 and WAL mode support)
- Node.js (optional, for toolchain)

### Server Installation

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/VitaNode/acpKanban/main/install.sh | bash
```

**Windows:**
```powershell
irm https://raw.githubusercontent.com/VitaNode/acpKanban/main/install.ps1 | iex
```

> The script automates: clone repository → detect system → install dependencies → initialize config → output connection credentials.

### First Connection

1. **Initialize** — Run `bash scripts/setup.sh`. This creates a virtual environment, installs dependencies, generates credentials, and creates startup scripts (`start.sh`, etc.)
2. **Start the backend** — Run `./start.sh` (equivalent to `python run_all.py`), which starts the API, Bridge, and local Relay simultaneously
3. **Open Flutter App** → go to "Connection Settings"
4. **Enter connection info** — LAN IP, port (API `8000` / Bridge `8001`), `USER_ID`, `API_TOKEN`, `RELAY_TOKEN` (all found in `config.json`)
5. **Connected** — The kanban board will appear

> Alternative launchers: `./start_api.sh` (API only) or `./start_dev.sh` (dev mode with hot reload).

---

## 🔧 Configuration

### Credentials

The system uses **manually entered credentials** for authentication. `config.json` is auto-generated on first run:

```json
{
  "system": {
    "api_token": "auto-generated API Token",
    "api_bind_host": "127.0.0.1",
    "bridge_bind_host": "127.0.0.1"
  },
  "relay": {
    "url": "ws://<relay-server>:8766",
    "token": "auto-generated Relay Token",
    "user_id": "auto-generated user ID"
  },
  "providers": {
    "default": "gemini",
    "list": [
      { "id": "gemini", "name": "Gemini CLI", "command": ["gemini", "--acp"] },
      { "id": "qwen",  "name": "Qwen Code",  "command": ["qwen",  "--acp"] }
    ]
  }
}
```

- Credentials are automatically generated on the first run of `setup.sh` or the backend
- Enter these credentials manually in the Flutter App's connection settings
- Modify credentials in `config.json` and restart the service to reset

### providers Configuration

Add agents to `providers.list` in `config.json`:
- `id` — Unique identifier
- `name` — Display name
- `command` — Launch command (as an array)
- `icon` — Material Icons name
- `remote: true` — Connect via SSH for remote agents

---

## 🧑‍💻 Development Guide

### Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Start dev mode (with hot reload)
./start_dev.sh
# or
uvicorn api.main:app --host 127.0.0.1 --port 8000 --reload
```

### Running Tests

```bash
pytest tests/                    # Python tests
cd flutter_prototype && flutter test  # Flutter tests
```

### Code Style

- Python: 4-space indentation, `snake_case` naming
- Dart/Flutter: Follow `flutter_lints`, `lowerCamelCase` for members, `PascalCase` for widgets

---

## ❓ FAQ

**Q: Can't connect to the backend?**
A: Check that your Mac firewall allows ports `8000` (API) and `8001` (Bridge). When connecting over LAN, use the Mac's actual IP address, not `127.0.0.1`.

**Q: mDNS service discovery not working?**
A: Make sure the Mac and phone are on the same LAN and the network equipment supports mDNS / mDNS cross-subnet forwarding. You can also enter the IP manually.

**Q: How do I add my own ACP Agent?**
A: Add the agent configuration to `providers.list` in `config.json` (the `command` field takes a launch command array), then restart the backend.

**Q: How do I reset all data?**
A: Delete `kanban.db` and `config.json`, then re-run `bash scripts/setup.sh`.

---

## 📚 Resources

### Protocol Specifications
- [Agent Client Protocol (ACP)](https://agentclientprotocol.com/) — Agent communication protocol standard
- [AG-UI Protocol](https://docs.ag-ui.com/) — Structured message rendering protocol
- [A2A Protocol](https://github.com/google/A2A) — Agent-to-Agent communication protocol

---

## 📄 License

MIT License — see [LICENSE](LICENSE) file for details.
