import unittest
import json
from src.protocol.ag_ui_mapper import AGUIMapper

class TestAGUIMapper(unittest.TestCase):
    def setUp(self):
        self.mapper = AGUIMapper()

    def test_map_history_message_text_only(self):
        msg = {"role": "assistant", "content": "Hello world", "metadata": None, "created_at": "2024-01-01T00:00:00", "is_complete": True}
        result = self.mapper.map_history_message(msg)
        self.assertEqual(result["event"], "message_bundled")

    def test_map_history_message_with_thought(self):
        msg = {
            "role": "assistant",
            "content": "Final answer",
            "metadata": {"thought": "I am thinking..."},
            "created_at": "2024-01-01T00:00:00",
            "is_complete": True
        }
        result = self.mapper.map_history_message(msg)
        self.assertEqual(result["reasoning"], "I am thinking...")

    def test_map_history_message_tool_extraction(self):
        """测试从旧格式 content 中智能提取工具调用标记"""
        msg = {
            "role": "assistant",
            "content": "Running tool... 🛠️ read_file(path='test.py'): success",
            "metadata": None,
            "created_at": "2024-01-01T00:00:00",
            "is_complete": True
        }
        result = self.mapper.map_history_message(msg)
        self.assertIn("read_file", str(result))
        self.assertIn("Running tool", result["text"])

    def test_map_notification_agent_message_chunk(self):
        acp_notif = {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"text": "part of msg"}
                }
            }
        }
        result = self.mapper.map_notification(acp_notif)
        self.assertEqual(result["event"], "message_chunk")
        self.assertEqual(result["text"], "part of msg")

    def test_map_notification_tool_call_start(self):
        """Test tool_call with pending status maps to tool_call_start"""
        acp_notif = {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call_123",
                    "tool": "web_search",
                    "status": "pending"
                }
            }
        }
        result = self.mapper.map_notification(acp_notif)
        self.assertEqual(result["event"], "tool_call_start")
        self.assertEqual(result["tool_id"], "call_123")
        self.assertEqual(result["status"], "running")  # Mapped from pending
        self.assertEqual(result["tool"], "web_search")
    
    def test_map_notification_tool_call_result(self):
        """Test tool_call with completed status maps to tool_call_result"""
        acp_notif = {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call_456",
                    "tool": "code_executor",
                    "status": "completed"
                }
            }
        }
        result = self.mapper.map_notification(acp_notif)
        self.assertEqual(result["event"], "tool_call_result")
        self.assertEqual(result["tool_id"], "call_456")
        self.assertEqual(result["status"], "success")  # Mapped from completed
    
    def test_map_notification_tool_call_update(self):
        """Test tool_call_update event mapping"""
        acp_notif = {
            "method": "session/update",
            "params": {
                "update": {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call_789",
                    "status": "running",
                    "content": [{"type": "text", "text": "Processing..."}]
                }
            }
        }
        result = self.mapper.map_notification(acp_notif)
        self.assertEqual(result["event"], "tool_call_update")
        self.assertEqual(result["tool_id"], "call_789")
        self.assertEqual(result["status"], "running")

    def test_fallback_for_unknown_format(self):
        acp_notif = {"method": "unknown/method", "params": {}}
        result = self.mapper.map_notification(acp_notif)
        self.assertIsNone(result)

if __name__ == '__main__':
    unittest.main()
