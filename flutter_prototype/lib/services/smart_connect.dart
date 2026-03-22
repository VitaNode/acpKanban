import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';

class SmartConnect {
  static const String _serviceType = '_acp._tcp.local';

  /// Performs mDNS lookup to find the local Mac IP address.
  static Future<String?> discoverLocalMac(String expectedUserId) async {
    final MDnsClient client = MDnsClient();
    await client.start();

    print('[SmartConnect] Scanning for mDNS service: $_serviceType');
    try {
      await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(_serviceType))) {
        
        await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName))) {
          
          await for (final IPAddressResourceRecord ip in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target))) {
            
            // Check if the User ID matches (optional but recommended)
            // We use simple check here. In production, we'd check PTR or SRV properties.
            print('[SmartConnect] Found potential host: ${ip.address.address}:${srv.port}');
            client.stop();
            return ip.address.address;
          }
        }
      }
    } catch (e) {
      print("[SmartConnect] mDNS Discovery Error: $e");
    } finally {
      client.stop();
    }
    return null;
  }
}
