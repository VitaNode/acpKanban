"""
一次性清理脚本：将数据库中所有 is_complete=0 的历史消息标记为 is_complete=1。

这些消息是之前 AI 流式响应中断后残留的未完成消息。
由于它们实际上已经不会再被更新，应该视为已完成。

用法：
    python fix_stale_sessions.py
"""

import sqlite3
import sys
import os

DB_PATH = os.path.join(os.path.dirname(__file__), "kanban.db")


def main():
    if not os.path.exists(DB_PATH):
        print(f"数据库文件不存在: {DB_PATH}")
        return

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    # 查询当前有多少条未完成的消息
    cursor.execute("SELECT COUNT(*) FROM card_sessions WHERE is_complete = 0")
    count = cursor.fetchone()[0]
    print(f"找到 {count} 条 is_complete=0 的历史消息")

    if count == 0:
        print("无需清理，退出。")
        conn.close()
        return

    # 确认清理
    print("将把这些消息标记为 is_complete=1...")

    # 执行更新
    cursor.execute("UPDATE card_sessions SET is_complete = 1 WHERE is_complete = 0")
    updated = cursor.rowcount
    conn.commit()

    print(f"已更新 {updated} 条消息")
    conn.close()


if __name__ == "__main__":
    main()
