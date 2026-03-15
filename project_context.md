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

### **待解决与后续计划**

#### **1. 待优化项**
- **Context 水位统计准确性**：目前的统计偶尔会抓取到 latency 或累加错误，需实现专门的“最终 JSON 块”解析逻辑。
- **摘要过期清理**：`memory_summary.md` 只增不减，需定期归档或滑动窗口清理。
- **自动摘要**：`/summary` 提炼目前仍需手动指令，需改为定时或事件驱动（如凌晨自动执行）。

#### **2. 新功能规划**
- **Google Tasks 深度集成**：进一步优化通过 `gws` 读写任务列表的 Prompt，实现手机端与 Bot 的无缝任务共享。
- **数据库记忆化**：将日志存入 SQLite，支持秒级全局搜索及未来的 Web 看板展示。
- **自主视觉增强**：不仅能看截图，还能通过 `cliclick` 结合视觉反馈实现更复杂的 GUI 自动化操作。
