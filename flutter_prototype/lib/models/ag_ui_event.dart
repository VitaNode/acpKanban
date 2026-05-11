import 'dart:convert';
import 'card_message.dart';

class AgUiEvent {
  final String? eventType;
  final String? text;
  final String? reasoning;
  final int? seqId;
  final bool? isComplete;
  final List<ToolCall>? toolCalls;
  final String? sessionId;
  final List<Map<String, dynamic>>? commands;
  final Map<String, dynamic>? plan;
  final List<dynamic>? options;
  final String? title;
  final String? method;
  final String? requestId;

  AgUiEvent({
    this.eventType,
    this.text,
    this.reasoning,
    this.seqId,
    this.isComplete,
    this.toolCalls,
    this.sessionId,
    this.commands,
    this.plan,
    this.options,
    this.title,
    this.method,
    this.requestId,
  });

  factory AgUiEvent.fromMessage(CardMessage message) {
    // Parse the content which should be a JSON string representing an AG-UI event
    try {
      final content = message.content;
      if (content.isEmpty) {
        return AgUiEvent();
      }
      
      final Map<String, dynamic> json = jsonDecode(content);
      
      // Parse tool calls - support both single tool call (legacy) and array format
      List<ToolCall>? toolCalls;
      if (json['tool_calls'] != null && json['tool_calls'] is List) {
        // New format: tool_calls array
        toolCalls = _parseToolCalls(json['tool_calls']);
      } else if (json['toolId'] != null || json['name'] != null) {
        // Legacy format: single tool call at root level
        toolCalls = [ToolCall(
          toolId: json['toolId'] as String?,
          name: json['name'] as String?,
          status: json['status'] as String?,
          args: json['args'] as String?,
          result: json['result'] as String?,
        )];
      }
      
      return AgUiEvent(
        eventType: json['event'] as String?,
        text: json['text'] as String?,
        reasoning: json['reasoning'] as String?,
        seqId: json['seqId'] as int?,
        isComplete: json['is_complete'] as bool?,
        sessionId: json['session_id'] as String?,
        toolCalls: toolCalls,
        commands: (json['commands'] as List?)?.cast<Map<String, dynamic>>(),
        plan: json['plan'] as Map<String, dynamic>?,
        options: json['options'] as List?,
        title: json['title'] as String?,
        method: json['method'] as String?,
        requestId: json['requestId'] as String?,
      );
    } catch (e) {
      // If parsing fails, return empty event
      return AgUiEvent();
    }
  }

  static List<ToolCall>? _parseToolCalls(dynamic toolCallsJson) {
    if (toolCallsJson == null) return null;
    if (toolCallsJson is! List) return null;
    
    return toolCallsJson.map((tc) => ToolCall.fromJson(tc as Map<String, dynamic>)).toList();
  }
}

class ToolCall {
  final String? toolId;
  final String? name;
  final String? status;
  final String? args;
  final String? result;

  ToolCall({
    this.toolId,
    this.name,
    this.status,
    this.args,
    this.result,
  });

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      toolId: json['tool_id'] as String?,
      name: json['name'] as String?,
      status: json['status'] as String?,
      args: json['args'] as String?,
      result: json['result'] as String?,
    );
  }
}