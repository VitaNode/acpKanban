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
        self.key = None
        self.aesgcm = None
        if session_key_hex:
            self.setup_session(session_key_hex)
        else:
            import warnings
            warnings.warn("E2EE initialized without a session key. Encryption will fail until setup_session is called.")

    def setup_session(self, session_key_hex):
        """Initializes the AES-GCM engine with a real session key."""
        self.key = bytes.fromhex(session_key_hex)
        self.aesgcm = AESGCM(self.key)

    @property
    def is_ready(self):
        return self.aesgcm is not None

    @staticmethod
    def generate_key_pair():
        private_key = x25519.X25519PrivateKey.generate()
        public_key = private_key.public_key()
        public_bytes = public_key.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw
        )
        return private_key, public_bytes.hex()

    @staticmethod
    def derive_shared_secret(private_key, peer_public_hex):
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
        if not self.is_ready:
            raise RuntimeError("E2EE engine not initialized with session key")
        nonce = os.urandom(12)
        # Returns ciphertext + 16 bytes tag
        ciphertext = self.aesgcm.encrypt(nonce, plaintext_str.encode(), None)
        payload = nonce + ciphertext
        return base64.b64encode(payload).decode('utf-8')

    def decrypt(self, b64_payload):
        if not self.is_ready:
            raise RuntimeError("E2EE engine not initialized with session key")
        payload = base64.b64decode(b64_payload)
        nonce = payload[:12]
        ciphertext = payload[12:]
        # Decrypts and verifies the 16 bytes tag at the end of ciphertext
        plaintext = self.aesgcm.decrypt(nonce, ciphertext, None)
        return plaintext.decode('utf-8')

    def wrap_json_rpc(self, data):
        """
        Wrap data in E2EE envelope.
        
        Args:
            data: Dictionary to encrypt
            
        Returns:
            Dictionary (not JSON string) for consistent API
        """
        plaintext = json.dumps(data)
        encrypted_payload = self.encrypt(plaintext)
        return {
            "jsonrpc": "2.0",
            "method": "e2ee/envelope",
            "params": {"payload": encrypted_payload}
        }

    def unwrap_json_rpc(self, envelope_str):
        data = json.loads(envelope_str)
        if data.get("method") == "e2ee/envelope":
            payload = data["params"]["payload"]
            decrypted_str = self.decrypt(payload)
            return json.loads(decrypted_str)
        return data
