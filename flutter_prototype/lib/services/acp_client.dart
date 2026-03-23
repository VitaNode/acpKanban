import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'smart_connect.dart';
import 'e2ee_manager.dart';

class ACPConfig {
  final String? localIp;
  final String? relayHost;
  final String? userId;
  final String? relayToken;
  final String? cloudDirectUrl;
  String? sessionKeyHex; // Key derived from pairing

  ACPConfig({
    this.localIp,
    this.relayHost = "relay.example.com",
    this.userId,
    this.relayToken,
    this.cloudDirectUrl,
    this.sessionKeyHex,
  });

  String? get relayUrl => (relayHost != null && userId != null) 
      ? "ws://$relayHost:8766/relay/app/$userId" : null;
  String? get cloudUrl => cloudDirectUrl ?? (relayHost != null ? "ws://$relayHost:8766/direct" : null);
}

class ACPClient {
  WebSocketChannel? _channel;
  final _uuid = const Uuid();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  
  ConnectionPath activeMode = ConnectionPath.none;
  String? activeUrl;
  E2EEManager? _e2ee;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;

  ACPClient();

  /// Orchestrates connection and performs ECDH pairing if needed.
  Future<void> smartConnect(ACPConfig config) async {
    // 1. Establish connection
    final result = await SmartConnect.connect(
      preferredLocalIp: config.localIp,
      relayUrl: config.relayUrl,
      cloudUrl: config.cloudUrl,
      token: config.relayToken,
      userId: config.userId,
    );

    _channel = result.channel;
    activeMode = result.path;
    activeUrl = result.url;
    _setupStream();

    // 2. Perform ECDH Pairing if no session key exists
    if (config.sessionKeyHex == null) {
      print('[ACP] No session key found. Initiating ECDH Pairing...');
      await _performPairing();
    } else {
      _e2ee = E2EEManager(config.sessionKeyHex!);
      print('[ACP] Using existing session key for E2EE.');
    }
    
    print('[ACP] SmartConnect Complete. Mode: $activeMode');
  }

  Future<void> _performPairing() async {
    // 1. Generate own key pair
    final keyPairData = await E2EEManager.generateKeyPair();
    final ownPublicKeyHex = keyPairData['publicKeyHex'] as String;
    final ownKeyPair = keyPairData['privateKey'];

    // 2. Exchange public keys with Mac
    // We send this as a raw JSON-RPC because we don't have a shared key yet
    final response = await sendRequest('pairing/exchange', {
      'publicKey': ownPublicKeyHex,
    }, forcePlaintext: true);

    if (response.containsKey('result')) {
      final peerPublicKeyHex = response['result']['publicKey'] as String;
      
      // 3. Derive Shared Secret
      final sharedSecretHex = await E2EEManager.deriveSharedSecret(
        ownKeyPair, peerPublicKeyHex
      );
      
      // 4. Initialize E2EE
      _e2ee = E2EEManager(sharedSecretHex);
      print('[ACP] Pairing Successful! Shared Secret Derived.');
      
      // Note: In a real app, we would save sharedSecretHex to secure storage here
    } else {
      throw Exception('Pairing failed: ${response['error']}');
    }
  }

  void _setupStream() {
    _channel!.stream.listen(
      (message) {
        Map<String, dynamic> data = jsonDecode(message);
        
        // Try to unwrap if it looks like an envelope
        if (data.containsKey('method') && data['method'] == 'e2ee/envelope') {
          if (_e2ee != null) {
            try {
              data = _e2ee!.unwrap(data);
            } catch (e) {
              print('[ACP] Decryption error: $e');
              return;
            }
          }
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
        activeMode = ConnectionPath.none;
      },
      onDone: () {
        activeMode = ConnectionPath.none;
      },
    );
  }

  Future<Map<String, dynamic>> sendRequest(String method, Map<String, dynamic> params, {bool forcePlaintext = false}) async {
    if (_channel == null) throw Exception('Not connected');

    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final requestObj = {
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params
    };

    dynamic payload;
    if (_e2ee != null && !forcePlaintext) {
      payload = jsonEncode(_e2ee!.wrap(requestObj));
    } else {
      payload = jsonEncode(requestObj);
    }

    _channel!.sink.add(payload);

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
      'clientInfo': {'name': 'KanbanMobile', 'version': '1.4.0'}
    });
  }

  Future<String> sendMessage(String message) async {
    final response = await sendRequest('chat/message', {'message': message});
    if (response.containsKey('result')) {
      final result = response['result'];
      if (result is Map && result.containsKey('message')) return result['message'];
      return result.toString();
    }
    throw Exception('Failed to send message');
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
    activeMode = ConnectionPath.none;
    _e2ee = null;
  }
}
