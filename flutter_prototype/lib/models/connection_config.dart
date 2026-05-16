import 'package:flutter/material.dart';

/// Connection mode enumeration
enum ConnectionMode {
  /// Local direct connection
  local,

  /// Cloud relay
  relay,

  /// Cloud SaaS (direct cloud service)
  cloud,
}

/// System proxy configuration (for summaries and vectorization)
class SystemProxyConfig {
  final String providerId;
  final Map<String, dynamic>? config;

  SystemProxyConfig({
    required this.providerId,
    this.config,
  });

  factory SystemProxyConfig.fromJson(Map<String, dynamic> json) {
    return SystemProxyConfig(
      providerId: json['provider_id'] as String,
      config: json['config'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'provider_id': providerId,
      if (config != null) 'config': config,
    };
  }
}

/// Connection configuration data model
class ConnectionConfig {
  final ConnectionMode preferredMode;
  final String? localIp;
  final int? localPort;
  final String? relayHost;
  final int? relayPort;
  final String? relayToken;
  final String? userId;
  final String? cloudUrl;
  final bool useMdns;
  final DateTime? lastUpdated;
  final SystemProxyConfig? systemConfig;

  ConnectionConfig({
    required this.preferredMode,
    this.localIp,
    this.localPort = 8766,
    this.relayHost,
    this.relayPort = 8766,
    this.relayToken,
    this.userId,
    this.cloudUrl,
    this.useMdns = true,
    this.lastUpdated,
    this.systemConfig,
  });

  /// Create default configuration
  factory ConnectionConfig.defaults({String? userId}) {
    return ConnectionConfig(
      preferredMode: ConnectionMode.local,
      localIp: 'localhost',
      localPort: 8766,
      relayHost: 'mybot.local',
      relayPort: 8766,
      useMdns: true,
      userId: userId,
      lastUpdated: DateTime.now(),
    );
  }

  /// Create configuration from JSON
  factory ConnectionConfig.fromJson(Map<String, dynamic> json) {
    return ConnectionConfig(
      preferredMode: ConnectionMode.values.firstWhere(
        (e) => e.name == json['preferredMode'],
        orElse: () => ConnectionMode.local,
      ),
      localIp: json['localIp'] as String?,
      localPort: json['localPort'] as int?,
      relayHost: json['relayHost'] as String?,
      relayPort: json['relayPort'] as int?,
      relayToken: json['relayToken'] as String?,
      userId: json['userId'] as String?,
      cloudUrl: json['cloudUrl'] as String?,
      useMdns: json['useMdns'] as bool? ?? true,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
      systemConfig: json['systemConfig'] != null
          ? SystemProxyConfig.fromJson(json['systemConfig'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'preferredMode': preferredMode.name,
      'localIp': localIp,
      'localPort': localPort,
      'relayHost': relayHost,
      'relayPort': relayPort,
      'relayToken': relayToken,
      'userId': userId,
      'cloudUrl': cloudUrl,
      'useMdns': useMdns,
      'lastUpdated': lastUpdated?.toIso8601String(),
      'systemConfig': systemConfig?.toJson(),
    };
  }

  /// Copy and modify configuration
  ConnectionConfig copyWith({
    ConnectionMode? preferredMode,
    String? localIp,
    int? localPort,
    String? relayHost,
    int? relayPort,
    String? relayToken,
    String? userId,
    String? cloudUrl,
    bool? useMdns,
    DateTime? lastUpdated,
    SystemProxyConfig? systemConfig,
  }) {
    return ConnectionConfig(
      preferredMode: preferredMode ?? this.preferredMode,
      localIp: localIp ?? this.localIp,
      localPort: localPort ?? this.localPort,
      relayHost: relayHost ?? this.relayHost,
      relayPort: relayPort ?? this.relayPort,
      relayToken: relayToken ?? this.relayToken,
      userId: userId ?? this.userId,
      cloudUrl: cloudUrl ?? this.cloudUrl,
      useMdns: useMdns ?? this.useMdns,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      systemConfig: systemConfig ?? this.systemConfig,
    );
  }
}
