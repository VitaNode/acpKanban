# MyBot (Gemini & Qwen Telegram Bridge)

A robust, multi-bot Telegram bridge that connects Telegram users with Google's `gemini` and Alibaba's `qwen` CLI tools. It provides a persistent, tool-enabled AI assistant with sophisticated memory systems and deep system integration on macOS.

## Project Overview

MyBot serves as a powerful interface for AI-driven automation, featuring:
- **Multi-Bot Support:** Run multiple independent bot instances (e.g., `probe`, `task`) with isolated data and workspaces.
- **Dual-Engine Logic:** Seamlessly switch between `gemini` and `qwen` engines during live sessions.
- **Native Session Management:** Leverages the native session persistence of the underlying CLI tools.
- **Sophisticated Memory:** A tiered memory architecture ensuring long-term context retention and structured fact tracking.
- **Tool Integration:** Built-in support for vision analysis (`screencapture` + Vision models), media processing (`ffmpeg`, `yt-dlp`), and Google Workspace (`gws`).
- **Robustness:** Handles message splitting for Telegram's 4000-character limit, offline retries via an outbox, and long-running CLI tasks (up to 10-minute timeouts).

## Architecture & Memory System

### Tiered Memory (Three-Layer Architecture)
1. **Raw Logs (Level 1):** Complete conversation history recorded daily in `bots/{name}/logs/YYYY-MM-DD.md`.
2. **Daily Briefs / Facts (Level 2):** Structured, permanent facts (e.g., user preferences, project paths) extracted via `/summary` and stored in `bots/{name}/gemini_memory/memory_summary.md`.
3. **Vector RAG (Level 3):** Semantic search capabilities using `memory.json` to retrieve relevant past interactions based on context.

### Project Structure
- `gemini_telegram_bridge.py`: Core application logic and Telegram bot handler.
- `bots/`: Instance-specific data, including logs, memory, and local workspaces.
- `logs/`: Main bridge system logs (`bridge.log`).
- `scripts/`: Helper scripts for gcloud authentication and other utilities.
- `venv/`: Python virtual environment.
- `project_context.md` & `project_notes.md`: Detailed documentation and progress tracking.

## Building and Running

### Prerequisites
- **Python 3.10+** (v3.14 used in development environment).
- **macOS** (for tools like `afplay`, `screencapture`, and `cliclick`).
- **Required Libraries:** `python-telegram-bot`, `google-generativeai`, `Pillow`, `python-dotenv`.
- **CLI Tools:** `gemini` and `qwen` CLI tools must be installed and available in the system path or bot workspace.

### Environment Setup
1.  **Activate Virtual Environment:**
    ```bash
    source venv/bin/activate
    ```
2.  **Configuration:** Create a `.env` file in the root with:
    ```env
    ALLOWED_USER_ID=your_telegram_user_id
    GEMINI_API_KEY=your_gemini_api_key
    PROBE_BOT_TOKEN=your_probe_bot_token
    TASK_BOT_TOKEN=your_task_bot_token
    # Add tokens for other bots as needed
    ```

### Running the Project
```bash
python gemini_telegram_bridge.py
```

### Key Commands (via Telegram)
- `/engine <gemini|qwen>`: Switch the active LLM engine for the current session.
- `/new`: Reset the current session and start fresh.
- `/summary`: Manually trigger the extraction of today's key facts into the permanent memory.

## Development Conventions

### Coding Style & Maintenance
- **Direct CLI Execution:** Most tasks are performed by executing CLI commands via `subprocess`.
- **Logging:** All DEBUG level logs are output to the terminal; INFO and above are persisted via daily rotating file handlers.
- **Identity Management:** The `agent.md` file in each bot's workspace defines its core identity and is synced to the engine-specific configuration files (`GEMINI.md`/`QWEN.md`).

### Contribution & Editing
- **Surgical Edits:** When modifying code, use `grep_search` to locate line numbers, `read_file` to confirm context, and then perform targeted replacements.
- **Verification:** Every change should be followed by a syntax check, testing within the Telegram bot, and a descriptive commit.
- **Stability:** Changes to `gemini_telegram_bridge.py` should prioritize message reliability and error handling (e.g., the `outbox` mechanism).

### Testing
- Automated testing is primarily performed via live interaction with the bots in a development instance (`probe`).
- Large-scale changes should be validated against the `project_context.md` requirements.
