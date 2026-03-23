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
  final String? sessionKeyHex; 

  ACPConfig({
    this.localIp,
    this.relayHost = "mybot.siliconpulse.cc",
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

  Future<void> smartConnect(ACPConfig config) async {
    if (config.sessionKeyHex != null) {
      _e2ee = E2EEManager(config.sessionKeyHex!);
    }

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

    if (_e2ee == null) {
      print('[ACP] Initiating ECDH Pairing...');
      await _performPairing();
    }
  }

  Future<void> _performPairing() async {
    final keyPairData = await E2EEManager.generateKeyPair();
    final ownPublicKeyHex = keyPairData['publicKeyHex'] as String;
    final ownKeyPair = keyPairData['privateKey'];

    final response = await sendRequest('pairing/exchange', {
      'publicKey': ownPublicKeyHex,
    }, forcePlaintext: true);

    if (response.containsKey('result')) {
      final peerPublicKeyHex = response['result']['publicKey'] as String;
      final sharedSecretHex = await E2EEManager.deriveSharedSecret(ownKeyPair, peerPublicKeyHex);
      _e2ee = E2EEManager(sharedSecretHex);
      print('[ACP] Pairing Successful!');
    } else {
      throw Exception('Pairing failed');
    }
  }

  void _setupStream() {
    _channel!.stream.listen(
      (message) async {
        try {
          Map<String, dynamic> data = jsonDecode(message);
          
          if (_e2ee != null && data.containsKey('method') && data['method'] == 'e2ee/envelope') {
            try {
              data = await _e2ee!.unwrap(data);
            } catch (e) {
              print('[ACP] Decryption error: $e');
              return;
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
        } catch (e) {
          print('[ACP] Message processing error: $e');
        }
      },
      onError: (error) => activeMode = ConnectionPath.none,
      onDone: () => activeMode = ConnectionPath.none,
    );
  }

  Future<Map<String, dynamic>> sendRequest(String method, Map<String, dynamic> params, {bool forcePlaintext = false}) async {
    if (_channel == null || activeMode == ConnectionPath.none) throw Exception('Not connected');

    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final requestObj = {"jsonrpc": "2.0", "id": id, "method": method, "params": params};
    
    dynamic payload;
    if (_e2ee != null && !forcePlaintext) {
      payload = jsonEncode(await _e2ee!.wrap(requestObj));
    } else {
      payload = jsonEncode(requestObj);
    }

    _channel!.sink.add(payload);
    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> initialize() async {
    try {
      print('[ACP] Sending initialize...');
      // Short timeout for initialize, proceed even if it fails/times out
      await sendRequest('initialize', {
        'clientInfo': {'name': 'KanbanMobile', 'version': '1.5.0'}
      }).timeout(const Duration(seconds: 5));
      print('[ACP] Initialize success');
    } catch (e) {
      print('[ACP] Initialize warning (proceeding anyway): $e');
    }
  }

  Future<String> sendMessage(String message) async {
    // Gemini CLI uses 'session/prompt'
    try {
      final response = await sendRequest('session/prompt', {'message': message});
      if (response.containsKey('result')) {
        final result = response['result'];
        // Standard ACP often returns { "text": "response..." }
        if (result is Map && result.containsKey('text')) {
          return result['text'].toString();
        }
        // Fallback: check for 'message' key (legacy/custom)
        if (result is Map && result.containsKey('message')) {
          return result['message'].toString();
        }
        return result.toString();
      } else if (response.containsKey('error')) {
        final error = response['error'];
        if (error is Map) {
          final msg = error['message'] ?? 'Unknown AI Error';
          final detail = error['data'] ?? '';
          throw Exception('$msg: $detail');
        }
        throw Exception(error.toString());
      }
    } catch (e) {
      // If session/prompt fails, try legacy chat/message (for acp_server.py compat)
      try {
        final legacyResponse = await sendRequest('chat/message', {'message': message});
        final result = legacyResponse['result'];
        if (result is Map && result.containsKey('message')) return result['message'].toString();
        return result.toString();
      } catch (_) {
        // Throw original error if legacy also fails
        rethrow;
      }
    }
    throw Exception('Unknown response format');
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
    activeMode = ConnectionPath.none;
    _e2ee = null;
  }
}
