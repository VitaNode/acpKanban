import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/config_option.dart';
import '../models/kanban_card.dart';

class SessionWebSocketService {
  static final SessionWebSocketService _instance =
      SessionWebSocketService._internal();
  factory SessionWebSocketService() => _instance;
  SessionWebSocketService._internal();

  static const String _baseUrl = 'http://localhost:8000';
  WebSocketChannel? _channel;
  final _messageController = StreamController<List<CardMessage>>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _planController = StreamController<AgentPlan?>.broadcast();
  final _configController = StreamController<List<ConfigOption>>.broadcast();
  final _commandController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _requestController = StreamController<Map<String, dynamic>>.broadcast();
  final _cardUpdateController = StreamController<KanbanCard>.broadcast();

  String? _currentCardId;
  bool _isConnected = false;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectCount = 0;

  // Local cache to support streaming updates
  List<CardMessage> _currentMessages = [];

  Stream<List<CardMessage>> get messages => _messageController.stream;
  Stream<String> get status => _statusController.stream;
  Stream<AgentPlan?> get plan => _planController.stream;
  Stream<List<ConfigOption>> get configOptions => _configController.stream;
  Stream<List<Map<String, dynamic>>> get availableCommands =>
      _commandController.stream;
  Stream<Map<String, dynamic>> get requests => _requestController.stream;
  Stream<KanbanCard> get cardUpdates => _cardUpdateController.stream;
  bool get isConnected => _isConnected;

  Future<bool> connect(String cardId, {int retryCount = 0}) async {
    // 如果是不同卡片，先断开旧连接，避免竞态条件
    if (_currentCardId != null && _currentCardId != cardId) {
      await disconnect();
    }

    // 同一张卡片且连接正常 → 重新请求历史（支持重入）
    if (_channel != null && _currentCardId == cardId && _isConnected) {
      await _requestHistory();
      return true;
    }

    _currentCardId = cardId;
    _currentMessages = [];
    _messageController.add([]);
    _planController.add(null);
    _configController.add([]);
    _commandController.add([]);
    _reconnectCount = 0;
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
        await Future.delayed(Duration(seconds: 2));
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
    if (_channel != null && _isConnected)
      _channel?.sink.add(jsonEncode({'type': 'get_history'}));
  }

  void _handleMessage(dynamic data) {
    try {
      Map<String, dynamic> m;
      if (data is String) {
        m = jsonDecode(data) as Map<String, dynamic>;
      } else if (data is Map<String, dynamic>) {
        m = data;
      } else {
        print('WS: Unexpected message type: ${data.runtimeType}');
        return;
      }
      if (m['method'] != null && m['id'] != null) {
        _requestController.add(m);
        return;
      }
      switch (m['type']) {
        case 'history':
          _currentMessages = (m['messages'] as List?)
                  ?.map((x) => CardMessage.fromJson(x))
                  .toList() ??
              [];
          _messageController.add(_currentMessages);
          // Also handle config_options embedded in history response
          if (m['config_options'] != null) {
            _configController.add((m['config_options'] as List?)
                    ?.map((x) => ConfigOption.fromJson(x))
                    .toList() ??
                []);
          }
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
      }
    } catch (e) {
      print('WS Parse Error: $e');
    }
  }

  Future<void> setConfigOption(String configId, String value) async {
    if (_channel != null && _isConnected)
      _channel!.sink.add(jsonEncode(
          {'type': 'set_config_option', 'name': configId, 'value': value}));
  }

  Future<void> sendMessage(String role, String content) async {
    if (_channel == null || !_isConnected) throw Exception('Not connected');
    _channel!.sink.add(
        jsonEncode({'type': 'send_message', 'role': role, 'content': content}));
  }

  Future<void> sendResponse(String id, Map<String, dynamic> result) async {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(
          jsonEncode({'type': 'rpc_response', 'id': id, 'result': result}));
    }
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    // Immediately reset state to avoid race conditions when reconnecting
    final channel = _channel;
    _channel = null;
    _isConnected = false;
    if (channel != null) {
      await channel.sink.close();
    }
  }

  void dispose() {
    _currentCardId = null;
    disconnect();
  }
}
