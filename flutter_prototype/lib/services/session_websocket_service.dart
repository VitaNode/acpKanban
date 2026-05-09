import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/config_option.dart';
import '../models/kanban_card.dart';
import '../models/ag_ui_event.dart';
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

  Future<bool> connect(String cardId, {int retryCount = 0}) async {
    // 如果是不同卡片，先断开旧连接，避免竞态条件
    if (_currentCardId != null && _currentCardId != cardId) {
      await disconnect();
    }

    // 同一张卡片且连接正常 → 重新请求历史（支持重入）
    if ((_channel != null || (_useProxy && _isConnected)) && _currentCardId == cardId && _isConnected) {
      await _requestHistory();
      return true;
    }

    _currentCardId = cardId;
    _currentMessages = [];
    _eventBuffer.clear();
    _lastContiguousSeqId = 0;
    _messageController.add([]);
    _planController.add(null);
    _configController.add([]);
    _commandController.add([]);
    _reconnectCount = 0;

    if (_useProxy) {
      debugPrint('[SessionWS] Using ACP Proxy for card $cardId');
      try {
        await _acpClient.waitForReady;
        final response = await _acpClient.sendRequest('session/ws_proxy', {
          'action': 'connect',
          'card_id': cardId,
        });
        
        if (response.containsKey('result')) {
          _isConnected = true;
          _reconnectCount = 0;
          
          // Listen to ACP notifications
          _acpSub?.cancel();
          _acpSub = _acpClient.messages.listen((msgStr) {
            try {
              final msg = jsonDecode(msgStr);
              if (msg['method'] == 'session/ws_event' && msg['params']?['card_id'] == _currentCardId) {
                _handleMessage(msg['params']['payload']);
              }
            } catch (e) {
              debugPrint('[SessionWS] ACP Msg Error: $e');
            }
          });
          
          await _requestHistory();
          return true;
        } else {
          debugPrint('[SessionWS] Proxy connect failed: ${response['error']}');
          return false;
        }
      } catch (e) {
        debugPrint('[SessionWS] Proxy connect error: $e');
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
    if (_useProxy) return; // ACP Proxy handles reconnection via SmartConnect
    _reconnectTimer?.cancel();
    if (_currentCardId != null && _reconnectCount < 5) {
      _reconnectCount++;
      _reconnectTimer = Timer(Duration(seconds: 5 * _reconnectCount), () {
        if (!_isConnected && _currentCardId != null) connect(_currentCardId!);
      });
    }
  }

  void _startHeartbeat() {
    if (_useProxy) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      if (_isConnected && _channel != null) {
        try {
          _channel!.sink.add(jsonEncode({'type': 'ping'}));
        } catch (e) {
          _isConnected = false;
        }
      }
    });
  }

  Future<void> _requestHistory() async {
    // If we have already received some messages, request history from the last contiguous seqId
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
        debugPrint('[SessionWS] Proxy send error: $e');
      }
    } else if (_channel != null) {
      _channel!.sink.add(data is String ? data : jsonEncode(data));
    }
  }

  List<CardMessage> _mergeMessages(List<CardMessage> messages) {
    if (messages.isEmpty) return [];
    
    List<CardMessage> merged = [];
    CardMessage? current = messages[0];
    
    for (int i = 1; i < messages.length; i++) {
      final next = messages[i];
      
      if (current != null && 
          current.role == 'assistant' && 
          next.role == 'assistant' && 
          (!current.isComplete || !next.isComplete)) {
        
        // Merge next into current
        current = current.copyWith(
          content: current.content + next.content,
          isComplete: next.isComplete,
          metadata: next.metadata != null ? next.metadata : current.metadata,
        );
      } else {
        merged.add(current!);
        current = next;
      }
    }
    merged.add(current!);
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
        if (kDebugMode) print(errorMsg);
        _errorController.add(errorMsg);
        return;
      }
      if (m['method'] != null && m['id'] != null) {
        _requestController.add(m);
        return;
      }
      // Handle AG-UI events (when ui_format is 'ag_ui')
      if (m['type'] == 'ag_ui_event') {
        final agUiEvent = AgUiEvent.fromMessage(CardMessage(
          id: '',
          cardId: _currentCardId ?? '',
          role: 'assistant',
          content: jsonEncode(m),
          createdAt: '',
        ));

        // Buffer the event by its seqId if present
        if (agUiEvent.seqId != null) {
          _eventBuffer[agUiEvent.seqId!] = agUiEvent;
          
          // Try to deliver any contiguous events we now have
          _tryDeliverBufferedEvents();
        } else {
          // No seqId, deliver immediately (e.g., heartbeat, session info)
          _deliverAgUiEvent(agUiEvent);
        }
        return; // Important: don't fall through to other handlers
      }

      switch (m['type']) {
        case 'history':
          final newMessages = (m['messages'] as List?)
                  ?.map((x) => CardMessage.fromJson(x))
                  .toList() ??
              [];
          
          // If we requested a delta update (after_seq > 0) and got no new messages,
          // just update the card/config info and keep existing messages.
          if (newMessages.isEmpty && _lastContiguousSeqId > 0) {
            _updateCardAndConfig(m);
            return;
          }

          if (_lastContiguousSeqId == 0) {
            // Full sync or first load
            _currentMessages = _mergeMessages(newMessages);
          } else {
            // Merge delta update
            for (var msg in newMessages) {
              final index = _currentMessages.indexWhere((existing) => 
                (existing.id == msg.id && msg.id.isNotEmpty && !msg.id.startsWith('streaming-') && !msg.id.startsWith('thought-')) || 
                (existing.seqId == msg.seqId && msg.seqId != null)
              );
              
              if (index != -1) {
                // Update existing message (e.g., from streaming to complete)
                _currentMessages[index] = msg;
              } else {
                // Add new message and keep sorted by seqId
                _currentMessages.add(msg);
              }
            }
            // Sort by seqId or fallback to created_at
            _currentMessages.sort((a, b) {
              if (a.seqId != null && b.seqId != null) return a.seqId!.compareTo(b.seqId!);
              return a.createdAt.compareTo(b.createdAt);
            });
            
            // After merging delta, we should also ensure the final list is merged
            _currentMessages = _mergeMessages(_currentMessages);
          }
          
          // Update _lastContiguousSeqId based on the highest seqId in history
          for (var msg in _currentMessages) {
            if (msg.seqId != null && msg.seqId! > _lastContiguousSeqId) {
              _lastContiguousSeqId = msg.seqId!;
            }
          }
          
          _messageController.add(List.from(_currentMessages));
          _updateCardAndConfig(m);
          break;
        case 'agent_plan':
          _planController
              .add(m['plan'] != null ? AgentPlan.fromJson(m['plan']) : null);
          break;
        case 'config_options':
          _configController.add((m['options'] as List?)
                  ?.map((x) => ConfigOption.fromJson(x))
                  .toList() ??
              []);
          break;
        case 'available_commands':
          _commandController.add(
              (m['commands'] as List?)?.cast<Map<String, dynamic>>() ?? []);
          break;
        case 'agent_message_chunk':
          final chunk = m['content']?['text'] ?? '';
          if (m['_meta'] != null || m['usage'] != null) {
            _requestHistory(); // Refresh to get cumulative tokens from DB
          }
          if (chunk.isNotEmpty) {
            if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && !_currentMessages.last.isComplete) {
              final last = _currentMessages.last;
              _currentMessages[_currentMessages.length - 1] = last.copyWith(
                content: last.content + chunk
              );
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
          if (m['_meta'] != null || m['usage'] != null) {
            _requestHistory(); // Refresh to get cumulative tokens from DB
          }
          if (thought.isNotEmpty) {
             if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant' && !_currentMessages.last.isComplete) {
              final last = _currentMessages.last;
              final metadata = Map<String, dynamic>.from(last.metadata ?? {});
              metadata['thought'] = (metadata['thought'] ?? '') + thought;
              _currentMessages[_currentMessages.length - 1] = last.copyWith(
                metadata: metadata
              );
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
          _requestHistory(); // Re-fetch to get updated metadata for tool status
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
          if (m['config_options'] != null) {
            _configController.add((m['config_options'] as List?)
                    ?.map((x) => ConfigOption.fromJson(x))
                    .toList() ??
                []);
          }
          // Also emit card update with new session ID so the UI can set _isAgentConnected
          if (m['sessionId'] != null) {
            _cardUpdateController.add(KanbanCard(
              id: _currentCardId ?? '',
              title: '',
              description: '',
              columnId: '',
              createdAt: '',
              updatedAt: '',
              acpSessionId: m['sessionId'],
              acpProviderId: null,
            ));
            // Auto-fetch context after session is ready
            getContext();
          }
          break;
        case 'context_data':
          if (m['context'] != null) {
            _contextController.add(m['context']);
          }
          break;
        case 'token_update':
          _cardUpdateController.add(KanbanCard(
            id: _currentCardId ?? '',
            title: '',
            description: '',
            columnId: '',
            createdAt: '',
            updatedAt: '',
            inputTokens: m['input_tokens'] ?? 0,
            outputTokens: m['output_tokens'] ?? 0,
          ));
          break;
        case 'error':
          _initializingController.add(false);
          _errorController.add(m['message'] ?? 'Unknown agent error');
          break;
      }
    } catch (e) {
      _initializingController.add(false);
      if (kDebugMode) print('WS Parse Error: $e');
      _errorController.add('Failed to process message: $e');
    }
  }

  void _deliverAgUiEvent(AgUiEvent event) {
    // Convert AgUiEvent back to CardMessage for UI consumption
    // This maintains compatibility with existing UI while enabling AG-UI features
    final Map<String, dynamic> agEventMap = {};
    if (event.eventType != null) agEventMap['event'] = event.eventType;
    if (event.text != null) agEventMap['text'] = event.text;
    if (event.reasoning != null) agEventMap['reasoning'] = event.reasoning;
    if (event.seqId != null) agEventMap['seqId'] = event.seqId;
    if (event.isComplete != null) agEventMap['is_complete'] = event.isComplete;
    if (event.sessionId != null) agEventMap['session_id'] = event.sessionId;
    if (event.toolCalls != null) {
      agEventMap['tool_calls'] = event.toolCalls!.map((tc) => {
        'tool_id': tc.toolId,
        'name': tc.name,
        'status': tc.status,
        'args': tc.args,
        'result': tc.result,
      }).toList();
    }

    final agUiMessage = CardMessage(
      id: '${DateTime.now().millisecondsSinceEpoch}-${event.seqId ?? 0}',
      cardId: _currentCardId ?? '',
      role: 'assistant',
      content: jsonEncode(agEventMap),
      createdAt: DateTime.now().toIso8601String(),
      isComplete: event.isComplete ?? false,
      seqId: event.seqId,
    );

    // Handle different event types for UI rendering
    if ((event.eventType == 'agent_message_chunk' || event.eventType == 'message_chunk') && event.text != null) {
      final chunk = event.text!;
      if (_currentMessages.isNotEmpty && 
          _currentMessages.last.role == 'assistant' && 
          !_currentMessages.last.isComplete) {
        final last = _currentMessages.last;
        _currentMessages[_currentMessages.length - 1] = last.copyWith(
          content: last.content + chunk,
          seqId: event.seqId,
        );
      } else {
        _currentMessages.add(CardMessage(
          id: 'streaming-${DateTime.now().millisecondsSinceEpoch}-${event.seqId ?? 0}',
          cardId: _currentCardId ?? '',
          role: 'assistant',
          content: chunk,
          createdAt: DateTime.now().toIso8601String(),
          isComplete: false,
          seqId: event.seqId,
        ));
      }
      _messageController.add(List.from(_currentMessages));
    } 
    else if (event.eventType == 'agent_thought_chunk' && event.text != null) {
      final thought = event.text!;
      if (_currentMessages.isNotEmpty && 
          _currentMessages.last.role == 'assistant' && 
          !_currentMessages.last.isComplete) {
        final last = _currentMessages.last;
        final metadata = Map<String, dynamic>.from(last.metadata ?? {});
        metadata['thought'] = (metadata['thought'] ?? '') + thought;
        _currentMessages[_currentMessages.length - 1] = last.copyWith(
          metadata: metadata,
          seqId: event.seqId,
        );
      } else {
        _currentMessages.add(CardMessage(
          id: 'thought-${DateTime.now().millisecondsSinceEpoch}-${event.seqId ?? 0}',
          cardId: _currentCardId ?? '',
          role: 'assistant',
          content: '',
          createdAt: DateTime.now().toIso8601String(),
          isComplete: false,
          metadata: {'thought': thought},
          seqId: event.seqId,
        ));
      }
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'tool_call_start' || event.eventType == 'tool_call_update' || event.eventType == 'tool_call_result') {
      // Handle tool call events by updating existing message or adding a new one
      final toolCall = event.toolCalls?.isNotEmpty == true ? event.toolCalls!.first : null;
      if (toolCall == null) return;

      final toolId = toolCall.toolId;
      final toolName = toolCall.name ?? 'Unknown';
      final toolStatus = _mapToolStatus(toolCall.status ?? 'running');
      
      // Try to find an existing tool message with the same toolId
      int existingIndex = _currentMessages.indexWhere((m) => 
        m.role == 'tool' && m.metadata?['tool_id'] == toolId
      );

      if (existingIndex != -1) {
        // Update existing tool message
        final existing = _currentMessages[existingIndex];
        final updatedMetadata = Map<String, dynamic>.from(existing.metadata ?? {});
        
        // Update name if it was previously 'Unknown' and we now have a name
        if (updatedMetadata['name'] == 'Unknown' && toolName != 'Unknown') {
          updatedMetadata['name'] = toolName;
        }
        updatedMetadata['status'] = toolStatus;
        
        // Update arguments if provided
        if (toolCall.args != null && toolCall.args!.isNotEmpty) {
          updatedMetadata['arguments'] = toolCall.args;
        }
        
        // Use the newest result if available
        String content = existing.content;
        if (toolCall.result != null && toolCall.result!.isNotEmpty) {
          content = toolCall.result!;
        }

        _currentMessages[existingIndex] = existing.copyWith(
          content: content,
          isComplete: event.eventType == 'tool_call_result',
          metadata: updatedMetadata,
        );
      } else {
        // Create a new tool message
        _currentMessages.add(CardMessage(
          id: 'tool-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}',
          cardId: _currentCardId ?? '',
          role: 'tool',
          content: toolCall.result ?? '',
          createdAt: DateTime.now().toIso8601String(),
          isComplete: event.eventType == 'tool_call_result',
          seqId: event.seqId,
          metadata: {
            'name': toolName,
            'status': toolStatus,
            'arguments': toolCall.args ?? '',
            'tool_id': toolId,
          }
        ));
      }
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'message_bundled' || event.eventType == 'message_chunk') {
      // Handle bundled messages (with reasoning and tool calls)
      final text = event.text ?? '';
      final reasoning = event.reasoning;
      
      final metadata = <String, dynamic>{};
      if (reasoning != null && reasoning.isNotEmpty) {
        metadata['thought'] = reasoning;
      }
      if (event.toolCalls != null && event.toolCalls!.isNotEmpty) {
        metadata['tool_calls'] = event.toolCalls!.map((tc) => {
          'tool_id': tc.toolId,
          'name': tc.name,
          'status': tc.status,
          'args': tc.args,
          'result': tc.result,
        }).toList();
      }
      
      _currentMessages.add(CardMessage(
        id: 'bundled-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}',
        cardId: _currentCardId ?? '',
        role: 'assistant',
        content: text,
        createdAt: DateTime.now().toIso8601String(),
        isComplete: event.isComplete ?? true,
        seqId: event.seqId,
        metadata: metadata.isNotEmpty ? metadata : null
      ));
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'user_message') {
      // Handle user messages echoed back from the server
      _currentMessages.add(CardMessage(
        id: 'user-${event.seqId ?? 0}-${DateTime.now().millisecondsSinceEpoch}',
        cardId: _currentCardId ?? '',
        role: 'user',
        content: event.text ?? '',
        createdAt: DateTime.now().toIso8601String(),
        isComplete: true,
        seqId: event.seqId,
      ));
      _messageController.add(List.from(_currentMessages));
    }
    else if (event.eventType == 'plan_update') {
      // Handle plan updates by extracting steps
      try {
        final rawMap = jsonDecode(agUiMessage.content);
        _planController.add(AgentPlan.fromJson(rawMap));
      } catch (e) {
        debugPrint('[SessionWS] Plan Update Error: $e');
      }
    }
    else if (event.eventType == 'config_update') {
      // Handle config updates
      try {
        final rawMap = jsonDecode(agUiMessage.content);
        final options = rawMap['options'] as List?;
        if (options != null) {
          _configController.add(options.map((o) => ConfigOption.fromJson(o as Map<String, dynamic>)).toList());
        }
      } catch (e) {
        debugPrint('[SessionWS] Config Update Error: $e');
      }
    }
    else if (event.eventType == 'commands_update') {
      // Handle commands updates
      try {
        final rawMap = jsonDecode(agUiMessage.content);
        final commands = rawMap['commands'] as List?;
        if (commands != null) {
          _commandController.add(commands.map((c) => c as Map<String, dynamic>).toList());
        }
      } catch (e) {
        debugPrint('[SessionWS] Commands Update Error: $e');
      }
    }
    else if (event.eventType == 'session_stop' || event.eventType == 'stop') {
      if (_currentMessages.isNotEmpty && _currentMessages.last.role == 'assistant') {
        _currentMessages[_currentMessages.length - 1] = _currentMessages.last.copyWith(isComplete: true);
        _messageController.add(List.from(_currentMessages));
      }
    }
    else {
      // If it's a known non-message event, ignore it to avoid leaking raw JSON
      final ignoreEvents = ['heartbeat', 'session_info', 'context_data'];
      if (event.eventType != null && ignoreEvents.contains(event.eventType)) {
        return;
      }
      
      // For unknown event types, only add if it looks like a message
      if (event.text != null && event.text!.isNotEmpty) {
        _currentMessages.add(agUiMessage);
        _messageController.add(List.from(_currentMessages));
      }
    }
  }

  String _mapToolStatus(String backendStatus) {
    // Map backend status (pending/completed/failed) to frontend status (running/success/failed)
    switch (backendStatus) {
      case 'pending':
      case 'running':
        return 'running';
      case 'completed':
      case 'success':
        return 'success';
      case 'failed':
      case 'cancelled':
      case 'error':
        return 'failed';
      default:
        return 'running';
    }
  }

  void _tryDeliverBufferedEvents() {
    // Prevent memory leaks: if buffer grows too large due to missing seqIds, clear it
    if (_eventBuffer.length > 100) {
      debugPrint("[AG-UI] Event buffer exceeded limit (100). Possible dropped packet at seqId ${_lastContiguousSeqId + 1}. Clearing buffer.");
      _eventBuffer.clear();
      // Optionally we could try to jump to the next available seqId, 
      // but clearing is safer to maintain consistency.
      return;
    }

    // Continuously deliver events from buffer as long as we have the next seqId
    while (_eventBuffer.containsKey(_lastContiguousSeqId + 1)) {
      final nextSeqId = _lastContiguousSeqId + 1;
      final event = _eventBuffer.remove(nextSeqId)!;
      _lastContiguousSeqId = nextSeqId;
      
      _deliverAgUiEvent(event);
      
      // If this event marks completion, we can consider the message complete
      if (event.isComplete == true) {
        // Optionally reset buffer if we want to start fresh for next message
        // But we keep buffering to handle potential overlaps
      }
    }
  }

  Future<void> sendInit() async {
    if (_isConnected) {
      _initializingController.add(true);
      await _send({
        'type': 'session_init',
        'ui_format': 'ag_ui',
      });
    }
  }

  Future<void> getContext() async {
    if (_isConnected) {
      await _send({'type': 'get_context'});
    }
  }

  Future<void> setConfigOption(String configId, String value) async {
    if (_isConnected) {
      await _send(
          {'type': 'set_config_option', 'name': configId, 'value': value});
    }
  }

  Future<void> sendMessage(String role, String content) async {
    if (!_isConnected) throw Exception('Not connected');
    await _send(
        {'type': 'send_message', 'role': role, 'content': content, 'ui_format': 'ag_ui'});
  }

  Future<void> sendResponse(String id, Map<String, dynamic> result) async {
    if (_isConnected) {
      await _send(
          {'type': 'rpc_response', 'id': id, 'result': result});
    }
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _acpSub?.cancel();
    _acpSub = null;
    
    if (_useProxy && _currentCardId != null && _isConnected) {
      try {
        await _acpClient.sendRequest('session/ws_proxy', {
          'action': 'disconnect',
          'card_id': _currentCardId,
        });
      } catch (e) {
        debugPrint('[SessionWS] Proxy disconnect error: $e');
      }
    }

    // Immediately reset state to avoid race conditions when reconnecting
    final channel = _channel;
    _channel = null;
    _isConnected = false;
    if (channel != null) {
      await channel.sink.close();
    }
  }

  void _updateCardAndConfig(Map<String, dynamic> m) {
    // Emit card update if session/provider/tokens info is included
    if (m.containsKey('acp_session_id') || m.containsKey('acp_provider_id') || m.containsKey('input_tokens')) {
      _cardUpdateController.add(KanbanCard(
        id: _currentCardId ?? '',
        title: '', // Not used by CardDetailView listener for this case
        description: '',
        columnId: '',
        createdAt: '',
        updatedAt: '',
        acpSessionId: m['acp_session_id'],
        acpProviderId: m['acp_provider_id'],
        availableCommands: (m['available_commands'] as List?)?.cast<Map<String, dynamic>>(),
        inputTokens: m['input_tokens'] ?? 0,
        outputTokens: m['output_tokens'] ?? 0,
      ));
    }

    // Also handle config_options embedded in history response
    if (m['config_options'] != null) {
      _configController.add((m['config_options'] as List?)
              ?.map((x) => ConfigOption.fromJson(x))
              .toList() ??
          []);
    }
    // Also handle available_commands embedded in history response
    if (m['available_commands'] != null) {
      _commandController.add((m['available_commands'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          []);
    }
  }

  void dispose() {
    _currentCardId = null;
    disconnect();
  }
}
