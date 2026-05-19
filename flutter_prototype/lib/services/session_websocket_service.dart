import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/config_option.dart';
import '../models/kanban_card.dart';
import '../models/ag_ui_event.dart';
import '../constants/error_copy.dart';
import '../utils/app_logger.dart';
import 'acp_client.dart';
import 'smart_connect.dart';

class SessionWebSocketService {
  static final SessionWebSocketService _instance =
      SessionWebSocketService._internal();
  factory SessionWebSocketService() => _instance;
  SessionWebSocketService._internal();

  static const String _baseUrl = 'http://localhost:8000';
  final ACPClient _acpClient = ACPClient();
  
  bool get _useProxy => _acpClient.activeMode != ConnectionPath.none;

  WebSocketChannel? _channel;
  StreamSubscription? _acpSub;

  final _messageController = StreamController<List<CardMessage>>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _planController = StreamController<AgentPlan?>.broadcast();
  final _configController = StreamController<List<ConfigOption>>.broadcast();
  final _commandController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _requestController = StreamController<Map<String, dynamic>>.broadcast();
  final _cardUpdateController = StreamController<KanbanCard>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _initializingController = StreamController<bool>.broadcast();
  final _contextController = StreamController<String>.broadcast();

  String? _currentCardId;
  bool _isConnected = false;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectCount = 0;

  // Track whether history has been loaded for the current card
  bool _hasLoadedHistory = false;
  String? _uiFormat;

  // Local cache to support streaming updates
  List<CardMessage> _currentMessages = [];
  
  // AG-UI Buffer for out-of-order event reordering
  final Map<int, AgUiEvent> _eventBuffer = {};
  int _lastContiguousSeqId = 0;

  Stream<List<CardMessage>> get messages => _messageController.stream;
  Stream<String> get status => _statusController.stream;
  Stream<AgentPlan?> get plan => _planController.stream;
  Stream<List<ConfigOption>> get configOptions => _configController.stream;
  Stream<List<Map<String, dynamic>>> get availableCommands =>
      _commandController.stream;
  Stream<Map<String, dynamic>> get requests => _requestController.stream;
  Stream<KanbanCard> get cardUpdates => _cardUpdateController.stream;
  Stream<String> get errors => _errorController.stream;
  Stream<bool> get isInitializing => _initializingController.stream;
  Stream<String> get contextData => _contextController.stream;
  bool get isConnected => _isConnected;
  String? get uiFormat => _uiFormat;

  Future<bool> connect(String cardId, {int retryCount = 0}) async {
    AppLogger.info('Connect attempt for card $cardId (retry=$retryCount), currentCardId=$_currentCardId, isConnected=$_isConnected, hasLoadedHistory=$_hasLoadedHistory');
    
    if (_currentCardId != null && _currentCardId != cardId) {
      AppLogger.info('Switching from card $_currentCardId to $cardId, disconnecting old connection');
      await disconnect();
    }

    if ((_channel != null || (_useProxy && _isConnected)) && _currentCardId == cardId && _isConnected) {
      AppLogger.info('Reusing existing connection for card $cardId, clearing cache and requesting history');
      _clearCache();
      await _requestHistory();
      return true;
    }

    _currentCardId = cardId;
    _currentMessages = [];
    _eventBuffer.clear();
    _lastContiguousSeqId = 0;
    _hasLoadedHistory = false;
    _messageController.add([]);
    _planController.add(null);
    _configController.add([]);
    _commandController.add([]);
    _reconnectCount = 0;

    if (_useProxy) {
      AppLogger.info('Using ACP Proxy for card $cardId');
      try {
        await _acpClient.waitForReady;
        final response = await _acpClient.sendRequest('session/ws_proxy', {
          'action': 'connect',
          'card_id': cardId,
        });
        
        if (response.containsKey('result')) {
          _isConnected = true;
          _reconnectCount = 0;
          
          _acpSub?.cancel();
          _acpSub = _acpClient.messages.listen((msgStr) {
            try {
              final msg = jsonDecode(msgStr);
              if (msg['method'] == 'session/ws_event' && msg['params']?['card_id'] == _currentCardId) {
                _handleMessage(msg['params']['payload']);
              }
            } catch (e) {
              AppLogger.error('ACP Msg Error', e);
            }
          });
          
          await _requestHistory();
          return true;
        } else {
          final err = response['error'];
          _errorController.add(ErrorCopy.mapError(err['error_code'], err['message']));
          AppLogger.error('Proxy connect failed: ${response['error']}');
          return false;
        }
      } catch (e) {
        _errorController.add(ErrorCopy.networkError);
        AppLogger.error('Proxy connect error', e);
        return false;
      }
    }

    try {
      final uri = Uri.parse(
          '${_baseUrl.replaceFirst('http', 'ws')}/api/ws/session/$cardId');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      _isConnected = true;
      _reconnectCount = 0;
      _startHeartbeat();
      _channel!.stream.listen((data) => _handleMessage(data),
          onError: (e) {
        _isConnected = false;
        _reconnectIfNecessary();
      }, onDone: () {
        _isConnected = false;
        _reconnectIfNecessary();
      });
      await _requestHistory();
      return true;
    } catch (e) {
      _isConnected = false;
      if (retryCount < 3) {
        await Future.delayed(const Duration(seconds: 2));
        return connect(cardId, retryCount: retryCount + 1);
      }
      return false;
    }
  }

  void _reconnectIfNecessary() {
    _reconnectTimer?.cancel();
    if (_currentCardId != null && _reconnectCount < 5) {
      _reconnectCount++;
      _reconnectTimer = Timer(Duration(seconds: 5 * _reconnectCount), () {
        if (!_isConnected && _currentCardId != null) connect(_currentCardId!);
      });
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      if (_isConnected) {
        if (_useProxy) {
          // Heartbeat for Proxy mode
          _acpClient.sendRequest('session/ws_proxy', {
            'action': 'ping',
            'card_id': _currentCardId,
          }).catchError((e) {
            _isConnected = false;
            _reconnectIfNecessary();
          });
        } else if (_channel != null) {
          // Heartbeat for Direct mode
          try {
            _channel!.sink.add(jsonEncode({'type': 'ping'}));
          } catch (e) {
            _isConnected = false;
            _reconnectIfNecessary();
          }
        }
      }
    });
  }

  Future<void> _requestHistory() async {
    final afterSeq = _lastContiguousSeqId;
    await _send({
      'type': 'get_history',
      'after_seq': afterSeq,
    });
  }

  Future<void> _send(dynamic data) async {
    if (!_isConnected) return;
    
    if (_useProxy) {
      try {
        await _acpClient.sendRequest('session/ws_proxy', {
          'action': 'send',
          'card_id': _currentCardId,
          'data': data,
        });
      } catch (e) {
        AppLogger.error('Proxy send error', e);
      }
    } else if (_channel != null) {
      _channel!.sink.add(data is String ? data : jsonEncode(data));
    }
  }

  List<CardMessage> _mergeMessages(List<CardMessage> messages) {
    if (messages.isEmpty) return [];

    List<CardMessage> merged = [];
    CardMessage? current;

    for (var next in messages) {
      if (current == null) {
        current = next;
        continue;
      }

      bool canMerge = false;
      if (current.role.toLowerCase() == 'assistant' &&
          next.role.toLowerCase() == 'assistant') {
        final currentMeta = current.metadata ?? {};
        final nextMeta = next.metadata ?? {};
        final currentType = currentMeta['type'];
        final nextType = nextMeta['type'];
        
        if (currentType == 'reasoning' && nextType == 'reasoning') {
          canMerge = true;
        } else if (currentType == null && nextType == null) {
          canMerge = true;
        } else if (currentType == 'plan_update' && nextType == 'plan_update') {
          canMerge = true;
        }
      }

      if (canMerge) {
        String newContent = current.content + next.content;
        final Map<String, dynamic> mergedMeta = Map<String, dynamic>.from(current.metadata ?? {});
        final nextMeta = next.metadata ?? {};
        
        nextMeta.forEach((key, value) {
          if (key == 'thought') {
            final prevThought = mergedMeta['thought']?.toString() ?? '';
            mergedMeta['thought'] = prevThought + (value?.toString() ?? '');
          } else if (key == 'tool_calls') {
            final List<dynamic> currentTC = List.from(mergedMeta['tool_calls'] ?? []);
            final List<dynamic> nextTC = List.from(value as List? ?? []);
            for (var tc in nextTC) {
              final id = tc['tool_id'];
              final existingIdx = currentTC.indexWhere((e) => e['tool_id'] == id && id != null);
              if (existingIdx != -1) currentTC[existingIdx] = tc;
              else currentTC.add(tc);
            }
            mergedMeta['tool_calls'] = currentTC;
          } else {
            mergedMeta[key] = value;
          }
        });

        current = current.copyWith(
          content: newContent,
          metadata: mergedMeta.isNotEmpty ? mergedMeta : null,
          isComplete: next.isComplete,
          seqId: next.seqId ?? current.seqId,
        );
      } else {
        merged.add(current);
        current = next;
      }
    }
    if (current != null) merged.add(current);
    return merged;
  }

  void _handleMessage(dynamic data) {
    try {
      Map<String, dynamic> m;
      if (data is String) {
        m = jsonDecode(data) as Map<String, dynamic>;
      } else if (data is Map<String, dynamic>) {
        m = data;
      } else {
        final errorMsg = 'WS: Unexpected message type: ${data.runtimeType}';
        AppLogger.error(errorMsg);
        _errorController.add(errorMsg);
        return;
      }
      if (m['method'] != null && m['id'] != null) {
        _requestController.add(m);
        return;
      }
      if (m['type'] == 'ag_ui_event') {
        final agUiEvent = AgUiEvent.fromMessage(CardMessage(
          id: '',
          cardId: _currentCardId ?? '',
          role: 'assistant',
          content: jsonEncode(m),
          createdAt: '',
        ));
        if (agUiEvent.seqId != null) {
          _eventBuffer[agUiEvent.seqId!] = agUiEvent;
          _tryDeliverBufferedEvents();
        } else {
          _deliverAgUiEvent(agUiEvent);
        }
        return;
      }

      switch (m['type']) {
        case 'history':
          final rawMessages = (m['messages'] as List?) ?? [];
          final List<CardMessage> newMessages = [];
          for (int i = 0; i < rawMessages.length; i++) {
            var msg = CardMessage.fromJson(rawMessages[i]);
            if (msg.seqId == null) {
              msg = msg.copyWith(seqId: _lastContiguousSeqId + i + 1);
            }
            if (msg.metadata?['thought'] != null && msg.content.isEmpty) {
              msg = msg.copyWith(content: msg.metadata!['thought'] as String);
            }
            newMessages.add(msg);
          }
          if (newMessages.isEmpty && _lastContiguousSeqId > 0) {
            _updateCardAndConfig(m);
            return;
          }
          if (_lastContiguousSeqId == 0) {
            _currentMessages = List.from(newMessages);
            _hasLoadedHistory = true;
          } else {
            for (var msg in newMessages) {
              final index = _currentMessages.indexWhere((existing) => 
                (existing.id == msg.id && msg.id.isNotEmpty && !msg.id.startsWith('streaming-') && !msg.id.startsWith('thought-')) || 
                (existing.seqId == msg.seqId && msg.seqId != null)
              );
              if (index != -1) _currentMessages[index] = msg;
              else _currentMessages.add(msg);
            }
            _currentMessages.sort((a, b) {
              if (a.seqId != null && b.seqId != null) return a.seqId!.compareTo(b.seqId!);
              return a.createdAt.compareTo(b.createdAt);
            });
          }
          for (var msg in _currentMessages) {
            if (msg.seqId != null && msg.seqId! > _lastContiguousSeqId) _lastContiguousSeqId = msg.seqId!;
          }
          _messageController.add(_mergeMessages(_currentMessages));
          _updateCardAndConfig(m);
          break;
        case 'agent_plan':
          _planController.add(m['plan'] != null ? AgentPlan.fromJson(m['plan']) : null);
          break;
        case 'config_options':
          _configController.add((m['options'] as List?)?.map((x) => ConfigOption.fromJson(x)).toList() ?? []);
          break;
        case 'available_commands':
          _commandController.add((m['commands'] as List?)?.cast<Map<String, dynamic>>() ?? []);
          break;
        case 'agent_message_chunk':
          final chunk = m['content']?['text'] ?? '';
          if (m['_meta'] != null || m['usage'] != null) _requestHistory();
          if (chunk.isNotEmpty) {
            if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && !_currentMessages.last.isComplete) {
              final last = _currentMessages.last;
              _currentMessages[_currentMessages.length - 1] = last.copyWith(content: last.content + chunk);
            } else {
              _currentMessages.add(CardMessage(
                id: 'streaming-${DateTime.now().millisecondsSinceEpoch}',
                cardId: _currentCardId ?? '',
                role: 'assistant',
                content: chunk,
                createdAt: DateTime.now().toIso8601String(),
                isComplete: false
              ));
            }
            _messageController.add(List.from(_currentMessages));
          }
          break;
        case 'agent_thought_chunk':
          final thought = m['content']?['text'] ?? '';
          if (m['_meta'] != null || m['usage'] != null) _requestHistory();
          if (thought.isNotEmpty) {
             if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && !_currentMessages.last.isComplete) {
              final last = _currentMessages.last;
              final metadata = Map<String, dynamic>.from(last.metadata ?? {});
              metadata['thought'] = (metadata['thought'] ?? '') + thought;
              _currentMessages[_currentMessages.length - 1] = last.copyWith(metadata: metadata);
            } else {
              _currentMessages.add(CardMessage(
                id: 'thought-${DateTime.now().millisecondsSinceEpoch}',
                cardId: _currentCardId ?? '',
                role: 'assistant',
                content: '',
                createdAt: DateTime.now().toIso8601String(),
                isComplete: false,
                metadata: {'thought': thought}
              ));
            }
            _messageController.add(List.from(_currentMessages));
          }
          break;
        case 'tool_call':
        case 'tool_call_update':
          _requestHistory();
          break;
        case 'message_added':
        case 'refresh':
          _requestHistory();
          break;
        case 'session_info_update':
          if (m['title'] != null || m['description'] != null) {
            _cardUpdateController.add(KanbanCard(
              id: _currentCardId ?? '',
              title: m['title'] ?? '',
              description: m['description'] ?? '',
              columnId: '',
              createdAt: DateTime.now().toIso8601String(),
              updatedAt: DateTime.now().toIso8601String(),
            ));
          }
          break;
        case 'session_info':
          _initializingController.add(false);
          _uiFormat = m['ui_format'];
          if (m['config_options'] != null) {
            _configController.add((m['config_options'] as List?)?.map((x) => ConfigOption.fromJson(x)).toList() ?? []);
          }
          if (m['sessionId'] != null) {
            _cardUpdateController.add(KanbanCard(
              id: _currentCardId ?? '',
              title: '', description: '', columnId: '', createdAt: '', updatedAt: '',
              acpSessionId: m['sessionId'], acpProviderId: null,
            ));
          }
          break;
        case 'context_data':
          if (m['context'] != null) _contextController.add(m['context']);
          break;
        case 'token_update':
          _cardUpdateController.add(KanbanCard(
            id: _currentCardId ?? '',
            title: '', description: '', columnId: '', createdAt: '', updatedAt: '',
            inputTokens: m['input_tokens'] ?? 0, outputTokens: m['output_tokens'] ?? 0,
          ));
          break;
        case 'error':
          _initializingController.add(false);
          _errorController.add(ErrorCopy.mapError(m['error_code'], m['message'] ?? 'Unknown agent error'));
          break;
      }
    } catch (e) {
      _initializingController.add(false);
      AppLogger.error('WS Parse Error', e);
      _errorController.add('Failed to process message: $e');
    }
  }

  void _deliverAgUiEvent(AgUiEvent event) {
    final Map<String, dynamic> agEventMap = {};
    if (event.eventType != null) agEventMap['event'] = event.eventType;
    if (event.text != null) agEventMap['text'] = event.text;
    if (event.reasoning != null) agEventMap['reasoning'] = event.reasoning;
    if (event.seqId != null) agEventMap['seqId'] = event.seqId;
    if (event.isComplete != null) agEventMap['is_complete'] = event.isComplete;
    if (event.sessionId != null) agEventMap['session_id'] = event.sessionId;
    if (event.toolCalls != null) {
      agEventMap['tool_calls'] = event.toolCalls!.map((tc) => {
        'tool_id': tc.toolId, 'name': tc.name, 'status': tc.status, 'args': tc.args, 'result': tc.result,
        if (tc.commandPreview != null) 'command_preview': tc.commandPreview,
        if (tc.fileTargets != null) 'file_targets': tc.fileTargets,
        if (tc.opKind != null) 'op_kind': tc.opKind,
        if (tc.diff != null) 'diff': tc.diff,
      }).toList();
    }
    if (event.commands != null) agEventMap['commands'] = event.commands;
    if (event.plan != null) agEventMap['plan'] = event.plan;
    if (event.options != null) agEventMap['options'] = event.options;

    final agUiMessage = CardMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}-${event.seqId ?? 0}',
      cardId: _currentCardId ?? '',
      role: 'assistant',
      content: jsonEncode(agEventMap),
      createdAt: DateTime.now().toIso8601String(),
      isComplete: event.isComplete ?? false,
      seqId: event.seqId,
    );

    if ((event.eventType == 'agent_message_chunk' || event.eventType == 'message_chunk') && event.text != null) {
      final chunk = event.text!;
      if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && !_currentMessages.last.isComplete && _currentMessages.last.metadata?['type'] != 'reasoning') {
        final last = _currentMessages.last;
        _currentMessages[_currentMessages.length - 1] = last.copyWith(content: last.content + chunk, seqId: event.seqId);
      } else {
        _currentMessages.add(CardMessage(
          id: 'streaming-${DateTime.now().millisecondsSinceEpoch}-${event.seqId ?? 0}',
          cardId: _currentCardId ?? '', role: 'assistant', content: chunk, createdAt: DateTime.now().toIso8601String(), isComplete: false, seqId: event.seqId,
        ));
      }
      _messageController.add(List.from(_currentMessages));
    } 
    else if ((event.eventType == 'agent_thought_chunk' || event.eventType == 'reasoning_message') && (event.text != null || event.reasoning != null)) {
      final thought = event.reasoning ?? event.text ?? '';
      if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && !_currentMessages.last.isComplete && _currentMessages.last.metadata?['type'] == 'reasoning') {
        final last = _currentMessages.last;
        _currentMessages[_currentMessages.length - 1] = last.copyWith(content: last.content + thought, seqId: event.seqId);
      } else {
        _currentMessages.add(CardMessage(
          id: 'thought-${DateTime.now().millisecondsSinceEpoch}-${event.seqId ?? 0}',
          cardId: _currentCardId ?? '', role: 'assistant', content: thought, createdAt: DateTime.now().toIso8601String(), isComplete: false, metadata: {'type': 'reasoning'}, seqId: event.seqId,
        ));
      }
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'tool_call_start' || event.eventType == 'tool_call_update' || event.eventType == 'tool_call_result') {
      final toolCall = event.toolCalls?.isNotEmpty == true ? event.toolCalls!.first : null;
      if (toolCall == null) return;
      final toolId = toolCall.toolId;
      final toolName = toolCall.name ?? 'Unknown';
      final toolStatus = _mapToolStatus(toolCall.status ?? 'running');
      int existingIndex = _currentMessages.indexWhere((m) => m.role == 'tool' && m.metadata?['tool_id'] == toolId);
      if (existingIndex != -1) {
        final existing = _currentMessages[existingIndex];
        final updatedMetadata = Map<String, dynamic>.from(existing.metadata ?? {});
        if ((updatedMetadata['name'] == null || updatedMetadata['name'] == 'Unknown') && toolName != 'Unknown') updatedMetadata['name'] = toolName;
        updatedMetadata['status'] = toolStatus;
        if (toolCall.args != null && toolCall.args!.isNotEmpty) updatedMetadata['arguments'] = toolCall.args;
        if (toolCall.commandPreview != null) updatedMetadata['command_preview'] = toolCall.commandPreview;
        if (toolCall.fileTargets != null) updatedMetadata['file_targets'] = toolCall.fileTargets;
        if (toolCall.opKind != null) updatedMetadata['op_kind'] = toolCall.opKind;
        if (toolCall.diff != null) updatedMetadata['diff'] = toolCall.diff;
        String content = existing.content;
        if (toolCall.result != null && toolCall.result!.isNotEmpty) content = toolCall.result!;
        _currentMessages[existingIndex] = existing.copyWith(content: content, isComplete: event.eventType == 'tool_call_result', metadata: updatedMetadata);
      } else {
        final meta = <String, dynamic>{
          'name': toolName, 'status': toolStatus, 'arguments': toolCall.args ?? '', 'tool_id': toolId,
          if (toolCall.commandPreview != null) 'command_preview': toolCall.commandPreview,
          if (toolCall.fileTargets != null) 'file_targets': toolCall.fileTargets,
          if (toolCall.opKind != null) 'op_kind': toolCall.opKind,
          if (toolCall.diff != null) 'diff': toolCall.diff,
        };
        _currentMessages.add(CardMessage(
          id: 'tool-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}',
          cardId: _currentCardId ?? '', role: 'tool', content: toolCall.result ?? '', createdAt: DateTime.now().toIso8601String(), isComplete: event.eventType == 'tool_call_result', seqId: event.seqId,
          metadata: meta,
        ));
      }
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'message_bundled' || event.eventType == 'message_chunk') {
      final text = event.text ?? '';
      final reasoning = event.reasoning;
      final metadata = <String, dynamic>{};
      if (reasoning != null && reasoning.isNotEmpty) metadata['thought'] = reasoning;
      if (event.toolCalls != null && event.toolCalls!.isNotEmpty) {
        metadata['tool_calls'] = event.toolCalls!.map((tc) => {
          'tool_id': tc.toolId, 'name': tc.name, 'status': tc.status, 'args': tc.args, 'result': tc.result,
          if (tc.commandPreview != null) 'command_preview': tc.commandPreview,
          if (tc.fileTargets != null) 'file_targets': tc.fileTargets,
          if (tc.opKind != null) 'op_kind': tc.opKind,
          if (tc.diff != null) 'diff': tc.diff,
        }).toList();
      }
      _currentMessages.add(CardMessage(
        id: 'bundled-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}',
        cardId: _currentCardId ?? '', role: 'assistant', content: text, createdAt: DateTime.now().toIso8601String(), isComplete: event.isComplete ?? true, seqId: event.seqId, metadata: metadata.isNotEmpty ? metadata : null
      ));
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == "interactive_request") {
      final eventJson = {"event": event.eventType, "text": event.text, "title": event.title, "method": event.method, "requestId": event.requestId, "options": event.options, "seqId": event.seqId};
      _currentMessages.add(CardMessage(
        id: "request-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}",
        cardId: _currentCardId ?? "", role: "assistant", content: jsonEncode(eventJson), createdAt: DateTime.now().toIso8601String(), isComplete: true, seqId: event.seqId, metadata: {"type": "interactive_request"}
      ));
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'user_message') {
      _currentMessages.add(CardMessage(
        id: 'user-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}',
        cardId: _currentCardId ?? '', role: 'user', content: event.text ?? '', createdAt: DateTime.now().toIso8601String(), isComplete: true, seqId: event.seqId,
      ));
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'plan_update') {
      try {
        final rawMap = jsonDecode(agUiMessage.content);
        final plan = AgentPlan.fromJson(rawMap);
        _planController.add(plan);
        if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && _currentMessages.last.metadata?['type'] == 'plan_update') {
          _currentMessages[_currentMessages.length - 1] = agUiMessage.copyWith(metadata: {'type': 'plan_update'});
        } else {
          _currentMessages.add(agUiMessage.copyWith(metadata: {'type': 'plan_update'}));
        }
        _messageController.add(List.from(_currentMessages));
      } catch (e) {
        AppLogger.error('Plan Update Error', e);
      }
    }
    else if (event.eventType == 'config_update') {
      try {
        final rawMap = jsonDecode(agUiMessage.content);
        final options = rawMap['options'] as List?;
        if (options != null) _configController.add(options.map((o) => ConfigOption.fromJson(o as Map<String, dynamic>)).toList());
      } catch (e) {
        AppLogger.error('Config Update Error', e);
      }
    }
    else if (event.eventType == 'commands_update') {
      try {
        final rawMap = jsonDecode(agUiMessage.content);
        final commands = rawMap['commands'] as List?;
        if (commands != null) _commandController.add(commands.map((c) => c as Map<String, dynamic>).toList());
      } catch (e) {
        AppLogger.error('Commands Update Error', e);
      }
    }
    else if (event.eventType == 'session_stop' || event.eventType == 'stop') {
      if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant') {
        _currentMessages[_currentMessages.length - 1] = _currentMessages.last.copyWith(isComplete: true);
        _messageController.add(List.from(_currentMessages));
      }
    }
    else {
      final ignoreEvents = ['heartbeat', 'session_info', 'context_data'];
      if (event.eventType != null && ignoreEvents.contains(event.eventType)) return;
      if (event.text != null && event.text!.isNotEmpty) {
        _currentMessages.add(agUiMessage);
        _messageController.add(List.from(_currentMessages));
      }
    }
  }

  String _mapToolStatus(String backendStatus) {
    switch (backendStatus) {
      case 'pending': case 'running': return 'running';
      case 'completed': case 'success': return 'success';
      case 'failed': case 'cancelled': case 'error': return 'failed';
      default: return 'running';
    }
  }

  void _tryDeliverBufferedEvents() {
    if (_eventBuffer.length > 100) {
      AppLogger.warning("Event buffer exceeded limit (100). Clearing buffer.");
      _eventBuffer.clear();
      return;
    }
    final sortedKeys = _eventBuffer.keys.toList()..sort();
    int deliverCount = 0;
    while (_eventBuffer.containsKey(_lastContiguousSeqId + 1)) {
      final nextSeqId = _lastContiguousSeqId + 1;
      final event = _eventBuffer.remove(nextSeqId)!;
      _lastContiguousSeqId = nextSeqId;
      _deliverAgUiEvent(event);
      deliverCount++;
    }
    if (deliverCount == 0 && _eventBuffer.isNotEmpty) {
      final oldestSeqId = sortedKeys.first;
      AppLogger.warning("Buffer gap detected. Forcing delivery of seqId=$oldestSeqId");
      _deliverAgUiEvent(_eventBuffer.remove(oldestSeqId)!);
      _lastContiguousSeqId = oldestSeqId;
    }
  }

  Future<void> sendInit() async {
    if (_isConnected) {
      _initializingController.add(true);
      await _send({'type': 'session_init', 'ui_format': 'ag_ui'});
    }
  }

  Future<void> cancelSession() async {
    if (_isConnected) await _send({'type': 'session_cancel'});
  }

  Future<void> getContext() async {
    if (_isConnected) await _send({'type': 'get_context'});
  }

  Future<void> setConfigOption(String configId, String value) async {
    if (_isConnected) await _send({'type': 'set_config_option', 'name': configId, 'value': value});
  }

  Future<void> sendMessage(String role, String content) async {
    if (!_isConnected) throw Exception(ErrorCopy.networkError);
    await _send({'type': 'send_message', 'role': role, 'content': content, 'ui_format': 'ag_ui'});
  }

  Future<void> sendResponse(String id, Map<String, dynamic> result) async {
    if (_isConnected) await _send({'type': 'rpc_response', 'id': id, 'result': result});
  }

  void addSyntheticUserMessage(String content) {
    _currentMessages.add(CardMessage(
      id: 'synthetic-${DateTime.now().millisecondsSinceEpoch}',
      cardId: _currentCardId ?? '', role: 'user', content: content, createdAt: DateTime.now().toIso8601String(),
    ));
    _messageController.add(List.from(_currentMessages));
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _acpSub?.cancel();
    _acpSub = null;
    if (_useProxy && _currentCardId != null && _isConnected) {
      try {
        await _acpClient.sendRequest('session/ws_proxy', {'action': 'disconnect', 'card_id': _currentCardId});
      } catch (e) {
        AppLogger.error('Proxy disconnect error', e);
      }
    }
    final channel = _channel;
    _channel = null;
    _isConnected = false;
    _hasLoadedHistory = false;
    if (channel != null) await channel.sink.close();
  }

  void _updateCardAndConfig(Map<String, dynamic> m) {
    if (m.containsKey('acp_session_id') || m.containsKey('acp_provider_id') || m.containsKey('input_tokens')) {
      _cardUpdateController.add(KanbanCard(
        id: _currentCardId ?? '', title: '', description: '', columnId: '', createdAt: '', updatedAt: '',
        acpSessionId: m['acp_session_id'], acpProviderId: m['acp_provider_id'],
        availableCommands: (m['available_commands'] as List?)?.cast<Map<String, dynamic>>(),
        inputTokens: m['input_tokens'] ?? 0, outputTokens: m['output_tokens'] ?? 0,
      ));
    }
    if (m['config_options'] != null) {
      _configController.add((m['config_options'] as List?)?.map((x) => ConfigOption.fromJson(x)).toList() ?? []);
    }
    if (m['available_commands'] != null) {
      _commandController.add((m['available_commands'] as List?)?.cast<Map<String, dynamic>>() ?? []);
    }
  }

  void dispose() {
    _currentCardId = null;
    disconnect();
  }

  void _clearCache() {
    _currentMessages = [];
    _eventBuffer.clear();
    _lastContiguousSeqId = 0;
    _hasLoadedHistory = false;
    _messageController.add([]);
    _planController.add(null);
    _configController.add([]);
    _commandController.add([]);
  }
}
