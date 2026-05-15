import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/connection_config.dart';
import 'connection_config_manager.dart';

class PairingResult {
  final bool success;
  final String? message;
  final ConnectionConfig? config;

  PairingResult({required this.success, this.message, this.config});
}

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  /// 使用 6 位配对码从指定主机获取凭据
  /// [host] 可以是 IP 地址或域名，例如 "100.64.1.5" (Tailscale IP)
  /// [port] 是 API 端口，默认为 8000
  Future<PairingResult> pairWithCode(String host, String code, {int port = 8000}) async {
    final url = Uri.parse('http://$host:$port/api/auth/pair');
    
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': code}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // 解析返回的凭据
        final userId = data['user_id'] as String;
        final relayToken = data['relay_token'] as String;
        final relayUrl = data['relay_url'] as String; // e.g. "wss://mybot.siliconpulse.cc"
        
        // 解析 Relay Host
        Uri relayUri = Uri.parse(relayUrl.replaceFirst('ws', 'http'));
        String relayHost = relayUri.host;
        int relayPort = relayUri.port > 0 ? relayUri.port : 8766;

        // 构建新的配置
        final configManager = await ConnectionConfigManager.getInstance();
        final currentConfig = await configManager.loadConfig();
        
        final newConfig = currentConfig.copyWith(
          preferredMode: ConnectionMode.relay,
          localIp: host, // 既然是通过这个 IP 配对成功的，它也可以作为 localIp
          relayHost: relayHost,
          relayPort: relayPort,
          relayToken: relayToken,
          userId: userId,
          apiPort: port,
        );

        // 保存配置
        await configManager.saveConfig(newConfig);
        
        return PairingResult(
          success: true,
          message: '配对成功',
          config: newConfig,
        );
      } else if (response.statusCode == 401) {
        return PairingResult(success: false, message: '配对码无效或已过期');
      } else {
        return PairingResult(success: false, message: '服务器错误: ${response.statusCode}');
      }
    } catch (e) {
      return PairingResult(success: false, message: '无法连接到服务器: ${e.toString()}');
    }
  }

  /// 在桌面端生成配对码 (仅用于本地测试或在桌面端 UI 显示)
  Future<String?> generatePairingCode(String host, {int port = 8000}) async {
    final url = Uri.parse('http://$host:$port/api/auth/pairing-code');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['code'] as String;
      }
    } catch (e) {
      print('Failed to generate pairing code: $e');
    }
    return null;
  }
}
