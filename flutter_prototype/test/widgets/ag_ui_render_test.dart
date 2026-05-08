import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_prototype/widgets/message_bubble.dart';
import 'package:flutter_prototype/models/card_message.dart';
import 'package:flutter_prototype/widgets/ag_ui/thinking_block.dart';
import 'package:flutter_prototype/widgets/ag_ui/tool_pill.dart';

import 'package:flutter_prototype/constants/app_constants.dart';

void main() {
  group('MessageBubble & AG-UI Components (Expanded)', () {
    // === 高优先级补充：节流逻辑验证 ===
    testWidgets('test_throttle_timing', (WidgetTester tester) async {
      String currentText = "";
      
      // 模拟一个简单的节流渲染组件逻辑
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            Timer? timer;
            void onChunk(String chunk) {
              currentText += chunk;
              timer?.cancel();
              timer = Timer(AppConstants.streamThrottleMs, () {
                setState(() {});
              });
            }
            
            return Scaffold(
              body: Column(
                children: [
                  Text(currentText),
                  ElevatedButton(
                    onPressed: () {
                      onChunk("A");
                      onChunk("B");
                      onChunk("C");
                    },
                    child: const Text("Send Chunks"),
                  )
                ],
              ),
            );
          },
        ),
      ));

      await tester.tap(find.text("Send Chunks"));
      // 立即检查：由于节流，UI 应该还没刷新
      await tester.pump(); 
      expect(find.text("ABC"), findsNothing);

      // 等待超过 60ms
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text("ABC"), findsOneWidget);
    });

    // === 高优先级补充：ToolPill 状态切换渲染 ===
    testWidgets('test_tool_pill_state_transition_ui', (WidgetTester tester) async {
      // 初始状态：Running
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ToolPill(name: 'read_file', status: 'running'),
        ),
      ));
      expect(find.byIcon(Icons.refresh), findsOneWidget); // 假设 running 显示刷新图标

      // 切换状态：Success
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ToolPill(name: 'read_file', status: 'success'),
        ),
      ));
      expect(find.byIcon(Icons.check_circle), findsOneWidget); // 假设 success 显示勾选图标
    });

    // === 中优先级补充：ThinkingBlock 展开/折叠交互 ===
    testWidgets('test_thinking_block_expand_collapse', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ThinkingBlock(
            text: 'I am reasoning...',
            isCollapsed: true, // 初始折叠
          ),
        ),
      ));

      // 验证折叠状态（文本可能不可见或只显示标题）
      expect(find.text('I am reasoning...'), findsNothing);

      // 点击展开
      await tester.tap(find.byType(ThinkingBlock));
      await tester.pumpAndSettle();

      // 验证展开状态
      expect(find.text('I am reasoning...'), findsOneWidget);
    });

    // === 中优先级补充：长对话列表性能 (Mock) ===
    testWidgets('test_long_conversation_performance_rendering', (WidgetTester tester) async {
      final messages = List.generate(100, (i) => CardMessage(
        id: '$i',
        cardId: 'c1',
        role: i % 2 == 0 ? 'user' : 'assistant',
        content: 'Message $i',
        createdAt: '',
      ));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: messages.length,
            itemBuilder: (context, index) => MessageBubble(message: messages[index]),
          ),
        ),
      ));

      // 验证第一条消息
      expect(find.text('Message 0'), findsOneWidget);
      
      // 滚动到底部
      await tester.drag(find.byType(ListView), const Offset(0, -5000));
      await tester.pumpAndSettle();

      // 验证最后一条消息（虚拟列表应正常工作）
      expect(find.text('Message 99'), findsOneWidget);
    });
  });
}
