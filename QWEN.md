# MyBot — Telegram Bot Bridge for Gemini & Qwen

A Telegram bot bridge that connects Telegram with Gemini and Qwen CLI tools, featuring a three-tier memory architecture for long-term context retention. Enables AI agents to interact with users via Telegram while having real access to the operating system, files, and Google Workspace.

---

## Project Overview

**Purpose:** Provide a persistent, multi-bot Telegram interface for AI agents with:
- Native session management (no context window limits)
- Three-tier memory for long-term knowledge retention
- Dual-engine support (Gemini + Qwen CLI)
- Google Workspace integration via `gws` CLI
- Vision capabilities (screenshot analysis)
- Multi-bot isolation (separate identity, logs, workspace per bot)

**Core Technologies:**
- Python 3.x with asyncio
- Telegram Bot API (`python-telegram-bot`)
- Google GenAI SDK
- Google Workspace CLI (`gws`)
- Gemini CLI & Qwen CLI

---

## Architecture

### Core Bridge (`gemini_telegram_bridge.py`)

The main bot orchestrator handles:
- Multi-bot instance management (probe, task, etc.)
- Message routing and rendering (HTML mode for Telegram)
- CLI subprocess execution with timeout handling
- Token usage tracking and display
- Vision pipeline (screenshot → analysis)

### Three-Tier Memory System

| Tier | Storage | Purpose |
|------|---------|---------|
| **Raw Logs** | `bots/{name}/logs/YYYY-MM-DD.md` | Real-time conversation logs for debugging |
| **Fact Summaries** | `bots/{name}/gemini_memory/memory_summary.md` | AI-extracted facts (common knowledge base) |
| **Vector RAG** | `bots/{name}/gemini_memory/memory.json` | Full conversation history for semantic search |

### Bot Instance Isolation

Each bot (`probe`, `task`, etc.) has its own:
- `bots/{name}/logs/` — Daily conversation logs
- `bots/{name}/gemini_memory/` — Memory files
- `bots/{name}/workspace/` — Working directory for file operations
- `bots/{name}/workspace/agent.md` — Identity/personality config
- `bots/{name}/workspace/GEMINI.md` / `QWEN.md` — Engine-specific instructions

---

## Configuration

### Environment Variables (`.env`)

```bash
# Required
ALLOWED_USER_ID=<your_telegram_user_id>
GEMINI_API_KEY=<your_gemini_api_key>
PROBE_BOT_TOKEN=<telegram_bot_token_for_probe>
TASK_BOT_TOKEN=<telegram_bot_token_for_task>

# Optional (for gws CLI)
GOOGLE_WORKSPACE_CLI_TOKEN=<oauth_token>
GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=<path_to_credentials.json>
```

### Bot Naming Convention

Bot names are derived from environment variable suffixes:
- `PROBE_BOT_TOKEN` → bot name: `probe`
- `TASK_BOT_TOKEN` → bot name: `task`

Each bot creates its own directory under `bots/{name}/`.

---

## Running the Bot

### Prerequisites

1. **Python packages:**
   - `python-telegram-bot`
   - `google-genai`
   - `Pillow`
   - `python-dotenv`

2. **CLI tools:**
   - `gemini` (Google Gemini CLI)
   - `qwen` (Alibaba Qwen CLI)
   - `gws` (Google Workspace CLI) — optional

3. **System tools (Mac):**
   - `screencapture` — for vision screenshots
   - `afplay` — for notification sounds

### Start Command

```bash
python gemini_telegram_bridge.py
```

The bot will auto-detect all `{NAME}_BOT_TOKEN` environment variables and start one instance per token.

### Bot Commands

| Command | Description |
|---------|-------------|
| `/engine gemini` | Switch to Gemini engine |
| `/engine qwen` | Switch to Qwen engine |
| `/new` | Reset session (skip resume/continue) |
| `/summary` | Generate daily fact summary via AI |

---

## Development & Debugging

### Logging

- **Console:** Real-time info logs per bot (`[BOT_NAME]` prefix)
- **Debug logs:** Daily rolling files in `bots/{name}/logs/YYYY-MM-DD.log`
- **HTTP/X logging:** Suppressed to reduce noise

### Error Handling

- 120-second hard timeout on CLI execution
- Network exceptions (TimedOut, NetworkError) are silently ignored
- Catastrophic errors logged with full stack trace
- Notification sound played on completion/error

### Code Editing Best Practices

**When using the `edit` tool, always verify target content first:**

1. Use `grep_search` to find the exact line number
2. Use `read_file` with `offset` and `limit` to see the exact content
3. Copy the exact text (including whitespace) for `old_string`

Example workflow:
```bash
# 1. Find line number
grep_search: "self._save_memory()" → Found at line 277

# 2. Read exact content
read_file: offset=275, limit=5

# 3. Use exact content in old_string
```

This prevents "0 occurrences found" errors.

### Post-Modification Workflow

**After every code modification, always:**

1. **Syntax check:** `python3 -m py_compile gemini_telegram_bridge.py`
2. **Test run:** Start the bot and verify basic functionality
3. **Commit changes:** 
   ```bash
   git add <modified_files>
   git status && git diff HEAD && git log -n 3
   git commit -m "<concise message describing WHY, not WHAT>"
   git status  # confirm commit succeeded
   ```

Never leave code untested or uncommitted.

### Identity Files

Each bot maintains synchronized identity files:
- `workspace/agent.md` — Core personality (user-editable)
- `workspace/GEMINI.md` — Gemini-specific instructions (auto-generated)
- `workspace/QWEN.md` — Qwen-specific instructions (auto-generated)

The bridge appends mandatory system rules to identity files on each message:
- Bot identity name
- Working directory
- Vision capability reminder
- Output format requirement

---

## Google Workspace Integration

The bot integrates with Google Workspace via the `gws` CLI:

### Available Skills

Located in `bots/{name}/workspace/cli/skills/`:
- **gws-gmail** — Send, triage, watch emails
- **gws-drive** — File upload, download, search
- **gws-calendar** — Create events, check agenda
- **gws-tasks** — Manage task lists
- **gws-sheets** — Read/write spreadsheets
- **gws-docs** — Document creation/editing
- **gws-chat** — Google Chat integration
- **gws-keep** — Google Keep notes
- **gws-meet** — Meet space management
- **gws-forms** — Form creation
- **gws-classroom** — Classroom management
- Plus 40+ recipe workflows (backup, invite, schedule, etc.)

### Authentication

```bash
# One-time setup (requires gcloud CLI)
gws auth setup

# Subsequent logins
gws auth login

# Export for headless use
gws auth export --unmasked > credentials.json
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/credentials.json
```

---

## Message Rendering Pipeline

The bridge uses a smart HTML renderer for Telegram:

1. **Preserve code blocks** — Convert to `<pre>` tags
2. **Preserve tables** — Detect markdown tables, wrap in `<pre>`
3. **Inline code** — Convert to `<code>` tags
4. **Bold/Italic** — Convert `**text**` → `<b>`, `_text_` → `<i>`
5. **Headers** — Convert `# Header` → `<b>Header</b>`
6. **Truncation** — Safe HTML truncation at 4000 chars with tag balancing

---

## Session Management

### Native Session Mode

The bridge leverages CLI-native session persistence:

| Engine | Flag | Behavior |
|--------|------|----------|
| Gemini | `--resume=latest` | Continues from last conversation |
| Qwen | `--continue` | Continues within workspace context |

Use `/new` to skip session resume for one turn (fresh context).

### Context Construction

Each message builds context from:
1. **Fact summaries** — Last 50 lines of `memory_summary.md`
2. **User message** — Prefixed with "老兵:" (user identifier)
3. **Session flag** — Optional `--resume` or `--continue`

---

## Vision Pipeline

When the CLI creates a `screenshot.png` in the workspace:

1. Bot detects new screenshot (mtime > command start time)
2. Sends image to Telegram
3. Calls Gemini Vision API with user query
4. Returns vision analysis as response

This enables "dual-pass" vision: execute → observe → analyze.

---

## Known Issues & TODOs

### Pending Optimizations

- **Qwen token stats:** Occasional failure to parse token usage (needs improved JSON recursion)
- **Single-process multi-bot:** Async event loop conflicts — currently using separate windows
- **Auto-summary:** Consider `launchd` for scheduled automatic archiving

### Future Enhancements

- **Google Tasks deep integration** — Sync with mobile tasks
- **Autonomous vision monitoring** — Bot decides when to screenshot
- **Smart log cleanup** — Archive cold data, retain summaries

---

## File Structure Reference

```
mybot/
├── gemini_telegram_bridge.py    # Main bot orchestrator
├── project_context.md           # Project documentation (Chinese)
├── .env                         # Environment variables (gitignored)
├── bots/
│   ├── probe/                   # Probe bot instance
│   │   ├── logs/                # Daily logs
│   │   ├── gemini_memory/       # Memory files
│   │   └── workspace/           # Working directory
│   └── task/                    # Task bot instance
│       └── ...
├── scripts/
│   ├── start_gcloud_auth.py     # gcloud authentication helper
│   └── gcloud_login.exp         # Expect script for gcloud login
└── logs/                        # (gitignored) Legacy log directory
```

---

## Security Notes

- **Allowed users:** Only `ALLOWED_USER_ID` can interact with the bot
- **Credential storage:** `.env` and `venv/` are gitignored
- **Destructive commands:** Bot runs in YOLO mode — exercise caution
- **Data exfiltration:** Do not share private data in group contexts
