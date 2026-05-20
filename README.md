# Agent Kanban (MyBot)

> **策划即执行，执行即记录** —— AI 原生任务管理系统

[![Python 3.10+](https://img.shields.io/badge/Python-3.10+-blue.svg)](https://www.python.org/)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-green.svg)](https://flutter.dev/)
[![ACP](https://img.shields.io/badge/ACP-Compliant-orange.svg)](https://agentclientprotocol.com/)
[![AG-UI](https://img.shields.io/badge/AG--UI-Protocol-purple.svg)](https://docs.ag-ui.com/)

## 📖 简介

**Agent Kanban (MyBot)** 是一个将 AI Agent 直接集成到工作流的看板任务管理系统。它解决了长周期（2-3 个月）项目开发中的两大痛点：

- **手动记录成本高** — 传统方式下，开发者需要手动记录工作内容、保存对话历史
- **上下文连续性断裂** — 切换任务时丢失之前的决策背景和实现细节

通过**看板替代 IDE**作为主界面，实现"策划即执行，执行即记录"的无缝工作流。

### 核心特性

- 🔄 **实时双向通信** — Flutter App ⇄ Bridge ⇄ ACP Agent
- 🔐 **端到端加密** — E2EE (X25519 + AES-256-GCM)，数据私有安全
- 🌐 **三级连接策略** — mDNS → 中继云端 → SaaS 云端，智能降级
- 🤖 **多 Agent 支持** — Gemini CLI, Qwen Code, OpenClaw, Cline CLI 等
- 📋 **卡片级会话隔离** — 每个卡片独立 Session，跨卡片可关联
- 🔍 **混合检索** — SQLite FTS5 + sqlite-vec 语义搜索
- 🌈 **自定义列** — 灵活配置看板列名、颜色、顺序
- ⏱️ **项目时间轴** — 聚合所有卡片事件的全局视图

---

## 🏗️ 系统架构

```
                    ┌──────────────┐
                    │   混合 DB     │ ← SQLite (FTS5 + Vector)
                    │ (Projects/Cards/Sessions)
                    └──────┬───────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
    (retrieval)    (Session State)   (Tool Logging)
            │              │              │
┌───────────▼─────┐  ┌────▼────┐   ┌────▼────┐
│  Context Builder│  │  ACP    │   │  Tools  │
│  (全局/关联/聚焦) │  │ Bridge  │   │ (MCP)   │
└─────────────────┘  └────┬────┘   └─────────┘
                          │
           ┌──────────────┼──────────────┐
           │              │              │
    ┌──────▼─────┐  ┌────▼────┐   ┌────▼────┐
    │ Flutter App│  │mDNS/LAN │   │Relay/Cloud│
    └────────────┘  └─────────┘   └──────────┘
```

### 数据层设计

| 层级 | 内容 | 更新频率 |
|------|------|----------|
| **Level 1: Global** | 项目摘要、agent.md、所有卡片摘要 | 卡片建立时加载 |
| **Level 2: Related** | 关联卡片的摘要 | 动态查询 |
| **Level 3: Focus** | 当前卡片的完整对话流和执行记录 | 实时 |

---

## 🚀 快速开始

### 环境要求

- Python 3.10+
- Flutter SDK 3.x
- SQLite (支持 FTS5 和 wal 模式)
- Node.js (可选，用于工具链)

### 安装步骤

#### 1. Backend API Server

```bash
# 安装依赖
pip install -r requirements.txt

# 启动 API 服务
uvicorn api.main:app --host 0.0.0.0 --port 8000

# 访问 API 文档
open http://localhost:8000/docs
```

#### 2. Bridge Service

```bash
# 本地开发模式
python run_bridge.py --user-id <your-user-id>

# 中继模式
python run_bridge.py \
  --user-id <your-user-id> \
  --relay-url wss://relay.mybot.siliconpulse.cc/ws \
  --token <auth-token>

# 指定工作目录
python run_bridge.py --workspace-cwd /path/to/project
```

#### 3. Flutter Frontend

```bash
cd flutter_prototype

# 安装依赖
flutter pub get

# 运行应用
flutter run

# 构建发行版
flutter build ios
flutter build macos
flutter build apk
```

---

## 🔧 配置说明

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

### 远程 SSH 配置

对于需要在远程服务器运行的 Provider：

```json
{
  "id": "gemini_f",
  "name": "Gemini-F",
  "command": [
    "ssh", "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=60",
    "user@remote-host",
    "zsh -ic 'gemini --acp'"
  ]
}
```

---

## 📡 安全与网络

### Smart Connect 三级连接策略

用户在 App 端可选择优先连接方式：

1. **内网直连 (mDNS)** 
   - 延迟 <5ms，数据不出局域网
   - 适用于同一网络环境

2. **云端中继 (Relay)**
   - NAT 穿透，端到端加密
   - 适用于跨网络环境

3. **云端 SaaS (Cloud)**
   - 服务始终在线
   - 兜底方案

### E2EE 端到端加密

```
┌──────────────┐                    ┌──────────────┐
│  Flutter App │                    │  Mac Bridge  │
│  生成 X25519 密钥对                  │  生成 X25519 密钥对  │
│      │                              │       │       │
│      │◄─────── ECDH 交换 ─────────►│       │       │
│      │         (公钥交换)            │       │       │
│      ▼                              ▼       │       │
│  计算共享 Session Key               计算共享 Session Key │
│      │                              │       │       │
│      │◄─────── AES-256-GCM 加密消息 ───────►│       │
│                                          (仅转发，不可解密)│
└──────────────┘                    └──────────────┘
                   云端中继 (WebSocket Relay)
```

**加密规格：**
- 密钥交换：X25519 椭圆曲线 Diffie-Hellman
- 对称加密：AES-256-GCM
- 认证：Token + 设备配对

---

## 🛠️ Tool System

系统内置丰富的工具集（基于 MCP 协议）：

### 文件操作
- `read_file` — 读取文件内容
- `write_file` — 写入文件
- `search_repo` — 代码库搜索

### 测试与执行
- `run_tests` — 运行测试套件
- `execute_code` — 执行代码片段

### 看板管理
- `create_card`, `update_card`, `delete_card`
- `move_card` — 拖拽移动卡片（支持列间迁移）
- `create_column`, `update_column`, `delete_column`
- 项目 CRUD

---

## 📊 数据库模型

### 核心表结构

```sql
-- 项目管理
projects(id, name, workspace_cwd, created_at, updated_at)

-- 列配置
columns(id, project_id, name, color, position)

-- 卡片
cards(id, column_id, title, description, status, summary, created_at)

-- 会话管理
card_sessions(id, card_id, session_id, started_at, last_activity)

-- 对话历史
card_session_messages(id, session_id, role, content, metadata)

-- 项目时间轴
project_timeline(id, project_id, event_type, card_id, payload, created_at)

-- 卡片摘要（已完成/归档）
summaries(card_id, summary, generated_at)
```

### 搜索能力

- **全文搜索 (FTS5)** — 关键字精确匹配
- **语义搜索 (sqlite-vec)** — 向量相似度检索
- **混合查询** — 结合两种方式的复合检索

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

### 插件系统（规划中）

- 🌐 浏览器插件
- 🔌 MCP Server 集成
- 💬 Slack/Teams/飞书/企业微信连接器

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

## 🧪 开发与测试

### 运行测试

```bash
# Python 单元测试
pytest tests/

# 特定模块测试
python test_permission_flow.py
python test_db_progress.py
```

### 日志查看

```bash
# 实时查看 Bridge 日志
tail -f mybot.log

# 查看特定会话日志
grep "session_id" mybot.log
```

---

## 🚧 Roadmap

### 近期目标
- [ ] AG-UI 协议深度集成（授权请求、进度反馈）
- [ ] 自动摘要优化（定时触发、质量评估）
- [ ] Git 分支联动（卡片 ↔ Branch ↔ Commit）

### 中期目标
- [ ] Agent 主动提议看板变更
- [ ] 子卡片自动拆解
- [ ] 自动化工作流引擎（规则触发 → 自动执行）

### 长期愿景
- [ ] 多项目协同（跨项目卡片引用）
- [ ] 团队共享看板
- [ ] 市场化的插件生态

---

## 🤝 贡献指南

我们欢迎社区的贡献！在提交 PR 之前，请：

1. Fork 仓库并创建功能分支
2. 遵循现有代码风格（Black + ruff）
3. 添加相应的测试用例
4. 更新文档

### 代码规范

- Python: Black + ruff
- Dart/Flutter: dart format + lint
- Markdown: 使用统一样式（见 `docs/markdown.css`）

---

## 📝 版本历史

### v0.3.0 (当前版本)
- ✅ 完整的列管理和卡片移动
- ✅ 会话级权限控制
- ✅ Timeline 事件聚合
- ✅ 多项目支持

### v0.2.0
- ✅ Smart Connect 三级策略
- ✅ E2EE 端到端加密
- ✅ Relay 中继服务

### v0.1.0
- ✅ 基础看板功能
- ✅ ACP Bridge 实现
- ✅ SQLite 持久化

---

## 👥 团队成员

- @flown - 核心架构 & 后端开发

---

## 📄 License

MIT License - see LICENSE file for details

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
