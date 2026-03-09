## MyBot

通过一个 **Telegram Bot 桥接器**，将 Telegram 作为 交互渠道，实现与后端 `gemini` 命令行工具进行推理与任务执行，并辅以本地向量数据库实现“长短期记忆”。

不只是简单的消息转发，而是通过**上下文注入**解决了大模型“断片”的问题，并通过 **CLI 集成** 赋予了 Bot 真实的文件系统操作权限。对于用户来说，这就是一个部署在服务器上、能记事、能干活的远程助手。

### **代码核心架构**

#### **1. 核心组件：`VectorMemory` (向量记忆系统)**
这是脚本中最复杂的自定义部分，实现了轻量级的 RAG（检索增强生成）：
*   **向量化**：使用 `google-generativeai` 的 `models/embedding-001` 将对话存入 `gemini_memory/memory.json`。
*   **语义检索 (`search`)**：通过计算余弦相似度，从历史记忆中提取最相关的 3 条上下文。
*   **持久化**：每次对话结束后，都会自动更新 JSON 文件，确保机器人重启后依然记得之前的交流。

#### **2. 任务处理流程：`handle_message`**
当“老兵”发送消息时，脚本执行以下逻辑：
1.  **身份校验**：仅响应 `ALLOWED_USER_ID` 定义的用户。
2.  **上下文准备**：
    *   调用 `VectorMemory.search` 获取相关历史。
    *   构建增强 Prompt，包含 `[Relevant History/Context]` 块。
3.  **CLI 调用**：
    *   执行命令：`gemini --approval-mode yolo --output-format json "<prompt>"`。
    *   **YOLO 模式**：允许 Gemini 直接执行代码或修改文件，无需人工二次确认。
4.  **结果解析**：
    *   解析 CLI 返回的 JSON，提取 `response`。
    *   如果 Gemini 执行了代码或工具，结果会一并回传给用户。
5.  **记忆存储**：将本次“问题+回答”存入向量库。

#### **3. 关键指令与交互设计**
*   **`/start`**：显示欢迎信息，确认机器人在线。
*   **`/search <query>`**：允许用户手动触发语义搜索，查看记忆库内容。
*   **打字状态模拟**：使用 `send_chat_action(ChatAction.TYPING)` 提供实时反馈。
*   **错误处理**：对 API 超时、CLI 错误及 Telegram 4096 字符限制做了截断和异常捕获。

---

### **进度**

#### 【2026-03-09】
- 已实现
  - 交互
  - 指令执行
  - 反馈
  - 日志
  - 长期记忆
- 未实现
  - 多个Bot，用不同的bottoken来区分
  - 手机版的project_context，采用Google Tasks，通过MCP来共享给Bot
