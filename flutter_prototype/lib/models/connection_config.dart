/// 连接模式枚举
enum ConnectionMode {
  /// 内网直连
  local,

  /// 云端中继
  relay,

  /// 云端SaaS (直连云端服务)
  cloud,
}

/// 连接配置数据模型
class ConnectionConfig {
  final ConnectionMode preferredMode;
  final String? localIp;
  final int? localPort;
  final String? relayHost;
  final int? relayPort;
  final String? relayToken;
  final String? cloudUrl;
  final bool autoFallback;
  final DateTime? lastUpdated;
  final String? userId;

  const ConnectionConfig({
    this.preferredMode = ConnectionMode.local,
    this.localIp,
    this.localPort = 8766,
    this.relayHost,
    this.relayPort = 8766,
    this.relayToken,
    this.cloudUrl,
    this.autoFallback = false,
    this.lastUpdated,
    this.userId,
  });

  /// 创建默认配置
  factory ConnectionConfig.defaults({String? userId}) {
    return ConnectionConfig(
      preferredMode: ConnectionMode.local,
      localPort: 8766,
      relayHost: '35.211.219.123',
      relayPort: 8766,
      cloudUrl: 'ws://35.211.219.123:8766/direct',
      autoFallback: false,
      userId: userId,
    );
  }

  /// 从JSON创建配置
  factory ConnectionConfig.fromJson(Map<String, dynamic> json) {
    final modeIndex = json['preferredMode'] as int? ?? 0;
    final mode = modeIndex == 0
        ? ConnectionMode.local
        : ConnectionMode.values[modeIndex];
    return ConnectionConfig(
      preferredMode: mode,
      localIp: json['localIp'] as String?,
      localPort: json['localPort'] as int? ?? 8766,
      relayHost: json['relayHost'] as String?,
      relayPort: json['relayPort'] as int? ?? 8766,
      relayToken: json['relayToken'] as String?,
      cloudUrl: json['cloudUrl'] as String?,
      autoFallback: json['autoFallback'] as bool? ?? false,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
      userId: json['userId'] as String?,
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'preferredMode': preferredMode.index,
      'localIp': localIp,
      'localPort': localPort,
      'relayHost': relayHost,
      'relayPort': relayPort,
      'relayToken': relayToken,
      'cloudUrl': cloudUrl,
      'autoFallback': autoFallback,
      'lastUpdated': lastUpdated?.toIso8601String(),
      'userId': userId,
    };
  }

  /// 复制并修改配置
  ConnectionConfig copyWith({
    ConnectionMode? preferredMode,
    String? localIp,
    int? localPort,
    String? relayHost,
    int? relayPort,
    String? relayToken,
    String? cloudUrl,
    bool? autoFallback,
    DateTime? lastUpdated,
    String? userId,
  }) {
    return ConnectionConfig(
      preferredMode: preferredMode ?? this.preferredMode,
      localIp: localIp ?? this.localIp,
      localPort: localPort ?? this.localPort,
      relayHost: relayHost ?? this.relayHost,
      relayPort: relayPort ?? this.relayPort,
      relayToken: relayToken ?? this.relayToken,
      cloudUrl: cloudUrl ?? this.cloudUrl,
      autoFallback: autoFallback ?? this.autoFallback,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      userId: userId ?? this.userId,
    );
  }

  String get localUrl => 'ws://${localIp ?? 'localhost'}:$localPort';

  String get relayUrl => 'ws://${relayHost ?? 'localhost'}:$relayPort';

  String get cloudDirectUrl =>
      'ws://${relayHost ?? 'localhost'}:$relayPort/direct';

  @override
  String toString() {
    return 'ConnectionConfig(mode: $preferredMode, local: $localIp:$localPort, relay: $relayHost:$relayPort, cloud: $cloudUrl)';
  }
}
