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

    def test_map_request_permission(self):
        """Test mapping of session/request_permission to interactive_request"""
        method = "session/request_permission"
        params = {
            "card_id": "card_789",
            "title": "Edit Permission",
            "toolCall": {
                "kind": "edit",
                "content": [{"type": "diff", "path": "test.txt", "newText": "hello"}]
            },
            "options": [
                {"id": "allow", "label": "Allow", "primary": True}
            ]
        }
        request_id = "req_123"
        result = self.mapper.map_request(method, params, request_id)
        
        self.assertEqual(result["event"], "interactive_request")
        self.assertEqual(result["requestId"], request_id)
        self.assertIn("File Operation: Edit", result["text"])
        self.assertEqual(len(result["options"]), 1)
        self.assertEqual(result["options"][0]["id"], "allow")

    def test_map_request_plan_extraction(self):
        """测试从 toolCall content 中提取 Plan 内容"""
        method = "session/request_permission"
        params = {
            "card_id": "card_789",
            "toolCall": {
                "title": "Plan:",
                "kind": "unknown",
                "content": [
                    {"type": "text", "text": "## Implementation Plan\n\n1. Step one\n2. Step two"}
                ]
            }
        }
        request_id = "req_plan"
        result = self.mapper.map_request(method, params, request_id)
        
        self.assertEqual(result["title"], "Plan:")
        self.assertEqual(result["text"], "## Implementation Plan\n\n1. Step one\n2. Step two")

    def test_map_history_message_with_reasoning_type(self):
        """测试正确识别 metadata 类型为 reasoning 的记录"""
        msg = {
            "role": "assistant",
            "content": "This is my thought process",
            "metadata": {"type": "reasoning"},
            "created_at": "2024-01-01T00:00:00",
            "is_complete": True
        }
        result = self.mapper.map_history_message(msg)
        self.assertEqual(result["reasoning"], "This is my thought process")
        self.assertEqual(result["text"], "")

    def test_map_history_message_structured_tool_calls(self):
        """测试从 metadata 中映射结构化的工具调用"""
        msg = {
            "role": "assistant",
            "content": "Result of tool",
            "metadata": {
                "tool_calls": [
                    {
                        "tool_id": "call_1",
                        "name": "read_file",
                        "arguments": "path='test.py'",
                        "result": "file content",
                        "status": "completed"
                    }
                ]
            },
            "created_at": "2024-01-01T00:00:00",
            "is_complete": True
        }
        result = self.mapper.map_history_message(msg)
        self.assertEqual(len(result["tool_calls"]), 1)
        self.assertEqual(result["tool_calls"][0]["tool"], "read_file")
        self.assertEqual(result["tool_calls"][0]["args"], "path='test.py'")

if __name__ == '__main__':
    unittest.main()
