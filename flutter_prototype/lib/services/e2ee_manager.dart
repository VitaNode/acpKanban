import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:cryptography/cryptography.dart';

class E2EEManager {
  final enc.Key key;
  
  E2EEManager(String keyHex) : key = enc.Key.fromBase16(keyHex);

  /// Generates a private/public key pair for ECDH.
  /// Returns a Map with 'privateKey' (object) and 'publicKeyHex' (string).
  static Future<Map<String, dynamic>> generateKeyPair() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;
    
    return {
      'privateKey': keyPair,
      'publicKeyHex': _bytesToHex(Uint8List.fromList(publicKeyBytes)),
    };
  }

  /// Derives a 32-byte shared secret using X25519 + HKDF.
  static Future<String> deriveSharedSecret(KeyPair ownKeyPair, String peerPublicHex) async {
    final algorithm = X25519();
    final peerPublicKey = SimplePublicKey(
      _hexToBytes(peerPublicHex),
      type: KeyPairType.x25519,
    );

    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: ownKeyPair,
      remotePublicKey: peerPublicKey,
    );

    // HKDF Expansion (Matching Python's info string)
    final hkdf = Hkdf(
      hmac: Hmac(Sha256()),
      outputLength: 32,
    );

    final derivedKey = await hkdf.deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode('mybot-e2ee-x25519-context'),
    );

    final keyBytes = await derivedKey.extractBytes();
    return _bytesToHex(Uint8List.fromList(keyBytes));
  }

  String encrypt(String plaintext) {
    final iv = enc.IV.fromSecureRandom(12);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm, padding: null));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    return base64.encode(combined);
  }

  String decrypt(String b64Payload) {
    final payload = base64.decode(b64Payload);
    if (payload.length < 12) throw Exception('Payload too short');
    final iv = enc.IV(payload.sublist(0, 12));
    final ciphertext = payload.sublist(12);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm, padding: null));
    return encrypter.decrypt(enc.Encrypted(ciphertext), iv: iv);
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
      return jsonDecode(decrypt(payload));
    }
    return data;
  }

  // Helper utils
  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
