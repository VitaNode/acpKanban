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

  Stream<List<CardMessage>> get messages => _messageController.stream;
  Stream<String> get status => _statusController.stream;
  bool get isConnected => _isConnected;

  Future<bool> connect(String cardId, {int retryCount = 0}) async {
    if (_channel != null && _currentCardId == cardId && _isConnected) {
      _statusController.add('connected');
      return true;
    }

    await disconnect();
    _currentCardId = cardId;

    try {
      final uri = Uri.parse(
          '${_baseUrl.replaceFirst('http', 'ws')}/ws/session/$cardId');
      _channel = WebSocketChannel.connect(uri);

      await _channel!.ready;
      _isConnected = true;
      _statusController.add('connected');
      _startHeartbeat();

      _channel!.stream.listen(
        (data) => _handleMessage(data as String),
        onError: (error) {
          _isConnected = false;
          _statusController.add('error: $error');
          _stopHeartbeat();
        },
        onDone: () {
          _isConnected = false;
          _statusController.add('disconnected');
          _stopHeartbeat();
        },
      );

      await _requestHistory();
      return true;
    } catch (e) {
      _isConnected = false;
      _statusController.add('connection_failed: $e');
      
      if (retryCount < 3) {
        await Future.delayed(Duration(seconds: 2 * (retryCount + 1)));
        return connect(cardId, retryCount: retryCount + 1);
      }
      return false;
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
    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }
    _currentCardId = null;
    _isConnected = false;
    _statusController.add('disconnected');
  }

  void dispose() {
    disconnect();
  }
}
