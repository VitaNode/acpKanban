import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/connection_config.dart';

// Conditional import for platform-specific WebSocket connection
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
    int localPort = 8766,
    bool useMdns = true,
    String? relayHost,
    int relayPort = 8766,
    String? relayToken,
    String? userId,
    String? cloudUrl,
  }) async {
    // Both Local and Relay modes in the new UI use the Relay protocol
    // to tunnel through the Bridge for security (since API is on 127.0.0.1).

    String? targetHost;
    int targetPort;
    ConnectionPath path;

    switch (mode) {
      case ConnectionMode.local:
        targetHost = localIp ?? 'localhost';
        targetPort = localPort;
        path = ConnectionPath.local;
        break;
      case ConnectionMode.relay:
        targetHost = relayHost;
        targetPort = relayPort;
        path = ConnectionPath.relay;
        break;
      case ConnectionMode.cloud:
        // Cloud mode remains for direct SaaS connection if needed
        final targetUrl =
            cloudUrl ?? 'ws://${relayHost ?? "localhost"}:$relayPort/direct';
        return _connectStrict(targetUrl, ConnectionPath.cloud, relayToken);
    }

    if (userId != null && targetHost != null) {
      // Use Relay/Bridge Tunnel protocol
      // If targetHost already has a scheme, don't add ws://
      String relayUrl;
      if (targetHost.startsWith('ws://') || targetHost.startsWith('wss://')) {
        relayUrl = '$targetHost:$targetPort/relay/app/$userId';
      } else {
        relayUrl = 'ws://$targetHost:$targetPort/relay/app/$userId';
      }

      print('[SmartConnect] Attempting Bridge Tunnel ($mode): $relayUrl');
      return _connectStrict(relayUrl, path, relayToken);
    }

    // Fallback/Legacy logic if userId is missing
    if (mode == ConnectionMode.local) {
      return _connectLocal(
          localIp: localIp,
          localPort: localPort,
          useMdns: useMdns,
          token: relayToken);
    }

    throw Exception('Connection failed. Missing userId or target host.');
  }

  static Future<SmartConnectResult> _connectLocal({
    String? localIp,
    int localPort = 8766,
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
          final localUrl = "ws://$discoveredIp:$localPort";
          print('[SmartConnect] Attempting Local (mDNS): $localUrl');
          final channel = await _tryConnect(localUrl, token);
          if (channel != null) {
            print('[SmartConnect] Local (mDNS) connection established: $localUrl');
            return SmartConnectResult(channel, ConnectionPath.local, localUrl);
          }
          print('[SmartConnect] Local (mDNS) connection failed (returned null): $localUrl');
        } else {
          print('[SmartConnect] No local Mac discovered via mDNS');
        }
      } catch (e) {
        print('[SmartConnect] mDNS scan or connection failed: $e');
      }
    }

    if (localIp != null) {
      final localUrl = "ws://$localIp:$localPort";
      print('[SmartConnect] Attempting Local (manual): $localUrl');
      final channel = await _tryConnect(localUrl, token);
      if (channel != null) {
        print('[SmartConnect] Local (manual) connection established: $localUrl');
        return SmartConnectResult(channel, ConnectionPath.local, localUrl);
      }
      print('[SmartConnect] Local (manual) connection failed: $localUrl');
    }

    throw Exception('Local connection failed. Check if Mac Bridge is running.');
  }

  static Future<SmartConnectResult> _connectStrict(
    String url,
    ConnectionPath path,
    String? token,
  ) async {
    print('[SmartConnect] Attempting $path: $url');
    try {
      final channel = await _tryConnect(url, token);
      if (channel != null) {
        print('[SmartConnect] $path connection established: $url');
        return SmartConnectResult(channel, path, url);
      }
      print('[SmartConnect] $path connection failed (returned null): $url');
    } catch (e) {
      print('[SmartConnect] $path connection error: $e');
    }
    throw Exception('$path connection failed. Check network and settings.');
  }

  static Future<String?> discoverLocalMac() async {
    if (kIsWeb) return null;

    final MDnsClient client = MDnsClient();
    try {
      // Phase 5.3 FIX: Even client.start() can throw if OS restricts UDP 5353
      try {
        await client.start();
      } catch (e) {
        print('[SmartConnect] mDNS client start failed: $e');
        return null;
      }

      final String? ip = await (() async {
        try {
          // Phase 5.3 FIX: In some environments, even calling lookup() can throw
          // a synchronous SocketException before the stream is returned.
          Stream<PtrResourceRecord>? lookupStream;
          try {
            lookupStream = client.lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer(_serviceType));
          } catch (e) {
            print('[SmartConnect] mDNS lookup sync error: $e');
            return null;
          }

          if (lookupStream == null) return null;

          await for (final PtrResourceRecord ptr in lookupStream
              .handleError((e) => print('mDNS Stream Error: $e'))) {
            try {
              final srvStream = client.lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName));

              await for (final SrvResourceRecord srv in srvStream
                  .handleError((e) => print('SRV Stream Error: $e'))) {
                try {
                  final ipStream = client.lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target));

                  await for (final IPAddressResourceRecord ipRecord in ipStream
                      .handleError((e) => print('IP Stream Error: $e'))) {
                    return ipRecord.address.address;
                  }
                } catch (ipE) {
                  print('IP Outer Error: $ipE');
                }
              }
            } catch (srvE) {
              print('SRV Outer Error: $srvE');
            }
          }
        } catch (lookupError) {
          print('[SmartConnect] mDNS lookup major error: $lookupError');
        }
        return null;
      })()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);

      return ip;
    } catch (e) {
      print('[SmartConnect] discoverLocalMac fatal catch: $e');
      return null;
    } finally {
      try {
        client.stop();
      } catch (_) {}
    }
  }

  static Future<WebSocketChannel?> _tryConnect(
      String url, String? token) async {
    // Direct call to platform-specific connection function
    return await connectWebSocket(url, token);
  }

  static String _getFriendlyErrorMessage(Object error) {
    final errorStr = error.toString();
    if (errorStr.contains('SocketException') || errorStr.contains('OSError')) {
      if (errorStr.contains('Connection refused')) {
        return 'Unable to connect to server. Please ensure:\n1. Server is running\n2. Address is correct\n3. Firewall is not blocking the connection';
      }
      if (errorStr.contains('Connection timed out') ||
          errorStr.contains('TimeoutException')) {
        return 'Connection timed out. Please check your network or server status.';
      }
      if (errorStr.contains('No route to host') ||
          errorStr.contains('Network is unreachable')) {
        return 'Network unreachable. Please check your connection.';
      }
      return 'Network error: ${errorStr.length > 100 ? errorStr.substring(0, 100) : errorStr}';
    }
    if (error is TimeoutException) {
      return 'Connection timed out. Please check your network or server status.';
    }
    return errorStr;
  }
}
