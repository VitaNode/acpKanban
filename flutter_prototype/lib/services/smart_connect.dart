import 'dart:async';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
    String? preferredLocalIp,
    String? relayUrl,
    String? cloudUrl,
    String? token,
    String? userId,
  }) async {
    // 1. Try mDNS Discovery with Timeout
    print('[SmartConnect] Starting mDNS scan...');
    final discoveredIp = await discoverLocalMac().timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
    
    final targetLocalIp = discoveredIp ?? preferredLocalIp;

    if (targetLocalIp != null) {
      final localUrl = "ws://$targetLocalIp:8766";
      print('[SmartConnect] Attempting Local Path: $localUrl');
      final channel = await _tryConnect(localUrl, token);
      if (channel != null) return SmartConnectResult(channel, ConnectionPath.local, localUrl);
    }

    // 2. Try Relay Path
    if (relayUrl != null) {
      print('[SmartConnect] Attempting Relay Path: $relayUrl');
      final channel = await _tryConnect(relayUrl, token);
      if (channel != null) return SmartConnectResult(channel, ConnectionPath.relay, relayUrl);
    }

    // 3. Try Cloud Path
    if (cloudUrl != null) {
      print('[SmartConnect] Attempting Cloud Path: $cloudUrl');
      final channel = await _tryConnect(cloudUrl, token);
      if (channel != null) return SmartConnectResult(channel, ConnectionPath.cloud, cloudUrl);
    }

    throw Exception('All connection paths failed. Mac may be offline.');
  }

  static Future<String?> discoverLocalMac() async {
    final MDnsClient client = MDnsClient();
    await client.start();
    try {
      // Internal scanner with internal loop
      final String? ip = await (() async {
        await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_serviceType))) {
          await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName))) {
            await for (final IPAddressResourceRecord ipRecord in client.lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target))) {
              return ipRecord.address.address;
            }
          }
        }
        return null;
      })().timeout(const Duration(seconds: 2), onTimeout: () => null);
      
      return ip;
    } catch (e) {
      print("[SmartConnect] mDNS error: $e");
      return null;
    } finally {
      client.stop();
    }
  }

  static Future<WebSocketChannel?> _tryConnect(String url, String? token) async {
    try {
      final uri = Uri.parse(url);
      final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};
      final channel = IOWebSocketChannel.connect(uri, headers: headers);
      await channel.ready.timeout(const Duration(seconds: 3));
      return channel;
    } catch (e) {
      print('[SmartConnect] Connection to $url failed: $e');
      return null;
    }
  }
}
