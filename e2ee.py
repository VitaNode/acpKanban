import os
import base64
import json
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

class E2EEManager:
    def __init__(self, session_key_hex=None):
        if session_key_hex:
            self.key = bytes.fromhex(session_key_hex)
        else:
            self.key = b'my_bot_default_32_byte_secret_key'[:32]
        
        self.aesgcm = AESGCM(self.key)

    @staticmethod
    def generate_key_pair():
        """Generates a private/public key pair using X25519."""
        private_key = x25519.X25519PrivateKey.generate()
        public_key = private_key.public_key()
        
        public_bytes = public_key.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw
        )
        # Return hex for easier transport in QR or code
        return private_key, public_bytes.hex()

    @staticmethod
    def derive_shared_secret(private_key, peer_public_hex):
        """Derives a 32-byte shared secret using X25519 + HKDF."""
        peer_public_key = x25519.X25519PublicKey.from_public_bytes(
            bytes.fromhex(peer_public_hex)
        )
        shared_key = private_key.exchange(peer_public_key)
        
        derived_key = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=b'mybot-e2ee-x25519-context',
        ).derive(shared_key)
        
        return derived_key.hex()

    def encrypt(self, plaintext_str):
        nonce = os.urandom(12)
        ciphertext = self.aesgcm.encrypt(nonce, plaintext_str.encode(), None)
        payload = nonce + ciphertext
        return base64.b64encode(payload).decode('utf-8')

    def decrypt(self, b64_payload):
        payload = base64.b64decode(b64_payload)
        nonce = payload[:12]
        ciphertext = payload[12:]
        plaintext = self.aesgcm.decrypt(nonce, ciphertext, None)
        return plaintext.decode('utf-8')

    def wrap_json_rpc(self, data):
        plaintext = json.dumps(data)
        encrypted_payload = self.encrypt(plaintext)
        return json.dumps({
            "jsonrpc": "2.0",
            "method": "e2ee/envelope",
            "params": {"payload": encrypted_payload}
        })

    def unwrap_json_rpc(self, envelope_str):
        data = json.loads(envelope_str)
        if data.get("method") == "e2ee/envelope":
            payload = data["params"]["payload"]
            decrypted_str = self.decrypt(payload)
            return json.loads(decrypted_str)
        return data
