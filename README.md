# Agent Kanban (MyBot)

> **策划即执行，执行即记录** —— AI 原生任务管理系统

[![Python 3.10+](https://img.shields.io/badge/Python-3.10+-blue.svg)](https://www.python.org/)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-green.svg)](https://flutter.dev/)
[![ACP](https://img.shields.io/badge/ACP-Compliant-orange.svg)](https://agentclientprotocol.com/)
[![AG-UI](https://img.shields.io/badge/AG--UI-Protocol-purple.svg)](https://docs.ag-ui.com/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20|%20Linux%20|%20Windows-blue)](https://github.com/flown/myrepo)

---

## 📖 简介

**Agent Kanban (MyBot)** 是一个将 AI Agent 直接集成到工作流的看板任务管理系统。它解决了长周期（2-3 个月）项目开发中的两大痛点：

- **手动记录成本高** — 传统方式下，开发者需要手动记录工作内容、保存对话历史
- **上下文连续性断裂** — 切换任务时丢失之前的决策背景和实现细节

通过**看板替代 IDE** 作为主界面，实现"策划即执行，执行即记录"的无缝工作流。

### 核心特性

- 🔄 **实时双向通信** — Flutter App ⇄ Bridge ⇄ ACP Agent
- 🔐 **端到端加密** — E2EE (X25519 + AES-256-GCM)，数据私有安全
- 🌐 **三级连接策略** — mDNS → 云中继 (Relay) → 云端 SaaS，智能降级
- 🤖 **多 Agent 支持** — Gemini CLI, Qwen Code, OpenClaw, Cline CLI 等
- 📋 **卡片级会话隔离** — 每个卡片独立 Session，跨卡片可关联
- 🔍 **混合检索** — SQLite FTS5 + sqlite-vec 语义搜索
- 🎨 **可视化列管理** — 拖拽排序、自定义列名和颜色
- ⏱️ **项目时间轴** — 聚合所有卡片事件的全局视图
- 📄 **AG-UI 协议集成** — 结构化消息渲染、工具调用状态胶囊、推理过程折叠展示

---

## 🏗️ 系统架构

### 全链路数据流

```
┌───────────────────────────────────────────────────────────────────────┐
│                         Flutter App (iPhone / Mac)                    │
│  ┌─────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ 看板视图   │  │ 卡片详情页    │  │ 连接设置      │  │ 时间轴视图    │   │
│  └────▲─────┘  └──────▲───────┘  └──────▲───────┘  └──────▲───────┘   │
│       │               │                 │               │             │
│  ┌────┴───────────────┴─────────────────┴───────────────┴────┐        │
│  │                Smart Connect 连接管理器                      │        │
│  │    mDNS (内网)       Relay (云端中继)      Cloud (SaaS)      │        │
│  └────────────────────────────▲──────────────────────────────┘        │
│                               │ E2EE (X25519 + AES-256-GCM)           │
└───────────────────────────────┼───────────────────────────────────────┘
                                │ WebSocket
┌───────────────────────────────┼───────────────────────────────────────┐
│                    Mac Bridge (Python Backend)                        │
│                               │                                       │
│  ┌────────────────────────────┴──────────────────────────────┐        │
│  │                     ACP Bridge                              │       │
│  │  ┌──────────┐  ┌──────────────┐  ┌──────────────┐         │       │
│  │  │ E2EE 加密 │  │ Session 管理  │  │ 权限控制      │         │       │
│  │  └──────────┘  └──────────────┘  └──────────────┘         │       │
│  └────────────────────────▲──────────────────────────────────┘        │
│                           │                                          │
│  ┌────────────────────────┴──────────────────────────────────┐        │
│  │                  AG-UI Mapper                              │       │
│  │    ACP 事件流  ←→  AG-UI 结构化消息 (Thinking/工具/文本)     │       │
│  └────────────────────────▲──────────────────────────────────┘        │
│                           │                                          │
│  ┌────────────────────────┴──────────────────────────────────┐        │
│  │                    REST API (FastAPI)                      │       │
│  │  /api/projects  /api/cards  /api/columns  /api/sessions    │       │
│  └────────────────────────▲──────────────────────────────────┘        │
│                           │                                          │
│  ┌────────────────────────┴──────────────────────────────────┐        │
│  │                   混合数据库 (SQLite)                       │       │
│  │  FTS5 全文搜索  │  sqlite-vec 语义搜索  │  WAL 并发模式     │       │
│  └───────────────────────────────────────────────────────────┘        │
└───────────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
            ┌───────▼───────┐       ┌───────▼───────┐
            │  ACP Agent    │       │  MCP Server   │
            │ (Gemini/Qwen) │       │ (tree-sitter) │
            └───────────────┘       └───────────────┘
```

### 数据层设计

| 层级 | 内容 | 更新频率 |
|------|------|----------|
| **Level 1: Global** | 项目摘要、agent.md、所有卡片摘要 | 卡片建立时加载 |
| **Level 2: Related** | 关联卡片的摘要 | 动态查询 |
| **Level 3: Focus** | 当前卡片的完整对话流和执行记录 | 实时 |

### 目录结构

```
acpkanban/
├── api/                    # FastAPI 端点
│   ├── main.py             # API 入口
│   ├── cards.py            # 卡片 CRUD
│   ├── columns.py          # 列管理
│   ├── projects.py         # 项目管理
│   ├── sessions.py         # 会话管理
│   ├── providers.py        # ACP Provider
│   └── ...
├── src/
│   ├── logic/              # 工作流/会话逻辑
│   │   ├── context.py      # 上下文构建
│   │   └── tools/          # 内置工具
│   ├── persistence/        # SQLite + 索引 + 嵌入
│   │   ├── database.py     # 数据库核心
│   │   ├── embedding.py    # 向量嵌入
│   │   └── indexer.py      # 增量索引
│   ├── protocol/           # ACP / AG-UI 协议
│   │   ├── adapter.py      # ACP 协议适配
│   │   ├── ag_ui_mapper.py # ACP → AG-UI 映射
│   │   ├── mcp_code.py     # 代码工具 (MCP)
│   │   ├── mcp_kanban.py   # 看板工具 (MCP)
│   │   └── drivers/        # ACP 驱动
│   ├── transport/          # 网络传输
│   │   ├── bridge.py       # ACP Bridge 核心
│   │   ├── bridge_ws.py    # WebSocket 传输
│   │   ├── e2ee.py         # 端到端加密
│   │   ├── mdns.py         # mDNS 服务发现
│   │   └── relay_server.py # 中继服务
│   ├── config/             # 配置管理
│   └── utils/              # 工具函数
├── flutter_prototype/      # Flutter 前端
│   ├── lib/
│   │   ├── main.dart       # 应用入口
│   │   ├── screens/        # 页面 (看板/卡片详情/连接设置)
│   │   ├── widgets/        # 组件 (19 个)
│   │   ├── services/       # 服务层 (12 个)
│   │   ├── models/         # 数据模型 (14 个)
│   │   ├── theme/          # 主题
│   │   └── utils/          # 工具函数
│   └── test/               # Flutter 测试
├── scripts/
│   ├── setup.sh            # 一键初始化脚本
│   ├── install_relay.sh    # Relay 远程安装脚本
│   └── relay/              # Relay 部署文件
├── conductor/              # 规划/设计文档 (17 份)
├── tests/                  # Python 测试
├── run_all.py              # 一键启动 (API + Bridge + Relay)
├── run_bridge.py           # Bridge 单独启动
├── acp_server.py           # 独立 ACP Server
└── config.json             # 运行配置
```

---

## 🚀 快速开始

### 环境要求

- Python 3.10+
- Flutter SDK 3.x
- SQLite (支持 FTS5 和 WAL 模式)
- Node.js (可选，用于工具链)

### 一行命令安装（推荐）

```bash
curl -fsSL https://github.com/<你的用户名>/acpkanban/install.sh | bash
```

脚本自动完成：克隆仓库 → 检测系统 → 安装依赖 → 初始化配置 → 输出连接凭据。

> 支持 macOS 和 Linux。Windows 用户请参考下方"分步安装"手动配置。

### 一键初始化（源码目录内运行）

```bash
# 从项目根目录运行
bash scripts/setup.sh
```

脚本会自动完成：
1. ✅ 检测操作系统 (macOS / Linux)
2. ✅ 安装系统依赖（如 `python3-venv`）
3. ✅ 创建 `.venv` 虚拟环境
4. ✅ 安装 Python 依赖
5. ✅ 初始化数据库和配置文件 (`config.json`)
6. ✅ 生成启动脚本 (`start.sh` / `start_api.sh` / `start_dev.sh`)
7. ✅ 输出连接凭据（`USER_ID`、`RELAY_TOKEN`、`API_TOKEN`）
8. ✅ 创建快捷命令（安装后可通过 `acpkanban-relay` 直接执行 Relay 安装）

> **注**：当前 `setup.sh` 仅支持 macOS 和 Linux。Windows 用户请在项目根目录下手动执行 `pip install -r requirements.txt` 并参考下方"分步安装"完成配置。

### 分步安装

#### 1. Python 后端

```bash
# 安装依赖
pip install -r requirements.txt

# 启动 API 服务
uvicorn api.main:app --host 0.0.0.0 --port 8000

# 访问 API 文档
open http://localhost:8000/docs
```

#### 2. Bridge 服务

```bash
# 本地开发模式
python run_bridge.py --user-id <your-user-id>

# 中继模式
python run_bridge.py \
  --user-id <your-user-id> \
  --relay-url wss://relay.acpkanban.siliconpulse.cc/ws \
  --token <auth-token>

# 指定工作目录
python run_bridge.py --workspace-cwd /path/to/project
```

#### 3. 一键启动（开发常用）

```bash
# 同时启动 API + Bridge + 本地 Relay
./start.sh

# 或使用源码启动
python run_all.py
```

#### 4. Flutter 前端

```bash
cd flutter_prototype

# 安装依赖
flutter pub get

# 运行应用 (选择 iPhone/Mac 模拟器)
flutter run

# 构建发行版
flutter build ios
flutter build macos
flutter build apk
```

### 首次连接

1. 运行 `bash scripts/setup.sh` 或从 `config.json` 获取 `USER_ID` 和 `API_TOKEN`
2. 启动后端服务 (`./start.sh`)
3. 打开 Flutter App → 进入"连接设置"
4. 输入 Mac 的局域网 IP、端口、`USER_ID`、`API_TOKEN`
5. 连接成功后即可看到看板

---

## 🔧 配置说明

### 凭据系统

系统使用 **手动输入凭据** 的认证方式（非配对码）：

```
┌─ config.json ─────────────────────────────────┐
│  {                                              │
│    "user_id": "生成的用户 ID",                     │
│    "api_token": "生成的 API Token",               │
│    "relay_token": "生成的中继 Token"               │
│  }                                               │
└─────────────────────────────────────────────────┘
```

- 首次运行 `setup.sh` 或后端时自动生成凭据
- 用户手动将凭据输入 Flutter App 的连接设置页面
- 修改 `config.json` 中的凭据并重启服务即可重置

### ACP Provider 配置 (`acp_config.json`)

```json
{
  "providers": [
    {
      "id": "gemini",
      "name": "Gemini CLI",
      "command": ["gemini", "--acp"],
      "icon": "bolt"
    },
    {
      "id": "qwen",
      "name": "Qwen Code",
      "command": ["qwen", "--acp"],
      "icon": "code"
    }
  ],
  "session_idle_timeout_minutes": 30,
  "max_sessions": 30
}
```

### 支持的 ACP Providers

| Provider | 命令 | 状态 |
|----------|------|------|
| Gemini CLI | `gemini --acp` | ✅ 已支持 |
| Qwen Code | `qwen --acp` | ✅ 已支持 |
| OpenClaw | `openclaw acp` | ✅ 已支持 |
| Cline CLI | `cline --acp` | ✅ 已支持 |

### 远程 SSH Provider

对于需要在远程服务器运行的 Provider：

```json
{
  "id": "gemini_remote",
  "name": "Gemini Remote",
  "command": [
    "ssh", "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=60",
    "user@remote-host",
    "zsh -ic 'gemini --acp'"
  ]
}
```

### Provider 级配置

每个 Provider 还可以有独立的配置文件：
- `GEMINI.md` — Gemini CLI 行为指引
- `QWEN.md` — Qwen Code 行为指引
- `AGENTS.md` — 仓库级开发指南（自动注入上下文）

---

## 📡 安全与网络

### Smart Connect 三级连接策略

用户在 App 端可选择优先连接方式：

```
┌──────────────────────────────────────────────────────────────┐
│                      Smart Connect                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ① mDNS (内网直连) ──── 延迟 <5ms, 数据不出局域网            │
│       ↓ 连接失败                                              │
│  ② Relay (云端中继) ──── NAT 穿透, 端到端加密                 │
│       ↓ 连接失败                                              │
│  ③ Cloud (云端 SaaS) ── 服务始终在线, 兜底方案                │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### E2EE 端到端加密

<details>
<summary>点击展开加密详情</summary>

```
┌──────────────┐                    ┌──────────────┐
│  Flutter App │                    │  Mac Bridge  │
│  生成 X25519 密钥对              │  生成 X25519 密钥对  │
│      │       │                    │       │       │
│      │◄─────── ECDH 交换 ────────►│       │       │
│      │         (公钥交换)         │       │       │
│      ▼       │                    ▼       │       │
│  计算共享 Session Key           │  计算共享 Session Key │
│      │       │                    │       │       │
│      │◄─────── AES-256-GCM 加密消息 ────►│       │
│                                          (仅转发，不可解密)│
└──────────────┘                    └──────────────┘
                   云端中继 (WebSocket Relay)
```

**加密规格：**
- 密钥交换：X25519 椭圆曲线 Diffie-Hellman
- 对称加密：AES-256-GCM
- 密钥生命周期：Bridge 重启时重新生成，不持久化
- 认证：Token + 设备配对

</details>

### Relay 中继部署

系统支持将 Relay 部署到远程 Linux 服务器：

```bash
# 一键安装（本地执行）
./scripts/install_relay.sh
```

安装过程中会询问：
1. **服务器 IP** 和 **SSH 端口**
2. **SSH 密码**（支持 sshpass）或使用已有 SSH Key
3. **中继端口**（默认 8765）
4. **是否安装 systemd 服务** — 选择后自动创建系统用户并守护进程

脚本自动完成：打包源文件 → SCP 上传 → 安装 Python 依赖 → 配置运行方式。

---

## 📦 多平台部署

### 服务端（本地）

Python 后端本身是跨平台的，但安装体验因系统而异：

| 系统 | 安装方式 | 注意事项 |
|------|---------|----------|
| **macOS** | `bash scripts/setup.sh`（推荐）或分步安装 | 需要 Xcode CLI Tools |
| **Linux** | `bash scripts/setup.sh`（推荐）或分步安装 | 自动通过 `apt-get` 安装 `python3-venv` |
| **Windows** | 手动安装 | 暂无 `setup.ps1`，见下方说明 |

#### Windows 手动安装步骤

```powershell
# 1. 安装 Python 3.10+ (确保勾选 "Add to PATH")
# 2. 在项目目录中创建虚拟环境
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt

# 3. 启动 API
.venv\Scripts\uvicorn api.main:app --host 0.0.0.0 --port 8000

# 4. 启动 Bridge
.venv\Scripts\python run_bridge.py --user-id <your-user-id>
```

> **注意**：Windows 上某些原生编译依赖（`tree-sitter`、`sqlite-vec`）可能需要 Visual Studio Build Tools。如果失败，核心功能（看板 CRUD、FTS5 搜索）不受影响。

### 客户端构建

Flutter 项目已预置 5 个平台目录（`ios/`、`android/`、`macos/`、`windows/`、`linux/`），可直接构建。

| 平台 | 构建命令 | 输出文件 | 分发方式 |
|------|---------|---------|---------|
| **iOS** | `flutter build ios --release --no-codesign` | `.app` → Xcode Archive → `.ipa` | **TestFlight** 外部测试 |
| **Android** | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` | **APK** 直接分发 |
| **macOS** | `flutter build macos --release` | `build/macos/Build/Products/Release/kanban_app.app` | **DMG** 安装镜像 |
| **Windows** | `flutter build windows --release` | `build/windows/runner/Release/` (exe + DLLs) | **ZIP** 或 **Inno Setup** 安装包 |
| **Linux** | `flutter build linux --release` | `build/linux/x64/release/bundle/` | **AppImage** / **Flatpak** |

#### macOS → DMG

```bash
flutter build macos --release
brew install create-dmg
create-dmg --volname "MyBot" \
  --app-drop-link 180 110 \
  --window-pos 200 120 \
  --window-size 600 400 \
  MyBot.dmg build/macos/Build/Products/Release/kanban_app.app
```

#### Windows 构建说明

需在 **Windows 开发机** 上操作：

```powershell
# 安装 Flutter SDK + Visual Studio 2022 (勾选 "Desktop development with C++")
# 构建
cd flutter_prototype
flutter build windows --release

# 输出目录: build/windows/runner/Release/
# 可用 Inno Setup 或 NSIS 将整个目录打包为 .exe 安装包
```

#### Android APK

```bash
cd flutter_prototype
flutter build apk --release
# APK 路径: build/app/outputs/flutter-apk/app-release.apk
```

#### iOS TestFlight

```bash
cd flutter_prototype
flutter build ios --release --no-codesign
# 然后用 Xcode 打开 ios/Runner.xcworkspace
# Product → Archive → Distribute App → TestFlight
```

---

## 📊 数据库模型

### 核心表结构

```sql
-- 项目管理
projects(id, name, workspace_cwd, created_at, updated_at)

-- 列配置（支持拖拽排序）
columns(id, project_id, name, color, position)

-- 卡片
cards(id, column_id, title, description, status, summary,
      feature_id, created_at, completed_at)

-- 会话管理
card_sessions(id, card_id, session_id, provider_id,
              started_at, last_activity)

-- 对话历史（支持 AG-UI 结构化消息）
card_session_messages(id, session_id, role, content, metadata)

-- 项目时间轴（全局事件聚合）
project_timeline(id, project_id, event_type, card_id,
                 payload, created_at)

-- 卡片摘要
summaries(card_id, summary, generated_at)
```

### Timeline 事件类型

| 事件 | 触发时机 | 元数据 |
|------|---------|--------|
| `card_created` | 创建卡片 | 标题、所属列 |
| `card_moved` | 跨列移动 | `from_column` → `to_column` |
| `card_completed` | 标记完成 | 总耗时 |
| `card_session_started` | 启动会话 | Provider、prompt 模板 |
| `summary_generated` | 生成摘要 | 长度、关键词 |
| `column_created/updated/deleted` | 列变更 | 名称、颜色 |

### 搜索能力

- **全文搜索 (FTS5)** — 关键字精确匹配
- **语义搜索 (sqlite-vec)** — 向量相似度检索
- **混合查询** — 结合两种方式的复合检索
- **增量索引** — 文件变更自动重新索引

---

## 🌐 API 端点

### 项目管理
| Method | Endpoint | 描述 |
|--------|----------|------|
| GET | `/api/projects` | 获取项目列表 |
| POST | `/api/projects` | 创建新项目 |
| GET | `/api/projects/{id}` | 获取项目详情 |
| PUT | `/api/projects/{id}` | 更新项目 |
| DELETE | `/api/projects/{id}` | 删除项目 |

### 列管理
| Method | Endpoint | 描述 |
|--------|----------|------|
| GET | `/api/projects/{id}/columns` | 获取列列表 |
| POST | `/api/projects/{id}/columns` | 创建新列 |
| PUT | `/api/columns/{id}` | 更新列 |
| PATCH | `/api/columns/{id}/position` | 调整列顺序 |
| DELETE | `/api/columns/{id}` | 删除列 |

### 卡片管理
| Method | Endpoint | 描述 |
|--------|----------|------|
| POST | `/api/cards` | 创建卡片 |
| GET | `/api/cards/{id}` | 获取卡片详情 |
| PUT | `/api/cards/{id}` | 更新卡片 |
| PATCH | `/api/cards/{id}/move` | 移动卡片 |
| DELETE | `/api/cards/{id}` | 删除卡片 |

### 会话管理
| Method | Endpoint | 描述 |
|--------|----------|------|
| GET | `/api/cards/{id}/session` | 获取会话历史 |
| POST | `/api/cards/{id}/session` | 发送消息到会话 |
| GET | `/api/cards/{id}/timeline` | 获取卡片时间轴 |

### 项目时间轴
| Method | Endpoint | 描述 |
|--------|----------|------|
| GET | `/api/projects/{id}/timeline` | 获取项目全局时间轴 |

---

## 🛠️ Tool System

系统通过 **REST API + Skills 指引** 与 Agent 交互（详见 `AGENTS.md`）：

### 看板操作（通过 HTTP API）
- `create_card`, `update_card`, `delete_card`, `move_card`
- `create_column`, `update_column`, `delete_column`
- 项目 CRUD

### 文件操作（通过 MCP/内置工具）
- `read_file` / `write_file` / `search_repo`
- `run_tests` / `execute_code`

### 工具集成方式

| 方式 | 说明 | 状态 |
|------|------|------|
| REST API | 通过 Agent Skills 指引，使用 HTTP 调用 | ✅ 推荐 |
| tree-sitter MCP | 通用代码分析 | ✅ 可选用 |

> **注**：自定义 MCP 服务器配置会在 ACP 协议握手时传递给 Agent，但主流 Agent CLI（Gemini CLI / Qwen Code）会忽略 `session/new` 中的 `mcpServers` 参数，改用自身的 MCP 配置。因此推荐通过 REST API + Skills 文档集成。

---

## 🎨 Flutter App 功能概览

### 页面 (Screens)
| 页面 | 说明 |
|------|------|
| **看板主页** | 多项目切换、列视图、卡片拖拽 |
| **卡片详情页** | 对话记录、Agent 交互、时间轴 |
| **连接设置页** | Smart Connect 配置、凭据输入 |

### 核心组件 (Widgets)
| 组件 | 说明 |
|------|------|
| `KanbanColumnWidget` | 列视图（支持拖拽排序） |
| `KanbanCardWidget` | 卡片卡片（标题、摘要、状态） |
| `ColumnManagerDialog` | 列管理对话框（添加/编辑/删除/拖动排序） |
| `CardDetailScreen` | 卡片详情（消息流、工具调用状态） |
| `MessageBubble` | AG-UI 结构化消息渲染 |
| `MessageShell` | 消息外壳（角色头像、时间戳） |
| `TimelineView` | 项目全局时间轴事件流 |
| `ProjectRoadmapView` | Feature 路线图视图 |
| `RoadmapManagerDialog` | 路线图管理对话框 |
| `ProjectManagementDialog` | 项目管理（创建/编辑/删除） |
| `ProjectSelector` | 项目切换器 |
| `DiffViewer` | 代码差异查看器 |
| `ContentBlockRenderer` | AG-UI 内容块渲染 |
| `StatusSummaryWidget` | 项目状态摘要 |
| `ConfigOptionsBar` | Provider 配置选项栏 |
| `PlanPanel` | Plan 模式面板 |
| `ConnectionSettingsScreen` | 连接设置页面 |
| `AppFeedback` | 反馈提示组件 |

### 连接服务
| 服务 | 说明 |
|------|------|
| `SmartConnect` | 三级连接策略管理 |
| `SessionWebSocketService` | WebSocket 会话（含 E2EE） |
| `ACPClient` | ACP 协议客户端 |
| `E2EEManager` | 端到端加密管理 |
| `ConnectionConfigManager` | 连接配置持久化 |
| `KanbanRefreshService` | 自动刷新服务（生命周期感知） |
| `ProjectService` | 项目数据服务 |
| `ThemeService` | 主题切换服务 |

---

## 🧪 开发与测试

### Python 后端测试

```bash
# 运行所有测试
pytest tests/

# 特定模块测试
python test_permission_flow.py
python test_db_progress.py
python test_config_backend.py

# 中继相关测试
python test_ws.py
```

### Flutter 前端测试

```bash
cd flutter_prototype

# 运行所有测试
flutter test

# 静态分析
flutter analyze
```

### 日志查看

```bash
# 实时查看 Bridge 日志
tail -f acpkanban.log

# 查看特定会话日志
grep "session_id" acpkanban.log
```

---

## 🔌 扩展性

### 自定义 Provider

在 `acp_config.json` 中添加新 Provider：

```json
{
  "id": "custom_agent",
  "name": "Custom AI Agent",
  "command": ["custom-agent", "--acp", "--config", "path/to/config.json"],
  "icon": "custom_icon_name"
}
```

### 设计文档

项目演进过程中的设计决策和讨论记录在 `conductor/` 目录中（17 份文档），涵盖：
- ACP 协议集成、AG-UI 消息优化
- E2EE 密钥管理、凭据系统设计
- 中继模式问题修复、Timeline 事件追踪
- 增量索引、上下文优化、用户管理等

---

## 📚 相关资源

### 协议规范
- [Agent Client Protocol](https://agentclientprotocol.com/)
- [AG-UI Protocol](https://docs.ag-ui.com/)

### 参考实现
- [Goose (GitHub)](https://block.github.io/goose/docs/guides/acp-clients)
- [Cline CLI](https://docs.cline.bot/cline-cli/acp-editor-integrations)
- [OpenClaw](https://docs.openclaw.ai/cli/acp)

### 官方 CLI 工具
- [Gemini CLI](https://github.com/google-gemini/gemini-cli)
- [Qwen Code](https://github.com/QwenLM/Qwen-Code)

---

## 🚧 Roadmap

### v0.4.0（进行中）
- [ ] AG-UI 协议深度集成（授权请求交互、进度反馈）
- [ ] Relay 自动重连优化（指数退避、生命周期感知刷新）
- [ ] 乐观 UI + 操作队列（弱网环境操作反馈）
- [ ] SQLite 本地缓存 + 对话预加载
- [ ] 一键远程安装 (`curl ... | bash` 模式)
- [ ] Windows 支持：`setup.ps1` PowerShell 安装脚本

### v0.5.0（规划中）
- [ ] Agent 主动提议看板变更
- [ ] 子卡片自动拆解
- [ ] Git 分支联动（卡片 ↔ Branch ↔ Commit）
- [ ] 客户端 CI/CD 自动构建（iOS/Android/Mac/Windows）

### 长期愿景
- [ ] 自动化工作流引擎（规则触发 → 自动执行）
- [ ] 多项目协同（跨项目卡片引用）
- [ ] 团队共享看板
- [ ] 插件生态（浏览器、IM 连接器）

---

## 📝 版本历史

### v0.3.1（当前）
- ✅ Look 和 Feel 打磨（无实际功能变更）
- ✅ 卡片详情页对话记录缓存优化
- ✅ Relay 安装时 systemd 可选

### v0.3.0
- ✅ 完整的列管理和卡片拖拽移动
- ✅ Column Manager 可视化对话框（拖拽排序）
- ✅ 会话级权限控制
- ✅ Timeline 事件聚合（10+ 事件类型）
- ✅ 多项目支持
- ✅ 项目路线图（Feature）视图
- ✅ 增量索引引擎

### v0.2.0
- ✅ Smart Connect 三级连接策略
- ✅ E2EE 端到端加密（X25519 + AES-256-GCM）
- ✅ Relay 中继服务 + 远程安装脚本
- ✅ mDNS 内网发现

### v0.1.0
- ✅ 基础看板功能（列/卡片 CRUD）
- ✅ ACP Bridge 实现
- ✅ SQLite 持久化（FTS5 全文搜索）
- ✅ AG-UI 结构化消息基础渲染

---

## 👥 团队成员

- @flown — 核心架构 & 后端开发

---

## 📄 License

MIT License — see [LICENSE](LICENSE) file for details

---

## 🆘 常见问题

### Q: 如何重置某个卡片的 Session？
A: 在卡片详情页点击右上角菜单，选择"Reset Session"，或直接调用 `POST /api/cards/{id}/session/new`

### Q: 怎样禁用某个 Provider？
A: 在 `acp_config.json` 中移除对应条目，或在 UI 的设置页面取消勾选

### Q: 数据备份在哪里？
A: 主要数据存储在 `kanban.db`（SQLite），建议定期备份该文件

### Q: 中继服务器挂了怎么办？
A: 系统会自动降级到 SaaS Cloud 模式（如果已配置），或提示用户切换到内网模式

### Q: 如何升级到最新版本？
A: `git pull` 拉取最新代码，然后重新运行 `bash scripts/setup.sh`（会保留已有 `config.json` 和数据库）

### Q: mDNS 找不到我的 Mac？
A: 确保 Mac 和手机在同一个局域网，检查防火墙是否阻止了 mDNS 端口（5353）。也可以手动输入 IP 地址连接

### Q: Flutter App 连接后看不到看板？
A: 检查 `USER_ID` 和 `API_TOKEN` 是否匹配后端 `config.json` 中的值。在"连接设置"中重新输入凭据后重试

### Q: 如何切换中继服务器？
A: 在"连接设置"页面修改 Relay URL 字段，或直接修改 `config.json` 中的 `relay.url` 并重启服务

### Q: 如何生成 iOS 的 TestFlight 构建？
A: 见上方"多平台部署 → 客户端构建 → iOS TestFlight"章节

### Q: 如何生成 Android APK？
A: 在 `flutter_prototype/` 目录执行 `flutter build apk --release`，APK 位于 `build/app/outputs/flutter-apk/app-release.apk`

### Q: macOS 构建输出什么格式？
A: `flutter build macos --release` 生成 `.app` bundle。推荐用 `create-dmg` 打包为 `.dmg` 安装镜像。详见"多平台部署"章节

### Q: 是否支持 Windows 客户端？
A: 是。Flutter 项目已包含完整的 `windows/` 构建配置和插件集成。在 Windows 开发机上运行 `flutter build windows --release` 即可