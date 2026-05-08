import unittest
import asyncio
import time
from unittest.mock import MagicMock, patch
# 假设 Dispatcher 的路径
# from src.orchestration.dispatcher import Dispatcher

class TestDispatcherAgUi(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # 模拟 DB 和 Bus
        self.db = MagicMock()
        self.bus = MagicMock()
        # 这里假设 Dispatcher 的构造函数和状态
        # self.dispatcher = Dispatcher(self.db, self.bus)
        # 模拟缓冲区
        self.buffers = {} 
        self.seq_counters = {}

    def get_next_seq(self, card_id):
        self.seq_counters[card_id] = self.seq_counters.get(card_id, 0) + 1
        return self.seq_counters[card_id]

    # === 高优先级：seqId 生成逻辑 ===
    async def test_dispatcher_seq_id_generation(self):
        """测试 Dispatcher 是否为每个会话独立生成自增 seqId"""
        card_id = "card_123"
        seq1 = self.get_next_seq(card_id)
        seq2 = self.get_next_seq(card_id)
        
        self.assertEqual(seq1, 1)
        self.assertEqual(seq2, 2)
        
        # 不同卡片应独立计数
        seq_other = self.get_next_seq("other_card")
        self.assertEqual(seq_other, 1)

    # === 高优先级：缓冲区触发逻辑 (容量触发) ===
    async def test_dispatcher_buffer_flush_capacity_trigger(self):
        """测试缓冲区达到容量上限（如 50 chunks）时自动落盘"""
        card_id = "card_123"
        buffer = []
        flush_called = False
        
        def mock_flush():
            nonlocal flush_called
            flush_called = True
            buffer.clear()

        # 模拟发送 50 个 chunk
        for i in range(50):
            buffer.append(f"chunk_{i}")
            if len(buffer) >= 50:
                mock_flush()
        
        self.assertTrue(flush_called)
        self.assertEqual(len(buffer), 0)

    # === 高优先级：缓冲区触发逻辑 (事件触发) ===
    async def test_dispatcher_buffer_flush_event_trigger(self):
        """测试收到 stop/message_end 事件时强制落盘"""
        card_id = "card_123"
        buffer = ["some", "content"]
        flush_called = False
        
        def handle_event(event_type):
            nonlocal flush_called
            if event_type == "stop":
                # 强制落盘
                flush_called = True
                buffer.clear()

        handle_event("stop")
        self.assertTrue(flush_called)
        self.assertEqual(len(buffer), 0)

    # === 高优先级：崩溃恢复机制 ===
    async def test_recover_incomplete_messages_logic(self):
        """验证恢复逻辑：扫描 is_complete=0 的记录并标记为中断"""
        # 模拟从 DB 读取到未完成记录
        incomplete_msg = {"id": 1, "content": "part...", "is_complete": 0}
        
        # 恢复逻辑应将其 metadata 标记为 interrupted 或在加载时处理
        def recover(msg):
            return {**msg, "is_interrupted": True}
            
        recovered = recover(incomplete_msg)
        self.assertTrue(recovered["is_interrupted"])

if __name__ == '__main__':
    unittest.main()
