import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

class ACPClient {
  final String url;
  WebSocketChannel? _channel;
  final _uuid = Uuid();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  bool _isReconnecting = false;
  
  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;

  ACPClient(this.url);

  Future<void> connect() async {
    await _connectWithRetry();
  }

  // Issue 3: Reconnection with exponential backoff
  Future<void> _connectWithRetry() async {
    int retries = 3;
    for (int i = 0; i < retries; i++) {
      try {
        print('[ACP] Attempting connection to $url (Try ${i + 1})');
        _channel = WebSocketChannel.connect(Uri.parse(url));
        await _channel!.ready;
        _setupStream();
        _isReconnecting = false;
        print('[ACP] Connected successfully.');
        return;
      } catch (e) {
        if (i == retries - 1) {
          print('[ACP] Failed to connect after $retries retries.');
          rethrow;
        }
        await Future.delayed(Duration(seconds: 2 * (i + 1)));
      }
    }
  }

  void _setupStream() {
    _channel!.stream.listen(
      (message) {
        print('[ACP] Received: $message');
        final data = jsonDecode(message);
        if (data.containsKey('id')) {
          final id = data['id'].toString();
          if (_pendingRequests.containsKey(id)) {
            _pendingRequests[id]!.complete(data);
            _pendingRequests.remove(id);
          }
        }
      },
      onError: (error) async {
        print('[ACP] WebSocket Error: $error');
        await _handleReconnect();
      },
      onDone: () async {
        print('[ACP] WebSocket Done (Disconnected)');
        await _handleReconnect();
      },
    );
  }

  Future<void> _handleReconnect() async {
    if (!_isReconnecting) {
      _isReconnecting = true;
      await Future.delayed(Duration(seconds: 5));
      try {
        await _connectWithRetry();
      } catch (e) {
        _isReconnecting = false;
      }
    }
  }

  // Issue 1, 2, 5: State check, timeout, logging
  Future<Map<String, dynamic>> sendRequest(String method, [Map<String, dynamic>? params]) async {
    if (_channel == null || _channel!.closeCode != null) {
      throw Exception('[ACP] Not connected. Cannot send $method.');
    }

    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final request = {
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params ?? {}
    };

    print('[ACP] --> Request: $method (id: $id)');
    
    try {
      _channel!.sink.add(jsonEncode(request));
    } catch (e) {
      _pendingRequests.remove(id);
      completer.completeError(e);
      rethrow;
    }

    // Issue 2: 30-second timeout
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
        print('[ACP] Request $id timed out.');
        throw TimeoutException('[ACP] Request $id timed out after 30s');
      },
    );
  }

  Future<void> initialize() async {
    await sendRequest('initialize', {
      'clientInfo': {'name': 'KanbanMobile', 'version': '1.3.0'}
    });
  }

  Future<String> sendMessage(String message) async {
    final response = await sendRequest('chat/message', {'message': message});
    if (response.containsKey('result')) {
      return response['result']['message'];
    } else {
      throw Exception(response['error']['message'] ?? 'Unknown Error');
    }
  }

  // Issue 4: Cleanup resources
  void disconnect() {
    for (final completer in _pendingRequests.values) {
      completer.completeError(Exception('Connection manually closed.'));
    }
    _pendingRequests.clear();
    _messageController.close();
    _channel?.sink.close();
  }
}
