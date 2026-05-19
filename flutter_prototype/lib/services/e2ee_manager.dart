import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class E2EEManager {
  List<int>? _secretKeyBytes;
  bool _isReady = false;

  // Use cryptography's AES-GCM implementation
  final _algorithm = AesGcm.with256bits(nonceLength: 12);

  E2EEManager(String? keyHex) {
    if (keyHex != null) {
      setupSession(keyHex);
    }
  }

  void setupSession(String keyHex) {
    _secretKeyBytes = _hexToBytes(keyHex);
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
  static Future<String> deriveSharedSecret(
      KeyPair ownKeyPair, String peerPublicHex) async {
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

  /// Encrypts plaintext using AES-GCM (cryptography package).
  /// Output Format: [Nonce (12 bytes)] + [Ciphertext] + [Tag (16 bytes)]
  Future<String> encrypt(String plaintext) async {
    if (!_isReady) throw Exception('E2EE session not ready');

    final secretKey = await _algorithm.newSecretKeyFromBytes(_secretKeyBytes!);
    final nonce = _algorithm.newNonce(); // 12 bytes random

    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );

    // Concatenate: Nonce + Ciphertext + Mac (Tag)
    final combined = Uint8List.fromList(
        secretBox.nonce + secretBox.cipherText + secretBox.mac.bytes);

    return base64.encode(combined);
  }

  /// Decrypts AES-GCM payload.
  Future<String> decrypt(String b64Payload) async {
    if (!_isReady) throw Exception('E2EE session not ready');

    final payload = base64.decode(b64Payload);
    if (payload.length < 12 + 16) {
      throw Exception('Invalid E2EE payload: Too short');
    }

    final nonce = payload.sublist(0, 12);
    final tagStart = payload.length - 16;
    final cipherText = payload.sublist(12, tagStart);
    final macBytes = payload.sublist(tagStart);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final secretKey = await _algorithm.newSecretKeyFromBytes(_secretKeyBytes!);

    final decryptedBytes = await _algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return utf8.decode(decryptedBytes);
  }

  Future<Map<String, dynamic>> wrap(Map<String, dynamic> data) async {
    final plaintext = jsonEncode(data);
    return {
      "jsonrpc": "2.0",
      "method": "e2ee/envelope",
      "params": {"payload": await encrypt(plaintext)}
    };
  }

  Future<Map<String, dynamic>> unwrap(Map<String, dynamic> data) async {
    if (data.containsKey('method') && data['method'] == 'e2ee/envelope') {
      final payload = data['params']['payload'];
      final decryptedStr = await decrypt(payload);
      return jsonDecode(decryptedStr);
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
