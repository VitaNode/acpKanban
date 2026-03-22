import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'smart_connect.dart';
import 'e2ee_manager.dart';

enum ConnectionMode { local, relay, cloud, none }

class ACPConfig {
  final String? localIp;
  final String? relayHost;
  final String? userId;
  final String? relayToken;
  final String? e2eeKeyHex;
  final String? cloudDirectUrl;

  ACPConfig({
    this.localIp,
    this.relayHost = "relay.example.com",
    this.userId,
    this.relayToken,
    this.e2eeKeyHex,
    this.cloudDirectUrl,
  });

  String? get localUrl => localIp != null ? "ws://$localIp:8766" : null;
  String? get relayUrl => (relayHost != null && userId != null) 
      ? "ws://$relayHost:8766/relay/app/$userId" : null;
  String? get cloudUrl => cloudDirectUrl ?? (relayHost != null ? "ws://$relayHost:8766/direct" : null);
}

class ACPClient {
  WebSocketChannel? _channel;
  final _uuid = const Uuid();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  
  ConnectionMode activeMode = ConnectionMode.none;
  String? activeUrl;
  E2EEManager? _e2ee;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;

  ACPClient();

  Future<void> smartConnect(ACPConfig config) async {
    if (config.e2eeKeyHex != null) {
      _e2ee = E2EEManager(config.e2eeKeyHex!);
    }

    print('[ACP] Scanning local network via mDNS...');
    final discoveredIp = await SmartConnect.discoverLocalMac(config.userId ?? "default");
    final targetLocalIp = discoveredIp ?? config.localIp;
    
    if (targetLocalIp != null) {
      final url = "ws://$targetLocalIp:8766";
      if (await _tryConnect(url, ConnectionMode.local, timeout: 2)) return;
    }

    if (config.relayUrl != null) {
      if (await _tryConnect(config.relayUrl!, ConnectionMode.relay, 
          timeout: 5, token: config.relayToken)) return;
    }

    if (config.cloudUrl != null) {
      if (await _tryConnect(config.cloudUrl!, ConnectionMode.cloud, 
          timeout: 10, token: config.relayToken)) return;
    }

    throw Exception('All connection paths failed.');
  }

  Future<bool> _tryConnect(String url, ConnectionMode mode, {int timeout = 5, String? token}) async {
    try {
      final uri = Uri.parse(url);
      final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};

      // IOWebSocketChannel supports headers
      _channel = IOWebSocketChannel.connect(uri, headers: headers);
      
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
        Map<String, dynamic> data = jsonDecode(message);
        if (_e2ee != null) {
          data = _e2ee!.unwrap(data);
        }

        if (data.containsKey('id')) {
          final id = data['id'].toString();
          if (_pendingRequests.containsKey(id)) {
            _pendingRequests[id]!.complete(data);
            _pendingRequests.remove(id);
          }
        }
        _messageController.add(jsonEncode(data));
      },
      onError: (error) {
        print('[ACP] WebSocket Error: $error');
        activeMode = ConnectionMode.none;
      },
      onDone: () {
        activeMode = ConnectionMode.none;
      },
    );
  }

  Future<Map<String, dynamic>> sendRequest(String method, [Map<String, dynamic>? params]) async {
    if (_channel == null) throw Exception('Not connected');

    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    Map<String, dynamic> requestObj = {
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params ?? {}
    };

    dynamic payload;
    if (_e2ee != null) {
      payload = jsonEncode(_e2ee!.wrap(requestObj));
    } else {
      payload = jsonEncode(requestObj);
    }

    try {
      _channel!.sink.add(payload);
    } catch (e) {
      _pendingRequests.remove(id);
      completer.completeError(e);
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException('Request $method timed out');
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
      if (result is Map && result.containsKey('message')) return result['message'];
      return result.toString();
    } else if (response.containsKey('error')) {
      throw Exception(response['error']['message'] ?? 'Unknown AI Error');
    }
    throw Exception('Unknown response format');
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
    activeMode = ConnectionMode.none;
    _e2ee = null;
  }
}
