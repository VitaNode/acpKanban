import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket connection implementation for Web platform
Future<WebSocketChannel?> connectWebSocket(String url, String? token) async {
  try {
    final uri = Uri.parse(url);
    final webUrl = token != null
        ? uri.replace(queryParameters: {'token': token}).toString()
        : uri.toString();
    final channel = HtmlWebSocketChannel.connect(Uri.parse(webUrl));
    await channel.ready.timeout(const Duration(seconds: 3));
    return channel;
  } catch (e) {
    print('[SmartConnect] Connection failed: $e');
    return null;
  }
}
