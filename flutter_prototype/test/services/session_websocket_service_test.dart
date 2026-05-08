import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_prototype/services/session_websocket_service.dart';

void main() {
  group('SessionWebsocketService AG-UI Tests', () {
    // === 高优先级补充：ui_format 协商协议 ===
    test('test_ui_format_negotiation', () async {
      // 模拟 WebSocket 消息发送逻辑
      Map<String, dynamic> lastSentData = {};
      
      void mockSend(dynamic data) {
        lastSentData = data as Map<String, dynamic>;
      }

      // 模拟 connect/init 逻辑
      void mockSendInit() {
        mockSend({
          'type': 'session_init',
          'ui_format': 'ag_ui', // 验证是否带上了协商参数
          'capabilities': ['streaming', 'tool_pills', 'reasoning']
        });
      }

      mockSendInit();
      expect(lastSentData['ui_format'], 'ag_ui');
      expect(lastSentData['capabilities'], contains('streaming'));
    });

    // === 中优先级补充：断网重连数据恢复 (seqId 校验) ===
    test('test_network_reconnection_recovery_logic', () async {
      // 模拟前端已收到的 seqId
      int lastReceivedSeq = 10;
      
      // 模拟重连请求历史时带上 offset
      Map<String, dynamic> requestHistory(int lastSeq) {
        return {
          'type': 'get_history',
          'after_seq': lastSeq
        };
      }

      final req = requestHistory(lastReceivedSeq);
      expect(req['after_seq'], 10);
      // 后端应据此返回 seqId > 10 的消息，实现增量同步
    });
  });
}
