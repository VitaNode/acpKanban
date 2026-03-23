## MyBot

通过一个 **Telegram Bot 桥接器**，将 Telegram 作为交互渠道，实现与后端 `gemini` 和 `qwen` 命令行工具进行推理与任务执行，并辅以三层记忆架构实现深度长期记忆。

不只是简单的消息转发，而是通过**多维记忆注入**和**原生会话管理**解决了大模型“断片”的问题，并通过 **CLI 集成** 赋予了 Bot 真实的操作系统、文件系统及 Google Workspace 操控权限。

---

## **核心架构**

#### **1. 三层记忆系统 (Tiered Memory)**
*   **第一层：原始日志 (Raw Logs)**：实时记录每一轮对话到 `bots/{name}/logs/YYYY-MM-DD.md`，用于追溯。
*   **第二层：事实摘要 (Daily Briefs)**：通过 `/summary` 指令调用 Gemini 提炼当天关键事实，沉淀至 `memory_summary.md`，作为机器人的“常识库”。
*   **第三层：向量检索 (Vector RAG)**：将对话向量化存入 `memory.json`，支持跨时空的语义搜索。

#### **2. 双引擎与多实例 (Multi-Engine & Multi-Bot)**
*   **多 Bot 隔离**：支持通过 `--name` 启动不同身份的机器人（如 `probe`, `task`），数据、日志、工作区完全物理隔离。
*   **双引擎驱动**：同时支持 Google `gemini` 和阿里 `qwen` CLI，可随时通过 `/engine` 指令在线切换。
*   **原生会话 (Native Session)**：从手动拼接历史转向利用 CLI 原生的会话管理（Gemini 的 `--resume` 和 Qwen 的 `--continue`），对话感极其自然丝滑。

#### **3. 强化感官与执行 (Vision & Tools)**
*   **真实视觉 (Dual-Pass Vision)**：实现“先截图、后分析”的闭环。Bot 执行 `screencapture` 后，自动调用 Vision 模型分析真实屏幕内容并回复。
*   **多媒体工具箱**：集成 `ffmpeg` (视频处理)、`yt-dlp` (资源下载)、`cliclick` (GUI 模拟点击)。
*   **Google 生态接入**：通过 `gws` CLI 获得 Gmail、Drive 和 Tasks 的读写权限。

#### **4. 交互与美化**
*   **渲染优化**：采用 HTML 渲染模式，解决 Telegram 不支持表格对齐的问题（通过 ```text 代码块触发横向滚动），并将标题自动转为粗体。
*   **状态透明**：控制台实时显示执行耗时，消息底部显示 `Context Left` (Gemini) 或 `Tokens Used` (Qwen)。
*   **反馈增强**：任务完成时 Mac 播放提示音 (`afplay`)，并支持静默调试日志（按天滚动）。

---

## **最新进展**

### 【2026-03-10】

**日志系统重构**
- **纯终端日志**：废弃文件日志 handler，所有 DEBUG 级别日志输出到终端，避免进程崩溃时日志丢失
- **分段计时**：增加 `⏱️ [XX.Xs] 阶段名` 日志，精确显示每个阶段的耗时（Context 构建、CLI 执行、响应解析等）
- **完整输出**：RAW STDOUT/STDERR 不再截断，便于诊断 Qwen Token 统计问题

**超时与稳定性**
- **超时延长**：CLI 超时从 120 秒延长到 180 秒，避免正常长任务被误杀
- **异常日志**：NetworkError 显示为 warning，catastrophic error 打印完整堆栈

**Qwen Token 统计修复**
- **问题根源**：Qwen 输出数组中有多个 `usage` 字段，原递归算法返回第一个（空的）而非最后一个（完整的）
- **解决方案**：优先从 `type="result"` 对象中提取 usage 和 response，确保拿到最终统计数据
- **效果**：Telegram 现在正确显示 `Tokens Used: XXXk`（如 276.2k）

**多 Bot 默认引擎配置**
- **probe 默认 qwen**，**task 默认 gemini**
- 通过 `DEFAULT_ENGINES` 字典配置，支持运行时 `/engine` 切换

**开发规范**
- **编辑最佳实践**：使用 `grep_search` 定位行号 → `read_file` 确认内容 → 再执行 `edit`
- **提交流程**：每次修改后必须语法检查 → 测试 → commit → 确认

---

### 【2026-03-15】

**鲁棒性与消息可靠性**
- **智能分段发送**：长消息自动按 4000 字符切分，并自动补全/重启 HTML 标签（b, i, pre, code），解决截断问题。
- **离线信箱 (Outbox)**：实现磁盘级补发机制。当网络断开导致回复发送失败时，自动保存至 `outbox/` 并在网络恢复后补发，补发消息包含原始问题 context。
- **超时上限提升**：将 CLI 超时上限提升至 600 秒（10 分钟），支持复杂长链任务。
- **自动化每日记忆**：脚本每一轮对话结束后自动同步至 `workspace/memory/YYYY-MM-DD.md`，实现 AI 视角的历史记录自动化。

**系统级优化**
- **日志轮转**：全面启用 `TimedRotatingFileHandler`，主日志与 Bot 专属日志均实现按天自动归档。
- **身份固化**：实现 `agent.md` 动态同步至 `GEMINI.md/QWEN.md`，净化 Prompt 注入，增强模型身份原生感。
- **会话锁定**：实现 UUID 级会话持久化锁定（`current_session.id`），彻底解决 Qwen 会话碎片化问题。

---

### 上下文优化——2026-03-17

通过将“身份指令”和“历史记忆”从每一轮对话中移除，改为仅在会话开始时进行一次性注入，减少 Token 噪音并提高对话一致性。

**实施详情：**
- [x] **精简系统提示词**：修改 `sync_identity_files`，不再在 `GEMINI.md/QWEN.md` 中写入全量身份，仅保留最小化的 Agent 标识。
- [x] **一次性初始化**：重构 `handle_message`，检测到新会话（`/new` 或首次启动）时，一次性注入全量 `memory_summary.md` 和 `agent.md`。
- [x] **消除冗余**：后续对话中不再重复发送身份规则和历史摘要，仅发送用户当前问题，依靠 native session 维持上下文。

**验证标准：**
- [ ] `/new` 后的首条消息包含完整背景。
- [ ] 后续消息仅包含用户文本。
- [ ] 长期对话下身份不发生偏移。



### 接入 Agent Client Protocol (ACP) —— 2026-03-20

#### ACP介绍

* **相关文档**
  - https://agentclientprotocol.com/get-started/introduction

* **ACP 协议原生支持的功能**

| 功能 | ACP 协议支持 | 说明 |
|------|------------|------|
| **会话创建** | ✅ `session/new` | 创建新会话 |
| **会话恢复** | ✅ `session/load` | 加载历史会话 |
| **消息发送** | ✅ `session/prompt` | 发送用户消息 |
| **流式响应** | ✅ `agent_message_chunk` | 实时 token 输出 |
| **工具调用** | ✅ `tool_call` | 标准化工具调用格式 |
| **权限审批** | ✅ `session/request_permission` | 请求用户批准 |
| **会话取消** | ✅ `session/cancel` | 中止当前操作 |
| **模式切换** | ✅ `session/set_mode` | 切换 agent 模式 |
| **上下文窗口状态** | ✅ `session/update` | agent 主动推送使用情况 |

#### 实施方案

将机器人架构从“单次 CLI 调用”升级为“基于 ACP 协议的长连接模型”，以支持流式输出、标准化工具调用和更好的会话管理。

* **实施详情：**
- [x] **协议层建设**：实现了一个 Python ACP Client (`acp_client.py`)，成功对接 `gemini --acp`，支持 JSON-RPC 通信、会话创建和流式消息解析。
- [x] **会话管理升级**：利用 ACP 原生的 `session/new` 和 `session/load` 替代了旧的命令行会话维护模式，实现了持久化进程。
- [x] **UI 与交互优化**：实现了 Telegram 上的流式打字机效果，大幅提升了交互反馈速度。
- [~] **交互审批与工具调用**：待进一步对接 `session/request_permission` 以实现内联按钮确认。
   1. 权限拦截机制已验证成功：我们的 Inline Button -> Callback -> Future -> ACP Respond
      这一整条链路在逻辑上已经通了。
   2. 文件创建失败 是因为 gemini CLI 内部的一个 Bug，在处理 default 审批回调时会崩溃。
   3. 后续计划：您可以先在 yolo 模式下进行开发。等我们未来通过 GitHub 发起 Issue
      并在官方修复该 Bug 后，再切回 default 模式。

* **验证标准：**
- [x] 机器人启动后，CLI 进程保持常驻而非每轮重启。
- [x] Telegram 消息支持流式实时更新。
- [x] 工具调用触发 Telegram 按钮交互审批。
- [x] 能够通过 ACP 协议成功加载历史会话。

---

### 【2026-03-20】**Kanban 项目启动：长时任务管理的自动化闭环**

* **项目定调**
- **核心目标**：解决长周期（2-3个月）APP 开发等任务中的“手动记录成本高”和“上下文连续性断裂”问题。
- **产品形态**：移动端看板 + 自动化时间轴，彻底取消手动复制粘贴，实现“策划即执行，执行即记录”。
- **技术底座**：全面拥抱 **Agent Client Protocol (ACP)**，作为看板 App 与执行 Agent 之间的通讯标准。

* **核心优化方案**
1. **自动任务同步 (Zero-Copy Sync)**
   - AI 在策划阶段生成的拆解任务直接写入后端 PostgreSQL，自动生成看板卡片。
   - 卡片内部包含“执行上下文 ID”，AI 执行时自动关联该 ID 提取所有历史背景。
2. **动态时间轴 (Auto-Timeline)**
   - 记录每一轮执行的决策点，特别是“由于技术障碍导致的方案变更”。
   - 时间轴作为 RAG 的高权重索引，当 AI 重新回到某个卡片时，优先加载该卡片在时间轴上的“心路历程”。
3. **结果导向的极简交互**
   - 针对非技术用户，隐藏中间执行过程（不设确认框），仅在看板展示状态（待办 -> 进行中 -> 已完成）。
   - 利用 ACP 的通知机制实现“任务节点达成”的主动推送。

* **实施路径 (Roadmap)**
- **Phase 1: ACP Server 搭建**
  - 基于 `gemini--experimental-acp` 实现后端服务。
  - 通过 Cloudflare Tunnel 建立手机端与本地执行环境的安全隧道。
- **Phase 2: 看板 & 时间轴存储**
  - 弃用文件式 Raw Logs，全面转向 PostgreSQL。
  - 实现“变更追踪”逻辑：当需求变化时，AI 自动在数据库中建立版本分支。
- **Phase 3: 移动端 App 开发 (The Kanban Face)**
  - 使用 Flutter 构建。
  - 集成 ACP Client 协议，实现看板卡片与 AI 会话的深度绑定。

* **技术挑战与对策**
- **连接稳定性**：移动端弱网下，通过 `Outbox` 机制和 ACP 的会话恢复功能确保指令不丢失。
- **长时记忆管理**：不再依赖全量对话缓存，而是依赖看板任务状态 + 时间轴摘要作为"极简上下文"。

---

### 【2026-03-21】**架构方案更新：自建中继服务器**

* **路径规划（3 条路径）**

| 路径 | 渠道 | 本地/云端 | ACP Server | 状态 |
|------|------|-----------|------------|------|
| **路径 1** | Telegram | 本地 | `gemini --acp` | ✅ 已实现 |
| **路径 2** | 手机 App | 本地 + 中继 | `gemini --acp` | 📅 开发中 |
| **路径 3** | 手机 App | 云端 | `acp_server.py` | ✅ 原型完成 |

---

#### **路径 1: Telegram → 本地 ACP Client → Gemini --acp** ✅

**架构**：
```
Telegram Bot (Python)
       │
       │ stdio (JSON-RPC)
       ▼
gemini --acp (本地进程)
       │
       ▼
Gemini API (via MCP)
```

**特点**：
- ✅ 已实现，通过 `gemini_telegram_bridge.py`
- ✅ 利用 Gemini CLI 的 MCP 生态，支持本地工具调用
- ⚠️ 依赖本地安装 Gemini CLI
- ⚠️ 无法直接部署到云端

**使用场景**：
- 个人日常快速任务管理
- 本地开发和测试
- 语音输入任务（Telegram 语音转文字）

---

#### **路径 2: 手机 App → 云端中继 → 本地 ACP Client → Gemini --acp** 📅

**架构**：
```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│  手机 App     │      │  云端中继     │      │  你的 Mac     │
│  Flutter     │─────>│  (WebSocket) │<────│ acp_bridge   │
│              │      │  公网 IP      │      │ gemini--acp  │
└──────────────┘      └──────────────┘      └──────────────┘
   连接 relay.example.com           主动连接云端
```

**核心思路**：
- ✅ Mac **主动连接**云端中继（无需外网 IP）
- ✅ 手机也连接**同一个云端中继**
- ✅ 中继服务器**双向转发**消息
- ✅ 用户**零配置**（只需登录账号）

**组件**：
| 组件 | 说明 | 状态 |
|------|------|------|
| `relay_server/server.py` | 云端 WebSocket 中继 | 📅 待开发 |
| `acp_bridge_relay.py` | Mac 端桥接器（连接云端） | 📅 待开发 |
| Flutter App | 登录账号 绑定手机端和Mac端 | ⚠️ 需修改 |

**工作流程**：
```
1. Mac 启动 acp_bridge_relay.py → 连接云端中继
         ↓
2. Mac 输入账号密码
         ↓
3. 手机 App 输入账号密码 → 连接云端
         ↓
4. 云端将手机和 Mac 的连接绑定
         ↓
5. 双向转发消息（手机 ↔ Mac）
```

**优化**：
- 做成系统进程，支持开机自起
- 支持自定义连接地址：内网地址，或者自行配置的 “ngrok/cloudflare tunnel” 地址

A. 安全加固：引入端到端加密 (E2EE) 🔒
  由于路径 2 被定位为“专业版/收费版”，安全性是第一优先级。
   * 建议：中继服务器仅负责“盲转发”加密后的原始数据包。
   * 实施：Mac 端和手机端在握手阶段通过 Diffie-Hellman
     等算法交换会话密钥。中继服务器只看到加密后的 JSON-RPC 流量，无法解析具体的指令内容。

  B. 配对机制优化：从“账号密码”到“设备配对” 🔗
   * 现状：用户在两端输入账号密码。
   * 优化：参考 Telegram 或 Discord 的登录方式。
       * Mac 端生成一个临时的 6 位配对码或 QR Code。
       * 手机端扫码/输入，中继服务器根据配对码完成两端 ID 的绑定。
       * 好处：减少用户输入负担，且避免在不信任的终端（如公用电脑）上输入主账号密码。

  C. 状态自愈：ACP 会话持久化 🔄
   * 痛点：如果 acp_bridge_relay.py 因为网络断开重连，本地的 gemini --acp 进程是否会重启？
   * 优化：
       * acp_bridge_relay.py 应该作为一个 Session Manager。
       * 即使 WebSocket 断开，本地的 gemini --acp 进程也保持运行。
       * 手机重连后，Bridge 通过 session/load 或 ACP
         内置的恢复机制，将之前的上下文无缝推回手机端。

  D. 流量优化：多通道转发 📡
   * 建议：支持“内网优先”发现。
   * 实施：在 App 中集成 mDNS (Bonjour)。如果手机和 Mac 在同一个 WiFi 下，App
     优先尝试直接连接 Mac 的局域网 IP（路径 1 的变体）；只有在非同网环境下，才切换到路径 2
     的云端中继。这能极大地降低延迟。

  E. 交互审批的移动端适配 📱
   * 建议：充分利用移动端推送通知。
   * 场景：当 Mac 端执行危险操作（如 rm -rf）触发 ACP 的 session/request_permission
     时，手机端不仅要在 App 内弹窗，还应发送系统级 Push
     Notification。用户点击通知即可直接审批。

  F. 组件层面细化建议
   * Relay Server (server.py):
       * 建议使用 FastAPI + WebSockets 库，或者专用的高性能转发引擎如 Nginx NJS。
       * 增加 Ping/Pong 心跳包 检测，设置合理的超时剔除机制。
   * Local Bridge (acp_bridge_relay.py):
       * 建议增加一个 "Privacy Mode" 开关。当开启时，禁止通过 ACP
         调用截图或读取特定敏感目录。

---

#### **路径 3: 手机 App → 云端 ACP Server → LLM API** ✅

**架构**：
```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│  手机 App     │      │  云端 ACP     │      │  LLM API     │
│  Flutter     │─────>│  acp_server  │─────>│ Gemini/Qwen  │
│              │      │  + Database  │      │              │
└──────────────┘      └──────────────┘      └──────────────┘
```

**组件**：
| 组件 | 说明 | 状态 |
|------|------|------|
| `acp_server.py` | ACP 服务端，调用 LLM API | ✅ 已完成 |
| `database.py` | SQLite 任务存储 | ✅ 已完成 |
| `acp_bridge_ws.py` | WebSocket 桥接器 | ✅ 已完成 |
| Flutter App | 看板 UI + 聊天 | ✅ 原型完成 |

**部署配置**：
```bash
# Docker 部署
docker run -p 8765:8765 \
  -e KANBAN_API_KEY=xxx \
  -e KANBAN_BASE_URL=https://api.redbox.ai/v1 \
  -e KANBAN_MODEL_ID=gemini-2.0-flash \
  kanban-server:latest
```

**优点**：
- ✅ 完整的生产就绪架构
- ✅ 无需本地依赖（Gemini CLI）
- ✅ 可直接商业化部署
- ✅ 支持多租户

**使用场景**：
- 商业化 SaaS 服务
- 多用户协作看板
- 长期任务管理

**优化**：
- 增加 Slack/Teams/飞书/企业微信/钉钉 插件

---

**架构对比**

| 维度 | 路径 1 (Telegram) | 路径 2 (中继) | 路径 4 (云端) |
|------|------------------|---------------|---------------|
| **延迟** | 低（本地 stdio） | 中（云端中转） | 低（直接 API） |
| **配置复杂度** | ⭐ 简单 | ⭐⭐ 中等 | ⭐⭐⭐ 较复杂 |
| **适用场景** | 个人日常 | 家庭/小团队 | 商业化 SaaS |

---

### 【2026-03-21】**商业化路径与架构优化方案**

* **商业化路径规划**

| 路径 | 渠道 | 部署方式 | 商业定位 | 核心价值 |
|------|------|-----------|----------|----------|
| **路径 1** | Telegram | 本地 | **开源免费** | 隐私优先，数据不出本地，吸引开发者生态。 |
| **路径 2** | 手机 App | 本地 + 中继 | **专业版/收费** | 移动端远程操控本地 Mac，适合高级技术用户。 |
| **路径 3** | 手机 App | 云端 SaaS | **商业化主力** | 零配置，云端长时记忆，团队协作看板。 |

* **核心技术优化策略**

1. **“卡片即上下文” (Card-as-Context)**
   - 在 ACP 协议中，利用 `session/load` 结合看板卡片 ID。
   - 用户点击卡片时，自动注入该卡片的任务状态与依赖，实现精准的局部上下文加载。

2. **自动化时间轴 RAG 化**
   - 将时间轴上的决策点（心路历程）进行向量索引。
   - 当任务报错时，AI 可自动回溯早期的技术决策，寻找潜在原因。

3. **安全加固 (针对路径 2)**
   - 实现 **端到端加密 (E2EE)**。中继服务器仅转发加密流，不具备解密权限，确保操控本地 Mac 时的绝对安全。

4. **统一 ACP 抽象层**
   - 编写通用的 `ACPLayer`，屏蔽 `stdio`、`WebSocket` 与 `Rest API` 的传输差异，使 App 逻辑与通讯协议解耦。

5. **MCP 插件转发站**
   - 本地桥接器作为 MCP 工具站，允许云端 Agent 远程调用用户本地的私有工具（如本地数据库、私有 API）。

---

#### 实施路线图 (更新)

* **Phase 2: 中继服务器与安全 (进行中 📅)**
- [ ] `session/request_permission` 拦截逻辑实现 (Telegram 端)
- [ ] 统一 ACP 抽象层封装
- [ ] 端到端加密方案设计

* **Phase 3: 云端部署与多租户 (待启动 📋)**
- [ ] Docker 镜像构建
- [ ] PostgreSQL 多租户 Schema 设计
- [ ] 监控与计费模块

---

### 【2026-03-21】**开源易用性优化方案**

* [ ] **Bots配置**
  - 支持多Bots，每个Bot单独配置以下参数：
    - Bot_token
    - 个人ID（暂时只支持私聊）
    - 默认Bot
    - agent.md
      - 需要提供模板
      - 去掉当前自动生成的 GEMINI.md 和 QWEN.md

* [ ] **Embedding配置**
  - BaseURL
  - Model_ID
  - key

* [ ] **支持ACP切换**（如果不配置模型ID会怎么样？）
  - AgentPool
  - Augment Code
  - Blackbox AI
  - Claude Code（通过 Zed 适配器）
  - Codex CLI（通过 Zed 适配器）
  - Code Assistant
  - Docker's cagent
  - fast-agent
  - Gemini CLI
  - Goose
  - JetBrains Junie（即将推出）
  - Kimi CLI
  - Minion Code
  - Mistral Vibe
  - OpenCode
  - OpenHands
  - Pi（通过 pi-acp 适配器）
  - Qoder CLI
  - Qwen Code
  - Stakpak
  - VT Code

* [ ] **记忆系统优化**
  - 引入**定期摘要**（每日把旧对话压缩成摘要）
  - `/summary` 改成**增量提炼**（读取旧摘要 + 新日志 → 生成新摘要）（不再限制300条）
  - 不再使用云端模型（否则要增加配置）

* [ ] **安全清理（敏感信息排查）**
  - `.env` 确保在 `.gitignore`
  - `bots/*/` 目录（包含日志、记忆、凭证）全部忽略
  - `logs/`、`venv/`、`__pycache__/` 忽略
  - 检查代码里有没有硬编码的 API Key、User ID
  - kanban.db、project_context.md、flutter_prototype

* [ ] **代码整理**
  - 统一注释风格（中文/英文选一个）
  - 移除调试代码（`print()`、临时注释）
  - 提取配置常量到单独文件
  - 增加类型注解（Python 3.10+）
  - 添加单元测试（至少覆盖核心逻辑）

* [ ] **依赖管理：**
  - `requirements.txt` 或 `pyproject.toml`
  - 标注 Python 版本要求
  - CLI 工具依赖说明（gemini、qwen、gws 的安装方式）

* [ ] **ACP 模式的可能性**：
  - ACP 协议支持**跨代理上下文同步**
  - 可以配置**共享 RAG 向量库**（`memory.json`）
  - 或者通过**事实摘要层**（`memory_summary.md`）同步知识

* [ ] **安全配置**
  - 单实例锁
    - 同一 bot_token 只能运行一个实例
  - 工作目录
    - bot_token 绑定工作目录
    - 不支持配置，强制在程序目录下自动生成（保证沙箱安全）
  - 增加验证配置文件
  - 文件写入锁 + 重试机制，并发写入时不丢失数据

---

### 【2026-03-22】路径 2 细化实施方案：统一中继与三级降级策略

为了平衡“低延迟”与“高可用性”，路径 2 的实施将采用**三级自适应连接策略**。

#### **1. 三级自适应逻辑 (Smart Connect)**
Flutter App 启动后将按以下顺序尝试连接：
1.  **内网直连 (Local Path)**：通过 mDNS 发现本地 Mac 的局域网 IP，直接建立 WebSocket 连接。延迟最小（<5ms），数据不经过云端。
2.  **云端中继 (Relay Path)**：内网不可达时，连接云端 `relay_server.py`。Mac 端桥接器主动向云端建立长连接实现 NAT 穿透。
3.  **云端 SaaS (Cloud Path)**：若本地 Mac 未启动，自动回退到云端部署的 `acp_server.py`，保证服务始终在线。

#### **2. 统一中继服务器 (`relay_server.py`)**
作为云端交换机，通过路径区分流量：
- `/relay/app/{user_id}`: 手机端接入点。
- `/relay/mac/{user_id}`: Mac 端接入点。
- `/direct`: 兼容路径 3 的直接模式。

#### **3. Mac 端双向桥接器 (`acp_bridge_relay.py`)**
在本地 Mac 运行，同时维持两个任务：
- **监听模式**：作为 Server 接受手机的内网直连。
- **主动模式**：作为 Client 连接云端中继。
- **共享执行**：两个通道共享同一个 `gemini --acp` 进程。

#### **4. 安全方案**
- **握手协议**：手机与 Mac 在首次配对时交换 AES 密钥。
- 端到端加密 (E2EE)：在路径 2 中，指令载荷由 App 加密，Mac 桥接器解密。中继服务器仅透传密文，确保云端不可视。

---

### 【2026-03-23】架构深度加固与安全闭环

针对原型中的关键漏洞进行了深度修复，实现了工业级的连接与安全标准。

#### **1. P0 级：安全与隐私闭环**
- **ECDH 密钥交换**：引入 **X25519** 椭圆曲线协议。实现了 `pairing/exchange` 握手，使 App 与 Mac 能够动态协商 Session Key，彻底告别硬编码密钥。
- **AES-256-GCM**：在 Python 和 Dart 两端同步实现了带关联数据的加密逻辑，确保消息的完整性与私密性。
- **握手拦截鉴权**：`relay_server.py` 升级为握手期 Token 校验，非法连接在建立前即被拒绝。

#### **2. P0 级：Smart Connect 完整实现**
- **扫描与发现**：Flutter 端 `SmartConnect` 类集成了 `multicast_dns` 扫描逻辑，能够自动锁定局域网内的 Mac IP。
- **连接编排器**：实现了三级降级自动化逻辑（Local mDNS -> Relay E2EE -> Cloud Direct），App 会自动寻找最优路径。

#### **3. 工程化与鲁棒性 (P1-P3)**
- **数据库连接池**：`database.py` 完整实现了基于 `Queue` 的连接池，并开启 WAL 模式以支持高并发。
- **广播回环修复**：重构 `acp_bridge_relay.py`，物理分离了本地客户端与云端中继的连接池，确保 ACP 输出的精准分发。
- **异常容错**：为 mDNS 资源释放、E2EE 解包、中继消息转发等关键路径增加了健壮的异常捕获与超时机制。

#### 云端部署

- SSH 连接： 35.211.219.123 （已经设置好了证书登录）
- 其他服务已占用端口：
  - 8000：https://api.siliconpulse.cc 
- 已安装环境：
  - Python 3.10 + FastAPI + Uvicorn + NumPy

