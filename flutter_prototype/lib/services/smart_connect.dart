import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/connection_config.dart';

// 条件导入平台特定的 WebSocket 连接函数
import 'websocket_connect_io.dart'
    if (dart.library.html) 'websocket_connect_web.dart';

enum ConnectionPath { local, relay, cloud, none }

class SmartConnectResult {
  final WebSocketChannel channel;
  final ConnectionPath path;
  final String url;

  SmartConnectResult(this.channel, this.path, this.url);
}

class SmartConnect {
  static const String _serviceType = '_acp._tcp.local';

  static Future<SmartConnectResult> connect({
    required ConnectionMode mode,
    String? localIp,
    bool useMdns = true,
    String? relayHost,
    int relayPort = 8766,
    String? relayToken,
    String? userId,
    String? cloudUrl,
  }) async {
    if (mode == ConnectionMode.local && kIsWeb) {
      throw Exception('本地连接模式不支持 Web 平台，请选择中继或云端模式');
    }

    switch (mode) {
      case ConnectionMode.local:
        return _connectLocal(
            localIp: localIp, useMdns: useMdns, token: relayToken);
      case ConnectionMode.relay:
        if (relayHost == null || userId == null) {
          throw Exception('Relay mode requires relayHost and userId');
        }
        final relayUrl = 'ws://$relayHost:$relayPort/relay/app/$userId';
        return _connectStrict(relayUrl, ConnectionPath.relay, relayToken);
      case ConnectionMode.cloud:
        final targetUrl = cloudUrl ?? 'ws://$relayHost:$relayPort/direct';
        return _connectStrict(targetUrl, ConnectionPath.cloud, relayToken);
    }
  }

  static Future<SmartConnectResult> _connectLocal({
    String? localIp,
    bool useMdns = true,
    String? token,
  }) async {
    if (kIsWeb) {
      throw Exception('Local mode not supported on Web');
    }

    if (useMdns) {
      print('[SmartConnect] Starting mDNS scan...');
      try {
        final discoveredIp = await discoverLocalMac().timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );

        if (discoveredIp != null) {
          final localUrl = "ws://$discoveredIp:8766";
          print('[SmartConnect] Attempting Local (mDNS): $localUrl');
          final channel = await _tryConnect(localUrl, token);
          if (channel != null) {
            return SmartConnectResult(channel, ConnectionPath.local, localUrl);
          }
        }
      } catch (e) {
        print('[SmartConnect] mDNS scan failed: $e');
      }
    }

    if (localIp != null) {
      final localUrl = "ws://$localIp:8766";
      print('[SmartConnect] Attempting Local (manual): $localUrl');
      final channel = await _tryConnect(localUrl, token);
      if (channel != null) {
        return SmartConnectResult(channel, ConnectionPath.local, localUrl);
      }
    }

    throw Exception('Local connection failed. Check if Mac Bridge is running.');
  }

  static Future<SmartConnectResult> _connectStrict(
    String url,
    ConnectionPath path,
    String? token,
  ) async {
    print('[SmartConnect] Attempting $path: $url');
    final channel = await _tryConnect(url, token);
    if (channel != null) {
      return SmartConnectResult(channel, path, url);
    }
    throw Exception('$path connection failed. Check network and settings.');
  }

  static Future<String?> discoverLocalMac() async {
    if (kIsWeb) return null;

    final MDnsClient client = MDnsClient();
    try {
      // Phase 5.3 FIX: On iOS, start() can throw SocketException if permission is denied
      await client.start().catchError((e) {
        print('[SmartConnect] mDNS client start failed: $e');
        return;
      });
      
      final String? ip = await (() async {
        try {
          await for (final PtrResourceRecord ptr
              in client.lookup<PtrResourceRecord>(
                  ResourceRecordQuery.serverPointer(_serviceType))) {
            await for (final SrvResourceRecord srv
                in client.lookup<SrvResourceRecord>(
                    ResourceRecordQuery.service(ptr.domainName))) {
              await for (final IPAddressResourceRecord ipRecord
                  in client.lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target))) {
                return ipRecord.address.address;
              }
            }
          }
        } catch (lookupError) {
          print('[SmartConnect] mDNS lookup error: $lookupError');
        }
        return null;
      })()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);

      return ip;
    } catch (e) {
      print('[SmartConnect] discoverLocalMac outer catch: $e');
      return null;
    } finally {
      try {
        client.stop();
      } catch (_) {}
    }
  }

  static Future<WebSocketChannel?> _tryConnect(
      String url, String? token) async {
    // 直接调用平台特定的连接函数
    return await connectWebSocket(url, token);
  }

  static String _getFriendlyErrorMessage(Object error) {
    final errorStr = error.toString();
    if (errorStr.contains('SocketException') || errorStr.contains('OSError')) {
      if (errorStr.contains('Connection refused')) {
        return '无法连接到服务器，请确认：\n1. 服务器已启动\n2. 地址正确\n3. 防火墙未阻止连接';
      }
      if (errorStr.contains('Connection timed out') ||
          errorStr.contains('TimeoutException')) {
        return '连接超时，请检查网络或服务器状态';
      }
      if (errorStr.contains('No route to host') ||
          errorStr.contains('Network is unreachable')) {
        return '网络不可达，请检查网络连接';
      }
      return '网络错误：${errorStr.length > 100 ? errorStr.substring(0, 100) : errorStr}';
    }
    if (error is TimeoutException) {
      return '连接超时，请检查网络或服务器状态';
    }
    return errorStr;
  }
}
