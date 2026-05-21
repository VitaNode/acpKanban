import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'smart_connect.dart';
import 'e2ee_manager.dart';
import '../models/connection_config.dart';
import 'file_system_service.dart';
import 'terminal_service.dart';
import '../utils/app_logger.dart';

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
      systemConfig: config.systemConfig?.toJson(),
    );
  }
}

class ACPClient {
  static final ACPClient _instance = ACPClient._internal();
  factory ACPClient() => _instance;
  ACPClient._internal();

  WebSocketChannel? _channel;
  final _uuid = const Uuid();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final _fileSystemService = FileSystemService();
  final _terminalService = TerminalService();

  ConnectionPath activeMode = ConnectionPath.none;
  String? activeUrl;
  E2EEManager? _e2ee;

  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;

  Map<String, dynamic> _agentCapabilities = {};
  Map<String, dynamic> get agentCapabilities => _agentCapabilities;

  bool get isReady => _channel != null && (_e2ee?.isReady ?? false);
  Completer<void>? _readyCompleter;

  Future<void> get waitForReady async {
    if (isReady) return;
    if (_readyCompleter == null || _readyCompleter!.isCompleted) {
      _readyCompleter = Completer<void>();
    }
    return _readyCompleter!.future;
  }

  Future<void> smartConnect(ACPConfig config) async {
    _readyCompleter = Completer<void>();
    if (config.sessionKeyHex != null) {
      _e2ee = E2EEManager(config.sessionKeyHex!);
      AppLogger.info('[ACP] E2EE initialized with pre-shared key');
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
    AppLogger.info('[ACP] Connected, E2EE ready: ${_e2ee?.isReady ?? false}');
    _setupStream();

    if (_e2ee == null) {
      AppLogger.info('[ACP] Initiating ECDH Pairing...');
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
      AppLogger.info('[ACP] Pairing Successful!');
    } else {
      throw Exception('Pairing failed');
    }
  }

  Future<Map<String, dynamic>> _handleFsRequest(
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'fs/read_text_file':
        return await _fileSystemService.handleReadTextFile(params);
      case 'fs/write_text_file':
        return await _fileSystemService.handleWriteTextFile(params);
      default:
        return {
          'error': {'code': -32601, 'message': 'Method not found: $method'}
        };
    }
  }

  Future<Map<String, dynamic>> _handleTerminalRequest(
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'terminal/create':
        return await _terminalService.createTerminal(params);
      case 'terminal/get_output':
        return await _terminalService.getTerminalOutput(params);
      case 'terminal/wait_for_exit':
        return await _terminalService.waitForExit(params);
      case 'terminal/kill':
        return await _terminalService.killTerminal(params);
      case 'terminal/release':
        return await _terminalService.releaseTerminal(params);
      default:
        return {
          'error': {'code': -32601, 'message': 'Method not found: $method'}
        };
    }
  }

  void _setupStream() {
    AppLogger.info(
        '[ACP] Setting up stream, E2EE ready: ${_e2ee?.isReady ?? false}');
    _channel!.stream.listen(
      (message) async {
        try {
          AppLogger.debug(
              '[ACP] Raw message received: ${message.toString().substring(0, 100)}...');

          dynamic decoded = message;
          if (message is String) {
            try {
              decoded = jsonDecode(message);
            } catch (e) {
              AppLogger.error('[ACP] Failed to decode JSON: $e');
              return;
            }
          }

          if (decoded is! Map<String, dynamic>) {
            AppLogger.warning(
                '[ACP] Decoded data is not a Map: ${decoded.runtimeType}');
            return;
          }

          Map<String, dynamic> data = decoded;
          AppLogger.debug(
              '[ACP] Decoded data method: ${data['method'] ?? 'N/A'}');

          if (_e2ee != null &&
              data.containsKey('method') &&
              data['method'] == 'e2ee/envelope') {
            AppLogger.debug('[ACP] Attempting to decrypt E2EE message...');
            try {
              data = await _e2ee!.unwrap(data);
              AppLogger.debug('[ACP] Decryption successful');
            } catch (e) {
              AppLogger.error('[ACP] Decryption error: $e');
              return;
            }
          }

          final method = data['method'] as String?;
          final id = data['id']?.toString();
          final params = data['params'] as Map<String, dynamic>? ?? {};

          if (method != null && id != null) {
            if (method.startsWith('fs/')) {
              AppLogger.info('[ACP] Handling fs request: $method');
              final result = await _handleFsRequest(method, params);
              final response = {
                'jsonrpc': '2.0',
                'id': id,
                'result': result,
              };
              _channel!.sink.add(jsonEncode(response));
              return;
            } else if (method.startsWith('terminal/')) {
              AppLogger.info('[ACP] Handling terminal request: $method');
              final result = await _handleTerminalRequest(method, params);
              final response = {
                'jsonrpc': '2.0',
                'id': id,
                'result': result,
              };
              _channel!.sink.add(jsonEncode(response));
              return;
            }
          }

          if (data.containsKey('id')) {
            final reqId = data['id'].toString();
            if (_pendingRequests.containsKey(reqId)) {
              _pendingRequests[reqId]!.complete(data);
              _pendingRequests.remove(reqId);
            }
          }
          _messageController.add(jsonEncode(data));
        } catch (e) {
          AppLogger.error('[ACP] Message processing error', e);
        }
      },
      onError: (error) {
        AppLogger.error('[ACP] Stream error', error);
        activeMode = ConnectionPath.none;
      },
      onDone: () {
        AppLogger.info('[ACP] Stream done');
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
      AppLogger.info('[ACP] Sending initialize...');
      final Map<String, dynamic> params = {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {
            'readTextFile': true,
            'writeTextFile': true,
          },
          'terminal': true,
        },
        'clientInfo': {
          'name': 'KanbanMobile',
          'title': 'acpKanban',
          'version': '2.0.0',
        },
      };
      if (systemConfig != null) {
        params['systemConfig'] = systemConfig;
      }

      final response = await sendRequest('initialize', params)
          .timeout(const Duration(seconds: 60));
      AppLogger.info('[ACP] Initialize success');

      _agentCapabilities = response['result']?['agentCapabilities'] ?? {};
      AppLogger.info('[ACP] Agent capabilities: $_agentCapabilities');

      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
    } catch (e) {
      AppLogger.warning('[ACP] Initialize warning (proceeding anyway): $e');
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
    }
  }

  Future<Map<String, dynamic>?> getSystemConfig() async {
    try {
      final response = await sendRequest('system/config/get', {});
      if (response.containsKey('result')) {
        return response['result'] as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      AppLogger.error('[ACP] Failed to get system config', e);
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> listProviders() async {
    final response = await sendRequest('provider/list', {});
    if (response.containsKey('result')) {
      return List<Map<String, dynamic>>.from(response['result']);
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> getProjectProgress(String projectId,
      {int depth = 3}) async {
    final response = await sendRequest(
        'kanban/progress/get', {'project_id': projectId, 'depth': depth});
    if (response.containsKey('result')) {
      return List<Map<String, dynamic>>.from(response['result']);
    }
    return [];
  }

  Future<String> createMilestone(String projectId, String title,
      {String? description, String? targetDate}) async {
    final response = await sendRequest('kanban/milestone/create', {
      'project_id': projectId,
      'title': title,
      if (description != null) 'description': description,
      if (targetDate != null) 'target_date': targetDate,
    });
    return response['result']['id'];
  }

  Future<void> updateMilestone(String mId,
      {String? title,
      String? description,
      String? status,
      String? targetDate}) async {
    await sendRequest('kanban/milestone/update', {
      'milestone_id': mId,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (status != null) 'status': status,
      if (targetDate != null) 'target_date': targetDate,
    });
  }

  Future<void> deleteMilestone(String mId) async {
    await sendRequest('kanban/milestone/delete', {'milestone_id': mId});
  }

  Future<String> createFeature(String mId, String title,
      {String? description}) async {
    final response = await sendRequest('kanban/feature/create', {
      'milestone_id': mId,
      'title': title,
      if (description != null) 'description': description,
    });
    return response['result']['id'];
  }

  Future<void> updateFeature(String fId,
      {String? title, String? description, String? status}) async {
    await sendRequest('kanban/feature/update', {
      'feature_id': fId,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (status != null) 'status': status,
    });
  }

  Future<void> deleteFeature(String fId) async {
    await sendRequest('kanban/feature/delete', {'feature_id': fId});
  }

  Future<String> createCard(String columnId, String title,
      {String? description, String? featureId}) async {
    final response = await sendRequest('kanban/card/create', {
      'column_id': columnId,
      'title': title,
      if (description != null) 'description': description,
      if (featureId != null) 'feature_id': featureId,
    });
    return response['result']['id'];
  }

  Future<void> updateCard(String cardId,
      {String? title, String? description, String? featureId}) async {
    await sendRequest('kanban/card/update', {
      'card_id': cardId,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (featureId != null) 'feature_id': featureId,
    });
  }

  Future<String> sendMessage(String message) async {
    try {
      final response =
          await sendRequest('session/prompt', {'message': message});
      if (response.containsKey('result')) {
        final result = response['result'];
        if (result is Map && result.containsKey('text')) {
          return result['text'].toString();
        }
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
      try {
        final legacyResponse =
            await sendRequest('chat/message', {'message': message});
        final result = legacyResponse['result'];
        if (result is Map && result.containsKey('message'))
          return result['message'].toString();
        return result.toString();
      } catch (_) {
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

  void cancelPendingRequest(String id) {
    if (_pendingRequests.containsKey(id)) {
      final completer = _pendingRequests.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.completeError('Request cancelled');
      }
      AppLogger.info('[ACP] Cancelled pending request: $id');
    }
  }

  void cancelAllPendingRequests() {
    final ids = List<String>.from(_pendingRequests.keys);
    for (final id in ids) {
      cancelPendingRequest(id);
    }
    AppLogger.info('[ACP] Cancelled all ${ids.length} pending requests');
  }
}
