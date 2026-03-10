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

### **待解决与后续计划**

#### **1. 待优化项**
- ~~**Qwen 统计显示**~~：已修复，从 `type="result"` 对象中提取 usage
- **摘要质量保障**：AI 可能提炼出不准确的事实（需优化 Prompt 或引入人工确认）
- **摘要过期清理**：`memory_summary.md` 只增不减，需定期归档或滑动窗口清理
- **单进程多 Bot**：异步事件循环冲突，目前采用多窗口分别启动
- **自动摘要**：需增加 `launchd` 实现真正的定时自动归档

#### **2. 新功能规划**
- **Google Tasks 深度集成**：进一步优化通过 `gws` 读写任务列表的 Prompt，实现手机端与 Bot 的无缝任务共享。
- **自主视觉监控**：让 Bot 能够根据任务需要，自主决定何时截图观察执行结果（例如确认软件是否打开成功）。
- **智能清理**：随着日志增多，需增加一套自动清理冷数据但保留核心摘要的机制。
