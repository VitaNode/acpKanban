## MyBot

通过一个 **Telegram Bot 桥接器**，将 Telegram 作为交互渠道，实现与后端 `gemini` 和 `qwen` 命令行工具进行推理与任务执行，并辅以三层记忆架构实现深度长期记忆。

不只是简单的消息转发，而是通过**多维记忆注入**和**原生会话管理**解决了大模型“断片”的问题，并通过 **CLI 集成** 赋予了 Bot 真实的操作系统、文件系统及 Google Workspace 操控权限。

---

### **核心架构升级**

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

### **最新进展**

#### 【2026-03-10】

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

#### 【2026-03-15】

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

### **待优化项及规划**

#### 上下文优化——2026-03-17

通过将“身份指令”和“历史记忆”从每一轮对话中移除，改为仅在会话开始时进行一次性注入，减少 Token 噪音并提高对话一致性。

**实施详情：**
- [x] **精简系统提示词**：修改 `sync_identity_files`，不再在 `GEMINI.md/QWEN.md` 中写入全量身份，仅保留最小化的 Agent 标识。
- [x] **一次性初始化**：重构 `handle_message`，检测到新会话（`/new` 或首次启动）时，一次性注入全量 `memory_summary.md` 和 `agent.md`。
- [x] **消除冗余**：后续对话中不再重复发送身份规则和历史摘要，仅发送用户当前问题，依靠 native session 维持上下文。

**验证标准：**
- [ ] `/new` 后的首条消息包含完整背景。
- [ ] 后续消息仅包含用户文本。
- [ ] 长期对话下身份不发生偏移。

上下文优化方案 - 2026-03-17                                                                
                                                                                            
此方案旨在通过将“身份指令”和“历史记忆”从每一轮对话中移除，改为仅在会话开始时进行一次性注入，从而减少 Token 噪音并提高对话的一致性。                                                  
                                                                                            
目标                                                                                       
  1. 消除冗余：停止在每一轮 prompt 中重复发送“身份指令”和“已知事实”。                       
  2. 一次性初始化：仅在新建会话（由 /new 指令触发或机器人首次启动）时，加载全量 memory_summary.md 和 agent.md 身份信息。                                               
  3. 精简系统提示词：将 GEMINI.md / QWEN.md 缩减为最小化的功能性 Header。                   
                                                                                            
关键文件与上下文                                                                           
  - gemini_telegram_bridge.py: 核心逻辑文件，负责 prompt 构建。                             
  - project_context.md: 项目进度与规划文档。                                                
  - bots/{name}/workspace/GEMINI.md: 当前每轮调用的系统提示词文件。                         
  - bots/{name}/gemini_memory/memory_summary.md: 历史事实库。                               
                                                                                            
实施步骤                                                                                   
                                                                                            
 1. 更新项目文档 (Updating project_context.md)                                              
 将此详细方案记录到 project_context.md 的最新进展或待优化项中。                             
                                                                                            
 2. 精简 GEMINI.md/QWEN.md                                                                  
 修改 GeminiBotInstance.sync_identity_files 方法。                                          
  - 改动：不再将 agent.md 的全量内容写入这些文件，仅保留最小化的 Agent 标识（例如 # Assistant Mode\nUse tools as needed.）。这样可以确保 CLI 仍然能够识别自身为 Agent，但不会在每一轮对话中产生巨大的上下文开销。                                       
                                                                                            
 3. 重构 handle_message 中的 Prompt 构建逻辑                                                
 更新 prompt 生成逻辑以支持会话初始化检测。                                                 
  - 逻辑：                                                                                  
      - 检测当前是否为新会话（判断 self.skip_session_once 是否为 True，或 current_session.id 文件是否存在）。                                                 
      - 如果是新会话：                                                                      
          - 加载全量 memory_summary.md。                                                    
          - 加载 agent.md 的内容并附加核心身份规则。                                        
          - 构建 full_prompt，包含“系统初始化 + 身份信息 + 历史摘要 + 用户当前问题”。       
          - 发送后将 self.skip_session_once 重置为 False。                                  
      - 如果不是新会话：                                                                    
          - full_prompt 仅包含“用户当前问题”。                                              
  - 移除：原有的每轮读取最后 50 行 facts_str 的逻辑。                                       
                                                                                            
 4. 验证 /new 指令的兼容性                                                                  
 确保 /new 指令能够正确重置会话状态，使得下一条消息能够触发“新会话”初始化逻辑。             
                                                                                            
验证与测试                                                                                 
  1. 会话重置测试：执行 /new 后发送消息，通过终端日志确认第一条消息包含了全量身份和摘要。   
  2. 持续对话测试：发送第二条消息，确认其 full_prompt 仅包含当前问题，不再重复冗余信息。    
  3. 身份持久性测试：确认机器人在第二轮对话中仍能记住自己的身份和核心规则（验证原生会话持久化有效）。                                                                             
  4. 日志审计：检查 bridge.log 确认 Token 占用显著下降。 




#### 将 Agent Client Protocol (ACP) 带入 Telegram 的桥接机器人

* **相关文档**
  - https://agentclientprotocol.com/get-started/introduction

* **Gemini CLI 和 Qwen Code 都支持 ACP，而且还有很多：**
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
| **Token 使用统计** | ✅ `PromptResponse.usage` | 详细的 token 分类统计 |