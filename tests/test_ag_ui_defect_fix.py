import unittest
import asyncio
import json
import os
from unittest.mock import MagicMock, patch
from src.persistence.database import KanbanDB
from src.orchestration.dispatcher import MessageDispatcher
from src.transport.bus import bus

class TestAgUiDefectFix(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # Use an in-memory SQLite database for testing
        self.db_path = ":memory:"
        self.db = KanbanDB(self.db_path)
        self.db.init_db()
        self.dispatcher = MessageDispatcher(self.db)

    async def test_recover_incomplete_messages_fix(self):
        """Verify that recover_incomplete_messages works correctly and uses existing DB methods."""
        card_id = "test_card_1"
        
        # 1. Insert an incomplete message manually
        with self.db.get_connection() as conn:
            conn.execute(
                "INSERT INTO card_sessions (card_id, role, content, is_complete, created_at) VALUES (?, ?, ?, ?, ?)",
                (card_id, "assistant", "Incomplete content", 0, "2026-05-09T12:00:00")
            )
        
        # 2. Call the recovery method
        await self.dispatcher.recover_incomplete_messages(card_id)
        
        # 3. Verify it's now marked as complete and has interrupted metadata
        with self.db.get_connection() as conn:
            cursor = conn.execute("SELECT is_complete, metadata FROM card_sessions WHERE card_id = ?", (card_id,))
            row = cursor.fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row[0], 1)
            metadata = json.loads(row[1]) if row[1] else {}
            self.assertTrue(metadata.get("is_interrupted"))

    async def test_seq_id_concurrency_fix(self):
        """Verify that _get_next_seq is atomic/thread-safe (simulated by concurrent tasks)."""
        card_id = "concurrent_card"
        
        # Spawn many concurrent requests for seq IDs
        num_requests = 100
        tasks = [self.dispatcher._get_next_seq(card_id) for _ in range(num_requests)]
        
        results = await asyncio.gather(*tasks)
        
        # Verify all results are unique and sequential (1 to 100)
        self.assertEqual(len(results), num_requests)
        self.assertEqual(set(results), set(range(1, num_requests + 1)))
    
    @patch('src.transport.bus.bus.publish')
    async def test_ag_ui_realtime_push_and_seq_id(self, mock_publish):
        """Verify AG-UI events are published in real-time with seqId."""
        card_id = "test_card_realtime"
        self.dispatcher.set_ui_format(card_id, "ag_ui")
        
        # Simulated notification chunk
        notification = {
            "method": "session/update",
            "params": {
                "sessionId": "session_123",
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"text": "Hello world"}
                }
            }
        }
        
        # Process notification
        on_output = MagicMock()
        await self.dispatcher._forward_notification(card_id, notification, on_output, ui_format="ag_ui")
        
        # Verify bus.publish was called
        mock_publish.assert_called()
        args = mock_publish.call_args[0]
        published_data = args[1]
        
        self.assertEqual(published_data["type"], "ag_ui_event")
        self.assertIn("seqId", published_data)
        self.assertEqual(published_data["text"], "Hello world")

    async def test_ag_ui_on_output_callback(self):
        """Verify on_output callback is used for AG-UI chunks."""
        card_id = "test_card_callback"
        self.dispatcher.set_ui_format(card_id, "ag_ui")
        
        # Simulated notification chunk
        notification = {
            "method": "session/update",
            "params": {
                "sessionId": "session_123",
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"text": "Hello world"}
                }
            }
        }
        
        # Mock on_output callback
        on_output = MagicMock()
        
        # Process notification
        await self.dispatcher._forward_notification(card_id, notification, on_output, ui_format="ag_ui")
        
        # Verify on_output was called
        on_output.assert_called()

    @patch('src.transport.bus.bus.publish')
    async def test_ag_ui_plan_update(self, mock_publish):
        """Verify AG-UI plan updates are published in real-time and follow the unified path."""
        card_id = "test_card_plan"
        self.dispatcher.set_ui_format(card_id, "ag_ui")
        
        # Simulated plan update
        notification = {
            "method": "session/update",
            "params": {
                "sessionId": "session_123",
                "update": {
                    "sessionUpdate": "plan",
                    "entries": [
                        {"content": "Step 1", "status": "completed"}
                    ]
                }
            }
        }
        
        await self.dispatcher._forward_notification(card_id, notification, ui_format="ag_ui")
        
        # Verify it was published as an AG-UI event
        mock_publish.assert_called()
        published_data = mock_publish.call_args[0][1]
        self.assertEqual(published_data["type"], "ag_ui_event")
        self.assertEqual(published_data["event"], "plan_update")

    async def test_ag_ui_tool_isolation_fix(self):
        """Verify tool calls are isolated from reasoning and stored as separate messages."""
        card_id = "test_card_tool_isolation"
        self.dispatcher.set_ui_format(card_id, "ag_ui")
        
        # 1. Simulate tool call start
        tool_call_start = {
            "method": "session/update",
            "params": {
                "card_id": card_id,
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call_1",
                    "tool": "read_file",
                    "status": "pending",
                    "rawInput": {"path": "test.txt"}
                }
            }
        }
        await self.dispatcher._forward_notification(card_id, tool_call_start, ui_format="ag_ui")
        await self.dispatcher._trigger_flush(card_id) # Force flush
        
        # 2. Check DB
        history = self.db.get_session_history(card_id)
        # Should have a 'tool' message
        tool_msgs = [m for m in history if m['role'] == 'tool']
        self.assertEqual(len(tool_msgs), 1)
        
        # Check metadata (comes back as JSON string from get_session_history if not formatted)
        # Wait, get_session_history usually returns formatted dicts in this project
        meta = tool_msgs[0]['metadata']
        if isinstance(meta, str): meta = json.loads(meta)
        
        self.assertEqual(meta['tool_id'], "call_1")
        self.assertEqual(meta['status'], "running")
        
        # 3. Check that reasoning is NOT polluted
        assistant_msgs = [m for m in history if m['role'] == 'assistant']
        for m in assistant_msgs:
            self.assertNotIn("Calling tool", m['content'])
            self.assertNotIn("read_file", m['content'])

        # 4. Simulate tool result
        tool_call_result = {
            "method": "session/update",
            "params": {
                "card_id": card_id,
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call_1",
                    "tool": "read_file",
                    "status": "completed",
                    "content": [{"type": "content", "content": {"text": "file content"}}]
                }
            }
        }
        await self.dispatcher._forward_notification(card_id, tool_call_result, ui_format="ag_ui")
        await self.dispatcher._trigger_flush(card_id) # Force flush
        
        # 5. Check DB again
        history = self.db.get_session_history(card_id)
        tool_msgs = [m for m in history if m['role'] == 'tool']
        self.assertEqual(len(tool_msgs), 1) # Should still be 1 (upserted)
        
        meta = tool_msgs[0]['metadata']
        if isinstance(meta, str): meta = json.loads(meta)
        self.assertEqual(meta['status'], "success")
        self.assertEqual(tool_msgs[0]['content'], "file content")

if __name__ == '__main__':
    unittest.main()
