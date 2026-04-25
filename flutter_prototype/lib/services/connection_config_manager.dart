import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/connection_config.dart';

/// 连接配置存储管理器
class ConnectionConfigManager {
  static const String _configKey = 'connection_config';
  static const String _tokenKey = 'connection_relay_token';
  static const String _userIdKey = 'connection_user_id';

  static ConnectionConfigManager? _instance;
  static SharedPreferences? _prefs;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  ConnectionConfigManager._();

  /// 获取单例实例
  static Future<ConnectionConfigManager> getInstance() async {
    if (_instance == null) {
      _instance = ConnectionConfigManager._();
      _prefs ??= await SharedPreferences.getInstance();
    }
    return _instance!;
  }

  /// 获取或生成用户ID
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

  /// 加载配置
  Future<ConnectionConfig> loadConfig() async {
    final userId = await getUserId();
    final jsonStr = _prefs?.getString(_configKey);
    if (jsonStr == null) {
      return ConnectionConfig.defaults(userId: userId);
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      // 从安全存储加载token
      final token = await _secureStorage.read(key: _tokenKey);
      final config = ConnectionConfig.fromJson(json);
      // 确保 userId 存在
      final finalConfig =
          config.userId != null ? config : config.copyWith(userId: userId);
      return finalConfig.copyWith(relayToken: token);
    } catch (e) {
      return ConnectionConfig.defaults(userId: userId);
    }
  }

  /// 保存配置
  Future<bool> saveConfig(ConnectionConfig config) async {
    try {
      // 保存非敏感配置到shared_preferences
      final configToSave = config.copyWith(
        lastUpdated: DateTime.now(),
      );
      final jsonStr = jsonEncode(configToSave.toJson());
      await _prefs?.setString(_configKey, jsonStr);

      // 保存敏感token到安全存储
      if (config.relayToken != null) {
        await _secureStorage.write(key: _tokenKey, value: config.relayToken);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// 加载Relay Token
  Future<String?> loadRelayToken() async {
    return await _secureStorage.read(key: _tokenKey);
  }

  /// 保存Relay Token
  Future<bool> saveRelayToken(String token) async {
    try {
      await _secureStorage.write(key: _tokenKey, value: token);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 清除所有配置
  Future<bool> clearConfig() async {
    try {
      await _prefs?.remove(_configKey);
      await _secureStorage.delete(key: _tokenKey);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 保存上次选择的 ACP Provider
  Future<void> setLastProvider(String providerId) async {
    await _prefs?.setString('last_acp_provider', providerId);
  }

  /// 获取上次选择的 ACP Provider
  String? getLastProvider() {
    return _prefs?.getString('last_acp_provider');
  }

  /// 保存上次选择的项目 ID
  Future<void> setLastProjectId(String projectId) async {
    await _prefs?.setString('last_project_id', projectId);
  }

  /// 获取上次选择的项目 ID
  String? getLastProjectId() {
    return _prefs?.getString('last_project_id');
  }

  /// 测试连接
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

  /// 测试本地连接
  Future<ConnectionTestResult> _testLocalConnection(
      ConnectionConfig config) async {
    if (kIsWeb) {
      return const ConnectionTestResult(
        success: false,
        message: 'Web平台不支持本地连接测试',
      );
    }
    return _testHostConnection(
      config.localIp ?? 'localhost',
      config.localPort ?? 8766,
      'Local',
    );
  }

  /// 测试中继连接
  Future<ConnectionTestResult> _testRelayConnection(
      ConnectionConfig config, String userId) async {
    if (kIsWeb) {
      return const ConnectionTestResult(
        success: false,
        message: 'Web平台不支持中继连接测试',
      );
    }
    return _testHostConnection(
      config.relayHost ?? 'localhost',
      config.relayPort ?? 8766,
      'Relay',
    );
  }

  /// 测试云端连接
  Future<ConnectionTestResult> _testCloudConnection(
      ConnectionConfig config) async {
    if (kIsWeb) {
      return const ConnectionTestResult(
        success: false,
        message: 'Web平台不支持云端连接测试',
      );
    }
    return _testHostConnection(
      config.relayHost ?? 'localhost',
      config.relayPort ?? 8766,
      'Cloud',
    );
  }

  /// 通用 TCP 连接测试
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
        message: '$modeName 连接成功 (${latency}ms)',
      );
    } catch (e) {
      return ConnectionTestResult(
        success: false,
        message: '$modeName 连接失败: ${e.toString()}',
      );
    }
  }
}

/// 连接测试结果
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
