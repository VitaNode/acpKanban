import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

enum ConnectionMode { local, relay, cloud, none }

class ACPConfig {
  final String? localIp;
  final String? relayHost;
  final String? userId;
  final String? cloudDirectUrl;

  ACPConfig({
    this.localIp,
    this.relayHost = "relay.example.com",
    this.userId,
    this.cloudDirectUrl,
  });

  String? get localUrl => localIp != null ? "ws://$localIp:8766" : null;
  String? get relayUrl => (relayHost != null && userId != null) 
      ? "ws://$relayHost:8766/relay/app/$userId" : null;
  String? get cloudUrl => cloudDirectUrl ?? (relayHost != null ? "ws://$relayHost:8766/direct" : null);
}

class ACPClient {
  WebSocketChannel? _channel;
  final _uuid = Uuid();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  
  ConnectionMode activeMode = ConnectionMode.none;
  String? activeUrl;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;

  ACPClient();

  /// The entry point for the three-level fallback connection strategy.
  Future<void> smartConnect(ACPConfig config) async {
    // 1. Try Local Path
    if (config.localUrl != null) {
      print('[ACP] Attempting Local Path: ${config.localUrl}');
      if (await _tryConnect(config.localUrl!, ConnectionMode.local, timeout: 2)) return;
    }

    // 2. Try Relay Path
    if (config.relayUrl != null) {
      print('[ACP] Attempting Relay Path: ${config.relayUrl}');
      if (await _tryConnect(config.relayUrl!, ConnectionMode.relay, timeout: 5)) return;
    }

    // 3. Try Cloud Direct Path
    if (config.cloudUrl != null) {
      print('[ACP] Attempting Cloud Direct Path: ${config.cloudUrl}');
      if (await _tryConnect(config.cloudUrl!, ConnectionMode.cloud, timeout: 10)) return;
    }

    throw Exception('All connection paths failed.');
  }

  Future<bool> _tryConnect(String url, ConnectionMode mode, {int timeout = 5}) async {
    try {
      final uri = Uri.parse(url);
      _channel = WebSocketChannel.connect(uri);
      
      // Wait for the connection to be ready with a timeout
      await _channel!.ready.timeout(Duration(seconds: timeout));
      
      activeMode = mode;
      activeUrl = url;
      _setupStream();
      print('[ACP] Connected via $mode to $url');
      return true;
    } catch (e) {
      print('[ACP] Connection to $url failed: $e');
      _channel = null;
      return false;
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
        _messageController.add(message);
      },
      onError: (error) {
        print('[ACP] WebSocket Error: $error');
        activeMode = ConnectionMode.none;
      },
      onDone: () {
        print('[ACP] WebSocket Disconnected');
        activeMode = ConnectionMode.none;
      },
    );
  }

  Future<Map<String, dynamic>> sendRequest(String method, [Map<String, dynamic>? params]) async {
    if (_channel == null) {
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

    try {
      _channel!.sink.add(jsonEncode(request));
    } catch (e) {
      _pendingRequests.remove(id);
      completer.completeError(e);
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
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
      final result = response['result'];
      if (result is Map && result.containsKey('message')) {
        return result['message'];
      }
      return result.toString();
    } else if (response.containsKey('error')) {
      throw Exception(response['error']['message'] ?? 'Unknown Error');
    }
    throw Exception('Unexpected response format');
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
    activeMode = ConnectionMode.none;
  }
}
