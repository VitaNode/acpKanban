import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:cryptography/cryptography.dart';

class E2EEManager {
  enc.Key? _key;
  bool _isReady = false;
  
  E2EEManager(String? keyHex) {
    if (keyHex != null) {
      setupSession(keyHex);
    }
  }

  void setupSession(String keyHex) {
    _key = enc.Key.fromBase16(keyHex);
    _isReady = true;
  }

  bool get isReady => _isReady;

  /// Generates a private/public key pair for ECDH using X25519.
  static Future<Map<String, dynamic>> generateKeyPair() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return {
      'privateKey': keyPair,
      'publicKeyHex': _bytesToHex(Uint8List.fromList(publicKey.bytes)),
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

    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final derivedKey = await hkdf.deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode('mybot-e2ee-x25519-context'),
    );

    final keyBytes = await derivedKey.extractBytes();
    return _bytesToHex(Uint8List.fromList(keyBytes));
  }

  /// Encrypts plaintext using AES-GCM. 
  /// Result: [Nonce (12 bytes)] + [Ciphertext] + [Tag (16 bytes)]
  String encrypt(String plaintext) {
    if (!_isReady) throw Exception('E2EE session not ready');
    
    final iv = enc.IV.fromSecureRandom(12);
    final encrypter = enc.Encrypter(enc.AES(_key!, mode: enc.AESMode.gcm, padding: null));
    
    // In 'encrypt' package with PointyCastle, the result of GCM encryption 
    // already appends the authentication tag to the ciphertext bytes.
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    return base64.encode(combined);
  }

  /// Decrypts AES-GCM payload.
  /// Payload must contain: Nonce (12) + Data + Tag (16)
  String decrypt(String b64Payload) {
    if (!_isReady) throw Exception('E2EE session not ready');
    
    final payload = base64.decode(b64Payload);
    if (payload.length < 12 + 16) {
      throw Exception('Invalid E2EE payload: Too short to contain Nonce and Tag');
    }
    
    final iv = enc.IV(payload.sublist(0, 12));
    final encryptedDataWithTag = payload.sublist(12);
    
    final encrypter = enc.Encrypter(enc.AES(_key!, mode: enc.AESMode.gcm, padding: null));
    return encrypter.decrypt(enc.Encrypted(encryptedDataWithTag), iv: iv);
  }

  Map<String, dynamic> wrap(Map<String, dynamic> data) {
    return {
      "jsonrpc": "2.0",
      "method": "e2ee/envelope",
      "params": {"payload": encrypt(jsonEncode(data))}
    };
  }

  Map<String, dynamic> unwrap(Map<String, dynamic> data) {
    if (data.containsKey('method') && data['method'] == 'e2ee/envelope') {
      final payload = data['params']['payload'];
      return jsonDecode(decrypt(payload));
    }
    return data;
  }

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
