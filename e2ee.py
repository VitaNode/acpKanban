import os
import base64
import json
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

class E2EEManager:
    def __init__(self, key_hex=None):
        # 32 bytes (256 bits) key
        if key_hex:
            self.key = bytes.fromhex(key_hex)
        else:
            # For testing, use a default key if none provided
            # In production, this must be securely shared between Mac and App
            self.key = b'my_bot_default_32_byte_secret_key'[:32]
        
        self.aesgcm = AESGCM(self.key)

    def encrypt(self, plaintext_str):
        """Encrypts a string and returns a base64 encoded payload."""
        nonce = os.urandom(12)
        ciphertext = self.aesgcm.encrypt(nonce, plaintext_str.encode(), None)
        # Result: [nonce (12b)] + [ciphertext]
        payload = nonce + ciphertext
        return base64.b64encode(payload).decode('utf-8')

    def decrypt(self, b64_payload):
        """Decrypts a base64 encoded payload and returns the original string."""
        payload = base64.b64decode(b64_payload)
        nonce = payload[:12]
        ciphertext = payload[12:]
        plaintext = self.aesgcm.decrypt(nonce, ciphertext, None)
        return plaintext.decode('utf-8')

    def wrap_json_rpc(self, data):
        """Wraps a JSON-RPC dict into an encrypted envelope."""
        plaintext = json.dumps(data)
        encrypted_payload = self.encrypt(plaintext)
        return json.dumps({
            "jsonrpc": "2.0",
            "method": "e2ee/envelope",
            "params": {
                "payload": encrypted_payload
            }
        })

    def unwrap_json_rpc(self, envelope_str):
        """Unwraps an encrypted envelope back to a JSON-RPC dict."""
        data = json.loads(envelope_str)
        if data.get("method") == "e2ee/envelope":
            payload = data["params"]["payload"]
            decrypted_str = self.decrypt(payload)
            return json.loads(decrypted_str)
        return data
