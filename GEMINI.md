# MyBot Bridge: Gemini & Qwen Telegram Integration

## Project Overview

MyBot is a sophisticated **Telegram Bot Bridge** that connects Telegram to the power of `gemini` and `qwen` CLI tools. It enables complex task execution and deep reasoning through a tiered memory system and native session management.

### Key Features
- **Multi-Bot Isolation**: Support for different bot identities (e.g., `probe`, `task`) with isolated data, logs, and workspaces.
- **Dual Engine Support**: Seamless switching between Google `gemini` and Alibaba `qwen` CLIs.
- **Tiered Memory System**:
    - **Raw Logs**: `bots/{name}/logs/YYYY-MM-DD.md`
    - **Daily Briefs**: Summary of daily facts in `memory_summary.md`.
    - **Vector RAG**: Semantic search via vectorized memory.
- **Native Vision & Execution**: Integrated screen capture analysis, multimedia tools (`ffmpeg`, `yt-dlp`), and Google Workspace access (`gws`).

---

## Directory Structure

- `gemini_telegram_bridge.py`: The main entry point and bridge logic.
- `project_context.md`: Detailed architectural design and progress logs.
- `bots/`: Directory containing specific bot instances.
    - `probe/`: General-purpose research and exploration bot.
    - `task/`: Specialized bot for strategy and automation.
- `scripts/`: Utility scripts for authentication and environment setup.
- `skills/`: Extensible tool definitions.

---

## Getting Started

### Prerequisites
- Python 3.10+
- `gemini` and `qwen` CLI tools installed and configured.
- `.env` file with `TELEGRAM_BOT_TOKEN` and `ALLOWED_USER_ID`.

### Running the Bridge
To start a specific bot instance, use the `--name` argument:

```bash
python3 gemini_telegram_bridge.py --name probe
```

Or for the task-focused bot:

```bash
python3 gemini_telegram_bridge.py --name task
```

### Commands in Telegram
- `/engine <gemini|qwen>`: Switch between engines.
- `/summary`: Manually trigger a daily summary.
- `/reset`: Clear the current session.

---

## Development Guidelines

1. **Multi-Bot Awareness**: Always ensure changes to the bridge logic respect the `--name` isolation. Data should be read from/written to the correct `bots/{name}/workspace/` directory.
2. **Memory Integrity**: Use the tiered memory system for long-term context. Avoid overwriting `MEMORY.md` without reading it first.
3. **CLI-First**: Prefer using the underlying CLI's native session management (`--resume` or `--continue`) to maintain conversational context.
4. **Validation**: Before committing bridge changes, test across both engines (`gemini` and `qwen`) to ensure compatibility.

---

## Important Files
- `gemini_telegram_bridge.py`: Main bridge implementation.
- `project_context.md`: The "source of truth" for project status and architecture.
- `bots/{name}/workspace/GEMINI.md`: Bot-specific instructions and identity.
