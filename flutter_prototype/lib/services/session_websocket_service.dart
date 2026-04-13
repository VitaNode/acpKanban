import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/config_option.dart';

class SessionWebSocketService {
  static final SessionWebSocketService _instance = SessionWebSocketService._internal();
  
  factory SessionWebSocketService() {
    return _instance;
  }

  SessionWebSocketService._internal();

  static const String _baseUrl = 'http://localhost:8000';

  WebSocketChannel? _channel;
  final _messageController = StreamController<List<CardMessage>>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  
  // Phase 5.2: New controllers for Plan and Config
  final _planController = StreamController<AgentPlan?>.broadcast();
  final _configController = StreamController<List<ConfigOption>>.broadcast();

  String? _currentCardId;
  bool _isConnected = false;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectCount = 0;
  static const int _maxReconnectAttempts = 5;

  Stream<List<CardMessage>> get messages => _messageController.stream;
  Stream<String> get status => _statusController.stream;
  Stream<AgentPlan?> get plan => _planController.stream;
  Stream<List<ConfigOption>> get configOptions => _configController.stream;
  
  bool get isConnected => _isConnected;

  Future<bool> connect(String cardId, {int retryCount = 0}) async {
    if (_channel != null && _currentCardId == cardId && _isConnected) {
      _statusController.add('connected');
      return true;
    }

    if (_currentCardId != cardId) {
      _messageController.add([]);
      _planController.add(null);
      _configController.add([]);
      _reconnectCount = 0;
    }

    await disconnect();
    _currentCardId = cardId;

    try {
      final uri = Uri.parse('${_baseUrl.replaceFirst('http', 'ws')}/ws/session/$cardId');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      _isConnected = true;
      _reconnectCount = 0;
      _statusController.add('connected');
      _startHeartbeat();

      _channel!.stream.listen(
        (data) => _handleMessage(data as String),
        onError: (e) {
          _isConnected = false;
          _statusController.add('error: $e');
          _reconnectIfNecessary();
        },
        onDone: () {
          _isConnected = false;
          _statusController.add('disconnected');
          _reconnectIfNecessary();
        },
      );
      await _requestHistory();
      return true;
    } catch (e) {
      _isConnected = false;
      _statusController.add('connection_failed: $e');
      if (retryCount < 3) {
        await Future.delayed(Duration(seconds: 2));
        return connect(cardId, retryCount: retryCount + 1);
      }
      return false;
    }
  }

  void _reconnectIfNecessary() {
    _reconnectTimer?.cancel();
    if (_currentCardId != null && _reconnectCount < _maxReconnectAttempts) {
      _reconnectCount++;
      _reconnectTimer = Timer(Duration(seconds: 5 * _reconnectCount), () {
        if (!_isConnected && _currentCardId != null) connect(_currentCardId!);
      });
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isConnected && _channel != null) {
        try { _channel!.sink.add(jsonEncode({'type': 'ping'})); } 
        catch (e) { _isConnected = false; _reconnectIfNecessary(); }
      }
    });
  }

  void _stopHeartbeat() { _heartbeatTimer?.cancel(); _heartbeatTimer = null; }

  Future<void> _requestHistory() async {
    if (_channel != null && _isConnected) {
      _channel?.sink.add(jsonEncode({'type': 'get_history'}));
    }
  }

  void _handleMessage(String data) {
    try {
      final message = jsonDecode(data) as Map<String, dynamic>;
      final type = message['type'];
      switch (type) {
        case 'history':
          final messages = (message['messages'] as List?)?.map((m) => CardMessage.fromJson(m)).toList() ?? [];
          _messageController.add(messages);
          break;
        case 'agent_plan':
          _planController.add(message['plan'] != null ? AgentPlan.fromJson(message['plan']) : null);
          break;
        case 'config_options':
          final options = (message['options'] as List?)?.map((o) => ConfigOption.fromJson(o)).toList() ?? [];
          _configController.add(options);
          break;
        case 'message_added':
        case 'refresh':
          _requestHistory();
          break;
      }
    } catch (e) {}
  }

  Future<void> setConfigOption(String name, String value) async {
    if (_channel == null || !_isConnected) return;
    _channel!.sink.add(jsonEncode({'type': 'set_config_option', 'name': name, 'value': value}));
  }

  Future<void> sendMessage(String role, String content, {Map<String, dynamic>? metadata}) async {
    if (_channel == null || !_isConnected) throw Exception('Not connected');
    _channel!.sink.add(jsonEncode({'type': 'send_message', 'role': role, 'content': content, 'metadata': metadata}));
  }

  Future<void> disconnect() async {
    _stopHeartbeat(); _reconnectTimer?.cancel();
    if (_channel != null) { await _channel!.sink.close(); _channel = null; }
    _isConnected = false;
  }

  void dispose() { _currentCardId = null; disconnect(); }
}
