import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'smart_connect.dart';
import 'e2ee_manager.dart';
import '../models/connection_config.dart';

class ACPConfig {
  final ConnectionMode mode;
  final String? localIp;
  final bool useMdns;
  final String? relayHost;
  final int relayPort;
  final String? userId;
  final String? relayToken;
  final String? cloudDirectUrl;
  final String? sessionKeyHex;
  final Map<String, dynamic>? systemConfig;

  ACPConfig({
    this.mode = ConnectionMode.local,
    this.localIp,
    this.useMdns = true,
    this.relayHost,
    this.relayPort = 8766,
    this.userId,
    this.relayToken,
    this.cloudDirectUrl,
    this.sessionKeyHex,
    this.systemConfig,
  });

  factory ACPConfig.fromConnectionConfig(
      ConnectionConfig config, String userId) {
    return ACPConfig(
      mode: config.preferredMode,
      localIp: config.localIp,
      useMdns: true,
      relayHost: config.relayHost,
      relayPort: config.relayPort ?? 8766,
      userId: userId,
      relayToken: config.relayToken,
      cloudDirectUrl: config.cloudUrl,
      systemConfig: config.systemConfig.toJson(),
    );
  }
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
      print('[ACP] E2EE initialized with pre-shared key');
    }

    final result = await SmartConnect.connect(
      mode: config.mode,
      localIp: config.localIp,
      useMdns: config.useMdns,
      relayHost: config.relayHost,
      relayPort: config.relayPort,
      relayToken: config.relayToken,
      userId: config.userId,
      cloudUrl: config.cloudDirectUrl,
    );

    _channel = result.channel;
    activeMode = result.path;
    activeUrl = result.url;
    print('[ACP] Connected, E2EE ready: ${_e2ee?.isReady ?? false}');
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

    final response = await sendRequest(
        'pairing/exchange',
        {
          'publicKey': ownPublicKeyHex,
        },
        forcePlaintext: true);

    if (response.containsKey('result')) {
      final peerPublicKeyHex = response['result']['publicKey'] as String;
      final sharedSecretHex =
          await E2EEManager.deriveSharedSecret(ownKeyPair, peerPublicKeyHex);
      _e2ee = E2EEManager(sharedSecretHex);
      print('[ACP] Pairing Successful!');
    } else {
      throw Exception('Pairing failed');
    }
  }

  void _setupStream() {
    print('[ACP] Setting up stream, E2EE ready: ${_e2ee?.isReady ?? false}');
    _channel!.stream.listen(
      (message) async {
        try {
          print(
              '[ACP] Raw message received: ${message.toString().substring(0, 100)}...');

          // Defensive decoding: handle both String and direct JSON
          dynamic decoded = message;
          if (message is String) {
            try {
              decoded = jsonDecode(message);
            } catch (e) {
              print('[ACP] Failed to decode JSON: $e');
              return;
            }
          }

          // Ensure we have a Map
          if (decoded is! Map<String, dynamic>) {
            print('[ACP] Decoded data is not a Map: ${decoded.runtimeType}');
            return;
          }

          Map<String, dynamic> data = decoded;
          print('[ACP] Decoded data method: ${data['method'] ?? 'N/A'}');

          if (_e2ee != null &&
              data.containsKey('method') &&
              data['method'] == 'e2ee/envelope') {
            print('[ACP] Attempting to decrypt E2EE message...');
            try {
              data = await _e2ee!.unwrap(data);
              print('[ACP] Decryption successful');
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
          print('[ACP] Error stack: ${StackTrace.current}');
        }
      },
      onError: (error) {
        print('[ACP] Stream error: $error');
        activeMode = ConnectionPath.none;
      },
      onDone: () {
        print('[ACP] Stream done');
        activeMode = ConnectionPath.none;
      },
    );
  }

  Future<Map<String, dynamic>> sendRequest(
      String method, Map<String, dynamic> params,
      {bool forcePlaintext = false}) async {
    if (_channel == null || activeMode == ConnectionPath.none)
      throw Exception('Not connected');

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
      payload = jsonEncode(await _e2ee!.wrap(requestObj));
    } else {
      payload = jsonEncode(requestObj);
    }

    _channel!.sink.add(payload);
    return completer.future.timeout(const Duration(seconds: 300));
  }

  Future<void> initialize([Map<String, dynamic>? systemConfig]) async {
    try {
      print('[ACP] Sending initialize...');
      final Map<String, dynamic> params = {
        'clientInfo': {'name': 'KanbanMobile', 'version': '1.5.0'}
      };
      if (systemConfig != null) {
        params['systemConfig'] = systemConfig;
      }
      
      // Short timeout for initialize, proceed even if it fails/times out
      await sendRequest('initialize', params).timeout(const Duration(seconds: 60));
      print('[ACP] Initialize success');
    } catch (e) {
      print('[ACP] Initialize warning (proceeding anyway): $e');
    }
  }

  Future<String> sendMessage(String message) async {
    // Gemini CLI uses 'session/prompt'
    try {
      final response =
          await sendRequest('session/prompt', {'message': message});
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
        final legacyResponse =
            await sendRequest('chat/message', {'message': message});
        final result = legacyResponse['result'];
        if (result is Map && result.containsKey('message'))
          return result['message'].toString();
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
