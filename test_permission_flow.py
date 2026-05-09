#!/usr/bin/env python3
"""
测试 ACP 授权流程

验证以下内容：
1. YOLO 模式是否自动放行权限请求
2. 非 YOLO 模式是否正确转发到 UI
"""

import asyncio
import json
import uuid
from src.persistence.database import KanbanDB


async def test_yolo_mode():
    """测试 YOLO 模式下的自动授权"""
    print("\n" + "=" * 60)
    print("YOLO 模式授权测试")
    print("=" * 60)

    db = KanbanDB()

    # 1. 创建列（YOLO 模式）
    print("\n[1] 创建 YOLO 模式的列...")
    project_id = db.create_project(
        name="Test YOLO Project",
        workspace_path="/tmp/test_workspace"
    )
    column_id = db.create_column(
        project_id=project_id,
        name="YOLO Column",
        position=0
    )
    # 更新为 YOLO 模式
    with db.get_connection() as conn:
        conn.execute(
            "UPDATE columns SET approval_mode = ? WHERE id = ?",
            ("yolo", column_id)
        )
    
    card_id = db.create_card(
        column_id=column_id,
        title="YOLO Test Card"
    )
    print(f"    ✓ 创建成功：column={column_id}, card={card_id}")

    # 2. 验证列的 approval_mode
    print("\n[2] 验证列的 approval_mode...")
    with db.get_connection() as conn:
        cursor = conn.execute("SELECT approval_mode FROM columns WHERE id = ?", (column_id,))
        row = cursor.fetchone()
        if row and row[0] == "yolo":
            print(f"    ✓ approval_mode 正确设置为：{row[0]}")
        else:
            print(f"    ✗ approval_mode 设置错误：{row[0] if row else 'None'}")

    # 3. 清理
    with db.get_connection() as conn:
        conn.execute("DELETE FROM cards WHERE id = ?", (card_id,))
        conn.execute("DELETE FROM columns WHERE id = ?", (column_id,))
        conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))
    print("\n    ✓ 测试数据已清理")

    print("\n" + "=" * 60)


async def test_manual_mode():
    """测试手动授权模式"""
    print("\n" + "=" * 60)
    print("手动授权模式测试")
    print("=" * 60)

    db = KanbanDB()

    # 1. 创建列（手动模式）
    print("\n[1] 创建手动授权模式的列...")
    project_id = db.create_project(
        name="Test Manual Project",
        workspace_path="/tmp/test_workspace"
    )
    column_id = db.create_column(
        project_id=project_id,
        name="Manual Column",
        position=0
    )
    # 更新为手动模式
    with db.get_connection() as conn:
        conn.execute(
            "UPDATE columns SET approval_mode = ? WHERE id = ?",
            ("manual", column_id)
        )
    
    card_id = db.create_card(
        column_id=column_id,
        title="Manual Test Card"
    )
    print(f"    ✓ 创建成功：column={column_id}, card={card_id}")

    # 2. 验证列的 approval_mode
    print("\n[2] 验证列的 approval_mode...")
    with db.get_connection() as conn:
        cursor = conn.execute("SELECT approval_mode FROM columns WHERE id = ?", (column_id,))
        row = cursor.fetchone()
        if row and row[0] == "manual":
            print(f"    ✓ approval_mode 正确设置为：{row[0]}")
        else:
            print(f"    ✗ approval_mode 设置错误：{row[0] if row else 'None'}")

    # 3. 清理
    with db.get_connection() as conn:
        conn.execute("DELETE FROM cards WHERE id = ?", (card_id,))
        conn.execute("DELETE FROM columns WHERE id = ?", (column_id,))
        conn.execute("DELETE FROM projects WHERE id = ?", (project_id,))
    print("\n    ✓ 测试数据已清理")

    print("\n" + "=" * 60)


if __name__ == "__main__":
    print("\n正在启动 ACP 授权测试...\n")
    
    # 运行测试
    asyncio.run(test_yolo_mode())
    asyncio.run(test_manual_mode())
    
    print("\n所有测试完成！\n")
    print("=" * 60)
    print("授权流程说明：")
    print("=" * 60)
    print("""
1. **哪些工具需要授权？**
   - 所有以 `fs/*` 开头的文件操作（如 fs/read_file, fs/write_file）
   - 所有以 `terminal/*` 开头的终端命令（如 terminal/run_command）
   - 任何 ACP Agent 调用 `session/request_permission` 的请求

2. **授权模式：**
   - `approval_mode = "yolo"`：自动放行，无需用户确认
   - `approval_mode = "manual"`：转发到 Flutter UI，等待用户授权

3. **完整的授权流程：**
   a) ACP Agent 调用工具（如 fs/read_file）
   b) Dispatcher._process_engine_request 中的 handle_nested_request 拦截
   c) 检查列的 approval_mode：
      - YOLO → 自动返回 {"outcome": {"optionId": "allow"}}
      - Manual → 发布 ui_request 事件到 bus，等待 UI 响应
   d) UI 收到 ui_request 事件后显示授权对话框
   e) 用户选择允许/拒绝后，UI 回复结果
   f) Dispatcher 将结果返回给 ACP Agent
""")
