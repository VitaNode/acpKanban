import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket connection implementation for native platforms (macOS, iOS, Android, Linux, Windows)
Future<WebSocketChannel?> connectWebSocket(String url, String? token) async {
  try {
    final uri = Uri.parse(url);
    final headers =
        token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};
    final channel = IOWebSocketChannel.connect(uri, headers: headers);
    await channel.ready.timeout(const Duration(seconds: 3));
    return channel;
  } catch (e) {
    print('[SmartConnect] Connection failed: $e');
    return null;
  }
}
