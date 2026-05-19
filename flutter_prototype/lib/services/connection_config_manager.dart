import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/connection_config.dart';

/// Connection configuration storage manager
class ConnectionConfigManager {
  static const String _configKey = 'connection_config';
  static const String _tokenKey = 'connection_relay_token';
  static const String _apiTokenKey = 'connection_api_token';
  static const String _userIdKey = 'connection_user_id';

  static ConnectionConfigManager? _instance;
  static SharedPreferences? _prefs;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  ConnectionConfigManager._();

  /// Get singleton instance
  static Future<ConnectionConfigManager> getInstance() async {
    if (_instance == null) {
      _instance = ConnectionConfigManager._();
      _prefs ??= await SharedPreferences.getInstance();
    }
    return _instance!;
  }

  /// Get or generate User ID
  Future<String> getUserId() async {
    String? userId = _prefs?.getString(_userIdKey);
    if (userId == null) {
      userId = _generateUserId();
      await _prefs?.setString(_userIdKey, userId);
    }
    return userId;
  }

  String _generateUserId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = timestamp.toString().substring(7);
    return 'user_$random';
  }

  /// Load configuration
  Future<ConnectionConfig> loadConfig() async {
    final userId = await getUserId();
    final jsonStr = _prefs?.getString(_configKey);
    if (jsonStr == null) {
      return ConnectionConfig.defaults(userId: userId);
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      // Load tokens from secure storage
      final relayToken = await _secureStorage.read(key: _tokenKey);
      final apiToken = await _secureStorage.read(key: _apiTokenKey);
      
      final config = ConnectionConfig.fromJson(json);
      // Ensure userId exists
      final finalConfig =
          config.userId != null ? config : config.copyWith(userId: userId);
      return finalConfig.copyWith(
        relayToken: relayToken,
        apiToken: apiToken,
      );
    } catch (e) {
      return ConnectionConfig.defaults(userId: userId);
    }
  }

  /// Save configuration
  Future<bool> saveConfig(ConnectionConfig config) async {
    try {
      // Save non-sensitive config to shared_preferences
      final configToSave = config.copyWith(
        lastUpdated: DateTime.now(),
      );
      final jsonStr = jsonEncode(configToSave.toJson());
      await _prefs?.setString(_configKey, jsonStr);

      // Save sensitive tokens to secure storage
      if (config.relayToken != null) {
        await _secureStorage.write(key: _tokenKey, value: config.relayToken);
      }
      if (config.apiToken != null) {
        await _secureStorage.write(key: _apiTokenKey, value: config.apiToken);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Load Relay Token
  Future<String?> loadRelayToken() async {
    return await _secureStorage.read(key: _tokenKey);
  }

  /// Load API Token
  Future<String?> loadApiToken() async {
    return await _secureStorage.read(key: _apiTokenKey);
  }

  /// Save Relay Token
  Future<bool> saveRelayToken(String token) async {
    try {
      await _secureStorage.write(key: _tokenKey, value: token);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Save API Token
  Future<bool> saveApiToken(String token) async {
    try {
      await _secureStorage.write(key: _apiTokenKey, value: token);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Clear all configuration
  Future<bool> clearConfig() async {
    try {
      await _prefs?.remove(_configKey);
      await _secureStorage.delete(key: _tokenKey);
      await _secureStorage.delete(key: _apiTokenKey);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Save last selected ACP Provider
  Future<void> setLastProvider(String providerId) async {
    await _prefs?.setString('last_acp_provider', providerId);
  }

  /// Get last selected ACP Provider
  String? getLastProvider() {
    return _prefs?.getString('last_acp_provider');
  }

  /// Save last selected Project ID
  Future<void> setLastProjectId(String projectId) async {
    await _prefs?.setString('last_project_id', projectId);
  }

  /// Get last selected Project ID
  String? getLastProjectId() {
    return _prefs?.getString('last_project_id');
  }

  /// Test connection
  Future<ConnectionTestResult> testConnection(
      ConnectionConfig config, String userId) async {
    switch (config.preferredMode) {
      case ConnectionMode.local:
        return _testLocalConnection(config);
      case ConnectionMode.relay:
        return _testRelayConnection(config, userId);
      case ConnectionMode.cloud:
        return _testCloudConnection(config);
    }
  }

  /// Test local connection
  Future<ConnectionTestResult> _testLocalConnection(
      ConnectionConfig config) async {
    if (kIsWeb) {
      return const ConnectionTestResult(
        success: false,
        message: 'Web platform does not support local connection testing',
      );
    }
    return _testHostConnection(
      config.localIp ?? 'localhost',
      config.localPort ?? 8766,
      'Local',
    );
  }

  /// Test relay connection
  Future<ConnectionTestResult> _testRelayConnection(
      ConnectionConfig config, String userId) async {
    if (kIsWeb) {
      return const ConnectionTestResult(
        success: false,
        message: 'Web platform does not support relay connection testing',
      );
    }
    return _testHostConnection(
      config.relayHost ?? 'localhost',
      config.relayPort ?? 8766,
      'Relay',
    );
  }

  /// Test cloud connection
  Future<ConnectionTestResult> _testCloudConnection(
      ConnectionConfig config) async {
    if (kIsWeb) {
      return const ConnectionTestResult(
        success: false,
        message: 'Web platform does not support cloud connection testing',
      );
    }
    return _testHostConnection(
      config.relayHost ?? 'localhost',
      config.relayPort ?? 8766,
      'Cloud',
    );
  }

  /// General TCP connection test
  Future<ConnectionTestResult> _testHostConnection(
    String host,
    int port,
    String modeName,
  ) async {
    try {
      final startTime = DateTime.now();
      final socket =
          await Socket.connect(host, port).timeout(const Duration(seconds: 5));
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      await socket.close();
      return ConnectionTestResult(
        success: true,
        latency: latency,
        message: '$modeName connected successfully (${latency}ms)',
      );
    } catch (e) {
      return ConnectionTestResult(
        success: false,
        message: '$modeName connection failed: ${e.toString()}',
      );
    }
  }
}

/// Connection test result
class ConnectionTestResult {
  final bool success;
  final int? latency;
  final String message;

  const ConnectionTestResult({
    required this.success,
    this.latency,
    required this.message,
  });
}
