import os
import base64
import json
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

KEY_STORAGE_PATH = Path.home() / ".mybot" / "e2ee_keys.json"


class E2EEManager:
    def __init__(self, session_key_hex=None):
        self.key = None
        self.aesgcm = None
        if session_key_hex:
            self.setup_session(session_key_hex)
        else:
            import warnings

            warnings.warn(
                "E2EE initialized without a session key. Encryption will fail until setup_session is called."
            )

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
        private_bytes = private_key.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        public_key = private_key.public_key()
        public_bytes = public_key.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        return private_bytes.hex(), public_bytes.hex()

    @staticmethod
    def derive_shared_secret(private_key, peer_public_hex):
        # Convert hex private key to object if needed
        if isinstance(private_key, str):
            private_key_obj = x25519.X25519PrivateKey.from_private_bytes(
                bytes.fromhex(private_key)
            )
        else:
            private_key_obj = private_key

        peer_public_key = x25519.X25519PublicKey.from_public_bytes(
            bytes.fromhex(peer_public_hex)
        )
        shared_key = private_key_obj.exchange(peer_public_key)
        derived_key = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=b"mybot-e2ee-x25519-context",
        ).derive(shared_key)
        return derived_key.hex()

    def encrypt(self, plaintext_str):
        if not self.is_ready:
            raise RuntimeError("E2EE engine not initialized with session key")
        nonce = os.urandom(12)
        # Returns ciphertext + 16 bytes tag
        ciphertext = self.aesgcm.encrypt(nonce, plaintext_str.encode(), None)
        payload = nonce + ciphertext
        return base64.b64encode(payload).decode("utf-8")

    def decrypt(self, b64_payload):
        if not self.is_ready:
            raise RuntimeError("E2EE engine not initialized with session key")
        payload = base64.b64decode(b64_payload)
        nonce = payload[:12]
        ciphertext = payload[12:]
        # Decrypts and verifies the 16 bytes tag at the end of ciphertext
        plaintext = self.aesgcm.decrypt(nonce, ciphertext, None)
        return plaintext.decode("utf-8")

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
            "params": {"payload": encrypted_payload},
        }

    def unwrap_json_rpc(self, envelope_str):
        data = json.loads(envelope_str)
        if data.get("method") == "e2ee/envelope":
            payload = data["params"]["payload"]
            decrypted_str = self.decrypt(payload)
            return json.loads(decrypted_str)
        return data

    @staticmethod
    def save_key_pair(user_id: str, private_key_hex: str, public_key_hex: str):
        keys = {}
        if KEY_STORAGE_PATH.exists():
            try:
                with open(KEY_STORAGE_PATH, "r") as f:
                    keys = json.load(f)
            except (json.JSONDecodeError, ValueError):
                # If corrupted, start fresh
                keys = {}

        keys[user_id] = {
            "private_key": private_key_hex,
            "public_key": public_key_hex,
        }

        with open(KEY_STORAGE_PATH, "w") as f:
            json.dump(keys, f)

        os.chmod(KEY_STORAGE_PATH, 0o600)

    @staticmethod
    def load_key_pair(user_id: str):
        if not KEY_STORAGE_PATH.exists():
            return None

        try:
            with open(KEY_STORAGE_PATH, "r") as f:
                keys = json.load(f)
        except (json.JSONDecodeError, ValueError):
            return None

        if isinstance(keys, dict) and user_id in keys:
            return keys[user_id]["private_key"], keys[user_id]["public_key"]
        return None

    @staticmethod
    def delete_key_pair(user_id: str):
        if not KEY_STORAGE_PATH.exists():
            return

        try:
            with open(KEY_STORAGE_PATH, "r") as f:
                keys = json.load(f)
        except (json.JSONDecodeError, ValueError):
            return

        if isinstance(keys, dict) and user_id in keys:
            del keys[user_id]
            with open(KEY_STORAGE_PATH, "w") as f:
                json.dump(keys, f)

