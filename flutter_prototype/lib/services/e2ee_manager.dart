import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';

class E2EEManager {
  final Key key;
  
  E2EEManager(String keyHex) : key = Key.fromBase16(keyHex);

  /// Matches the Python implementation: [nonce (12 bytes)] + [ciphertext]
  String encrypt(String plaintext) {
    final iv = IV.fromSecureRandom(12);
    final encrypter = Encrypter(AES(key, mode: AESMode.gcm, padding: null));
    
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    return base64.encode(combined);
  }

  String decrypt(String b64Payload) {
    final payload = base64.decode(b64Payload);
    if (payload.length < 12) {
      throw Exception('Encrypted payload too short');
    }
    
    final iv = IV(payload.sublist(0, 12));
    final ciphertext = payload.sublist(12);
    
    final encrypter = Encrypter(AES(key, mode: AESMode.gcm, padding: null));
    return encrypter.decrypt(Encrypted(ciphertext), iv: iv);
  }

  Map<String, dynamic> wrap(Map<String, dynamic> data) {
    final plaintext = jsonEncode(data);
    return {
      "jsonrpc": "2.0",
      "method": "e2ee/envelope",
      "params": {"payload": encrypt(plaintext)}
    };
  }

  Map<String, dynamic> unwrap(Map<String, dynamic> data) {
    if (data.containsKey('method') && data['method'] == 'e2ee/envelope') {
      final payload = data['params']['payload'];
      final decryptedStr = decrypt(payload);
      return jsonDecode(decryptedStr);
    }
    return data;
  }
}
