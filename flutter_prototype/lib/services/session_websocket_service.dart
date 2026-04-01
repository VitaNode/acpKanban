import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/card_message.dart';

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

  String? _currentCardId;
  bool _isConnected = false;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectCount = 0;
  static const int _maxReconnectAttempts = 5;

  Stream<List<CardMessage>> get messages => _messageController.stream;
  Stream<String> get status => _statusController.stream;
  bool get isConnected => _isConnected;

  Future<bool> connect(String cardId, {int retryCount = 0}) async {
    // If already connecting to the same card, ignore
    if (_channel != null && _currentCardId == cardId && _isConnected) {
      _statusController.add('connected');
      return true;
    }

    // Clear old messages if switching cards
    if (_currentCardId != cardId) {
      _messageController.add([]);
      _reconnectCount = 0; // Reset count on manual switch
    }

    await disconnect();
    _currentCardId = cardId;

    try {
      final uri = Uri.parse(
          '${_baseUrl.replaceFirst('http', 'ws')}/ws/session/$cardId');
      _channel = WebSocketChannel.connect(uri);

      await _channel!.ready;
      _isConnected = true;
      _reconnectCount = 0; // Reset on success
      _statusController.add('connected');
      _startHeartbeat();

      _channel!.stream.listen(
        (data) => _handleMessage(data as String),
        onError: (error) {
          _isConnected = false;
          _statusController.add('error: $error');
          _stopHeartbeat();
          _reconnectIfNecessary();
        },
        onDone: () {
          _isConnected = false;
          _statusController.add('disconnected');
          _stopHeartbeat();
          _reconnectIfNecessary();
        },
      );

      await _requestHistory();
      return true;
    } catch (e) {
      _isConnected = false;
      _statusController.add('connection_failed: $e');
      
      // Initial connection retry (manual/first-time)
      if (retryCount < 3) {
        await Future.delayed(Duration(seconds: 2 * (retryCount + 1)));
        return connect(cardId, retryCount: retryCount + 1);
      }
      return false;
    }
  }

  void _reconnectIfNecessary() {
    _reconnectTimer?.cancel();
    if (_currentCardId != null && _reconnectCount < _maxReconnectAttempts) {
      _reconnectCount++;
      _statusController.add('reconnecting');
      _reconnectTimer = Timer(Duration(seconds: 5 * _reconnectCount), () {
        if (!_isConnected && _currentCardId != null) {
          connect(_currentCardId!);
        }
      });
    } else if (_reconnectCount >= _maxReconnectAttempts) {
      _statusController.add('max_reconnect_reached');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isConnected && _channel != null) {
        try {
          _channel!.sink.add(jsonEncode({'type': 'ping'}));
        } catch (e) {
          _isConnected = false;
          _statusController.add('disconnected');
          _stopHeartbeat();
          _reconnectIfNecessary();
        }
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _requestHistory() async {
    if (_channel != null && _isConnected) {
      _channel?.sink.add(jsonEncode({
        'type': 'get_history',
      }));
    }
  }

  void _handleMessage(String data) {
    try {
      final message = jsonDecode(data) as Map<String, dynamic>;
      final type = message['type'];

      switch (type) {
        case 'history':
          final messages = (message['messages'] as List?)
                  ?.map((m) => CardMessage.fromJson(m))
                  .toList() ??
              [];
          _messageController.add(messages);
          break;
        case 'message_added':
        case 'refresh':
          _requestHistory();
          break;
        case 'pong':
          // Heartbeat received
          break;
      }
    } catch (e) {
      // Ignore parse errors
    }
  }

  Future<void> sendMessage(String role, String content,
      {Map<String, dynamic>? metadata}) async {
    if (_channel == null || !_isConnected) {
      throw Exception('Not connected to WebSocket');
    }

    _channel!.sink.add(jsonEncode({
      'type': 'send_message',
      'role': role,
      'content': content,
      'metadata': metadata,
    }));
  }

  Future<void> disconnect() async {
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }
    _isConnected = false;
    _statusController.add('disconnected');
  }

  void dispose() {
    _currentCardId = null;
    disconnect();
  }
}
