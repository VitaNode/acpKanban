/// 连接模式枚举
enum ConnectionMode {
  /// 内网直连
  local,

  /// 云端中继
  relay,

  /// 云端 SaaS (直连云端服务)
  cloud,
}

/// 系统代理配置 (摘要与向量化)
class SystemAgentConfig {
  final String? baseUrl;
  final String? apiKey;
  final String summaryModel;
  final String embeddingModel;

  const SystemAgentConfig({
    this.baseUrl,
    this.apiKey,
    this.summaryModel = 'gpt-4o-mini',
    this.embeddingModel = 'text-embedding-3-small',
  });

  factory SystemAgentConfig.fromJson(Map<String, dynamic> json) {
    return SystemAgentConfig(
      baseUrl: json['baseUrl'] as String?,
      apiKey: json['apiKey'] as String?,
      summaryModel: json['summaryModel'] as String? ?? 'gpt-4o-mini',
      embeddingModel: json['embeddingModel'] as String? ?? 'text-embedding-3-small',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'summaryModel': summaryModel,
      'embeddingModel': embeddingModel,
    };
  }

  SystemAgentConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? summaryModel,
    String? embeddingModel,
  }) {
    return SystemAgentConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      summaryModel: summaryModel ?? this.summaryModel,
      embeddingModel: embeddingModel ?? this.embeddingModel,
    );
  }
}

/// 连接配置数据模型
class ConnectionConfig {
  final ConnectionMode preferredMode;
  final String? localIp;
  final int? localPort;
  final int? apiPort;
  final String? relayHost;
  final int? relayPort;
  final String? relayToken;
  final String? cloudUrl;
  final bool autoFallback;
  final DateTime? lastUpdated;
  final String? userId;
  final SystemAgentConfig systemConfig;

  const ConnectionConfig({
    this.preferredMode = ConnectionMode.local,
    this.localIp,
    this.localPort = 8766,
    this.apiPort = 8000,
    this.relayHost,
    this.relayPort = 8766,
    this.relayToken,
    this.cloudUrl,
    this.autoFallback = false,
    this.lastUpdated,
    this.userId,
    this.systemConfig = const SystemAgentConfig(),
  });

  /// 创建默认配置
  factory ConnectionConfig.defaults({String? userId}) {
    return ConnectionConfig(
      preferredMode: ConnectionMode.local,
      localPort: 8766,
      apiPort: 8000,
      relayHost: '35.211.219.123',
      relayPort: 8766,
      cloudUrl: 'ws://35.211.219.123:8766/direct',
      autoFallback: false,
      userId: userId,
      systemConfig: const SystemAgentConfig(),
    );
  }

  /// 从 JSON 创建配置
  factory ConnectionConfig.fromJson(Map<String, dynamic> json) {
    final modeIndex = json['preferredMode'] as int? ?? 0;
    final mode = modeIndex == 0
        ? ConnectionMode.local
        : ConnectionMode.values[modeIndex];
    return ConnectionConfig(
      preferredMode: mode,
      localIp: json['localIp'] as String?,
      localPort: json['localPort'] as int? ?? 8766,
      apiPort: json['apiPort'] as int? ?? 8000,
      relayHost: json['relayHost'] as String?,
      relayPort: json['relayPort'] as int? ?? 8766,
      relayToken: json['relayToken'] as String?,
      cloudUrl: json['cloudUrl'] as String?,
      autoFallback: json['autoFallback'] as bool? ?? false,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
      userId: json['userId'] as String?,
      systemConfig: json['systemConfig'] != null
          ? SystemAgentConfig.fromJson(json['systemConfig'] as Map<String, dynamic>)
          : const SystemAgentConfig(),
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'preferredMode': preferredMode.index,
      'localIp': localIp,
      'localPort': localPort,
      'apiPort': apiPort,
      'relayHost': relayHost,
      'relayPort': relayPort,
      'relayToken': relayToken,
      'cloudUrl': cloudUrl,
      'autoFallback': autoFallback,
      'lastUpdated': lastUpdated?.toIso8601String(),
      'userId': userId,
      'systemConfig': systemConfig.toJson(),
    };
  }

  /// 复制并修改配置
  ConnectionConfig copyWith({
    ConnectionMode? preferredMode,
    String? localIp,
    int? localPort,
    int? apiPort,
    String? relayHost,
    int? relayPort,
    String? relayToken,
    String? cloudUrl,
    bool? autoFallback,
    DateTime? lastUpdated,
    String? userId,
    SystemAgentConfig? systemConfig,
  }) {
    return ConnectionConfig(
      preferredMode: preferredMode ?? this.preferredMode,
      localIp: localIp ?? this.localIp,
      localPort: localPort ?? this.localPort,
      apiPort: apiPort ?? this.apiPort,
      relayHost: relayHost ?? this.relayHost,
      relayPort: relayPort ?? this.relayPort,
      relayToken: relayToken ?? this.relayToken,
      cloudUrl: cloudUrl ?? this.cloudUrl,
      autoFallback: autoFallback ?? this.autoFallback,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      userId: userId ?? this.userId,
      systemConfig: systemConfig ?? this.systemConfig,
    );
  }

  String get localUrl => 'ws://${localIp ?? 'localhost'}:$localPort';

  String get relayUrl => 'ws://${relayHost ?? 'localhost'}:$relayPort';

  String get cloudDirectUrl =>
      'ws://${relayHost ?? 'localhost'}:$relayPort/direct';

  @override
  String toString() {
    return 'ConnectionConfig(mode: $preferredMode, local: $localIp:$localPort, api: $apiPort, relay: $relayHost:$relayPort, cloud: $cloudUrl)';
  }
}
