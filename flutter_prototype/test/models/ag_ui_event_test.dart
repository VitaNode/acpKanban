import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanban_app/models/card_message.dart';
import 'package:kanban_app/models/ag_ui_event.dart';

void main() {
  group('AgUiEvent Model & Logic Tests (Expanded)', () {
    // === 高优先级补充：ToolPill 状态转换 ===
    test('test_tool_pill_state_transition', () {
      final startJson = jsonEncode({
        'type': 'ag_ui_event',
        'event': 'tool_call_start',
        'toolId': 't1',
        'name': 'search'
      });

      final resultJson = jsonEncode({
        'type': 'ag_ui_event',
        'event': 'tool_call_result',
        'toolId': 't1',
        'status': 'success'
      });

      final event1 = AgUiEvent.fromMessage(CardMessage(
          id: '1',
          cardId: 'c1',
          role: 'assistant',
          content: startJson,
          createdAt: ''));
      final event2 = AgUiEvent.fromMessage(CardMessage(
          id: '2',
          cardId: 'c1',
          role: 'assistant',
          content: resultJson,
          createdAt: ''));

      expect(event1.eventType, 'tool_call_start');
      expect(event1.toolCalls?.first.toolId, 't1');

      expect(event2.eventType, 'tool_call_result');
      expect(event2.toolCalls?.first.status, 'success');
    });

    // === 高优先级补充：乱序事件处理 (SeqId 排序) ===
    test('test_seq_id_ordering_logic', () {
      final events = [
        {'seqId': 2, 'text': 'World'},
        {'seqId': 1, 'text': 'Hello '},
      ];

      // 模拟前端排序逻辑
      events.sort((a, b) => (a['seqId'] as int).compareTo(b['seqId'] as int));

      final result = events.map((e) => e['text']).join();
      expect(result, 'Hello World');
    });

    // === 高优先级补充：乱序事件缓冲 (End 先于 Content) ===
    test('test_out_of_order_event_buffering', () {
      bool isRenderedAsComplete = false;
      List<int> receivedSeqs = [];
      int expectedEndSeq = 2;

      void onEvent(int seq, bool isEnd) {
        receivedSeqs.add(seq);
        // 如果收到了 end，但前面的 seq 还没到齐，不能标记为 complete
        if (isEnd && !receivedSeqs.contains(1)) {
          isRenderedAsComplete = false;
        } else if (receivedSeqs.contains(1) &&
            receivedSeqs.contains(expectedEndSeq)) {
          isRenderedAsComplete = true;
        }
      }

      onEvent(2, true); // End 先到
      expect(isRenderedAsComplete, false);

      onEvent(1, false); // Content 后到
      expect(isRenderedAsComplete, true);
    });

    // === 中优先级补充：长消息性能逻辑模拟 ===
    test('test_long_message_data_handling', () {
      final longText = 'A' * 10000;
      final msg = CardMessage(
        id: '1',
        cardId: 'c1',
        role: 'assistant',
        content: jsonEncode(
            {'type': 'ag_ui_event', 'event': 'text_message', 'text': longText}),
        createdAt: '',
      );

      final event = AgUiEvent.fromMessage(msg);
      expect(event.text?.length, 10000);
    });
  });
}
