import os
import json
import secrets
import string
from src.logger import setup_logger
from pathlib import Path
from typing import Any, Dict, Optional
from dotenv import load_dotenv

logger = setup_logger("ConfigManager")
load_dotenv()

class ConfigManager:
    _instance = None
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(ConfigManager, cls).__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
            
        # Point to the actual project root (mybot/)
        self.project_root = Path(__file__).parent.parent.parent.absolute()
        self.config_path = self.project_root / "config.json"
        self.old_config_path = self.project_root / "acp_config.json"
        
        self._config: Dict[str, Any] = {}
        self._load_defaults()
        self._migrate_old_config()
        self._load_from_file()
        self._load_from_env()
        self._ensure_credentials()
        self._save_to_file()
        
        self._initialized = True
        logger.info(f"ConfigManager initialized. Project root: {self.project_root}")

    def _load_defaults(self):
        """Set default values for all configurations."""
        self._config = {
            "system": {
                "db_path": str(self.project_root / "kanban.db"),
                "workspace_root": str(Path.home()),
                "log_level": "INFO",
                "max_sessions": 30,
                "session_idle_timeout_minutes": 30,
                "api_token": "",
                "api_bind_host": "127.0.0.1",
                "bridge_bind_host": "127.0.0.1"
            },
            "relay": {
                "url": "",
                "token": "",
                "user_id": "",
            },
            "providers": {
                "default": "gemini",
                "list": []
            },
            "system_agent": {
                "api_key": os.getenv("KANBAN_API_KEY", ""),
                "base_url": os.getenv("KANBAN_BASE_URL", "https://api.openai.com/v1"),
                "summary_model": os.getenv("SUMMARY_MODEL", "gpt-4o-mini"),
                "embedding_model": os.getenv("EMBEDDING_MODEL", "text-embedding-3-small"),
            }
        }

    def _migrate_old_config(self):
        """Migrate settings from acp_config.json if config.json doesn't exist."""
        if not self.config_path.exists() and self.old_config_path.exists():
            try:
                with open(self.old_config_path, "r") as f:
                    old_data = json.load(f)
                
                if "providers" in old_data:
                    self._config["providers"]["list"] = old_data["providers"]
                if "default_provider" in old_data:
                    self._config["providers"]["default"] = old_data["default_provider"]
                if "max_sessions" in old_data:
                    self._config["system"]["max_sessions"] = old_data["max_sessions"]
                if "session_idle_timeout_minutes" in old_data:
                    self._config["system"]["session_idle_timeout_minutes"] = old_data["session_idle_timeout_minutes"]
                
                logger.info(f"Migrated old config from {self.old_config_path}")
            except Exception as e:
                logger.error(f"Failed to migrate old config: {e}")

    def _load_from_file(self):
        """Load configuration from config.json if it exists."""
        if self.config_path.exists():
            try:
                with open(self.config_path, "r") as f:
                    file_config = json.load(f)
                
                # Migrate 'cloud' to 'system_agent' if found
                if "cloud" in file_config and "system_agent" not in file_config:
                    logger.info("Migrating 'cloud' config to 'system_agent'")
                    cloud = file_config["cloud"]
                    file_config["system_agent"] = {
                        "api_key": cloud.get("api_key", ""),
                        "base_url": cloud.get("base_url", "https://api.openai.com/v1"),
                        "summary_model": cloud.get("model_id", "gpt-4o-mini"),
                        "embedding_model": "text-embedding-3-small"
                    }
                
                # Deep merge for top-level keys
                for key in ["system", "relay", "providers", "system_agent"]:
                    if key in file_config and isinstance(file_config[key], dict):
                        self._config[key].update(file_config[key])
                    elif key in file_config:
                        self._config[key] = file_config[key]
                        
                logger.info(f"Loaded config from {self.config_path}")
            except Exception as e:
                logger.error(f"Failed to load config file: {e}")

    def _load_from_env(self):
        """Override configuration with environment variables."""
        # System
        if os.getenv("KANBAN_DB_PATH"):
            self._config["system"]["db_path"] = os.getenv("KANBAN_DB_PATH")
        if os.getenv("WORKSPACE_ROOT"):
            self._config["system"]["workspace_root"] = os.getenv("WORKSPACE_ROOT")
        if os.getenv("API_TOKEN"):
            self._config["system"]["api_token"] = os.getenv("API_TOKEN")
            
        # Relay
        if os.getenv("RELAY_URL"):
            self._config["relay"]["url"] = os.getenv("RELAY_URL")
        if os.getenv("RELAY_TOKEN"):
            self._config["relay"]["token"] = os.getenv("RELAY_TOKEN")
        if os.getenv("USER_ID"):
            self._config["relay"]["user_id"] = os.getenv("USER_ID")

        # System Agent
        if os.getenv("KANBAN_API_KEY"):
            self._config["system_agent"]["api_key"] = os.getenv("KANBAN_API_KEY")
        if os.getenv("KANBAN_BASE_URL"):
            self._config["system_agent"]["base_url"] = os.getenv("KANBAN_BASE_URL")
        if os.getenv("SUMMARY_MODEL"):
            self._config["system_agent"]["summary_model"] = os.getenv("SUMMARY_MODEL")
        if os.getenv("EMBEDDING_MODEL"):
            self._config["system_agent"]["embedding_model"] = os.getenv("EMBEDDING_MODEL")

    def _ensure_credentials(self):
        """Ensure USER_ID, RELAY_TOKEN, and SYSTEM.API_TOKEN exist, generating them if necessary."""
        # 1. First check if they are already in the config (loaded from file or env)
        user_id = self._config["relay"].get("user_id")
        token = self._config["relay"].get("token")
        api_token = self._config["system"].get("api_token")

        # 2. If missing, generate strong random ones
        if not user_id:
            random_suffix = ''.join(secrets.choice(string.digits) for _ in range(6))
            self._config["relay"]["user_id"] = f"user_{random_suffix}"
            logger.info(f"Generated new USER_ID: {self._config['relay']['user_id']}")

        if not token:
            self._config["relay"]["token"] = secrets.token_urlsafe(32)
            logger.info("Generated new strong RELAY_TOKEN")

        if not api_token:
            self._config["system"]["api_token"] = secrets.token_urlsafe(32)
            logger.info("Generated new strong SYSTEM.API_TOKEN")

    def _save_to_file(self):
        """Persist current configuration to config.json."""
        try:
            with open(self.config_path, "w") as f:
                json.dump(self._config, f, indent=2)
            logger.info(f"Saved config to {self.config_path}")
        except Exception as e:
            logger.error(f"Failed to save config: {e}")

    def get(self, key_path: str, default: Any = None) -> Any:
        """
        Get a configuration value using a dot-separated path (e.g., 'system.db_path').
        """
        parts = key_path.split(".")
        val = self._config
        try:
            for part in parts:
                val = val[part]
            return val
        except (KeyError, TypeError):
            return default

    @property
    def providers(self) -> list:
        return self._config["providers"]["list"]

    @property
    def default_provider(self) -> str:
        return self._config["providers"]["default"]

    @property
    def db_path(self) -> str:
        return self._config["system"]["db_path"]

    @property
    def relay_url(self) -> str:
        return self._config["relay"]["url"]

    @property
    def user_id(self) -> str:
        return self._config["relay"]["user_id"]

    @property
    def relay_token(self) -> str:
        return self._config["relay"]["token"]

    @property
    def api_token(self) -> str:
        return self._config["system"]["api_token"]

    @property
    def api_bind_host(self) -> str:
        return self._config["system"].get("api_bind_host", "127.0.0.1")

    @property
    def bridge_bind_host(self) -> str:
        return self._config["system"].get("bridge_bind_host", "127.0.0.1")

    @property
    def system_agent_api_key(self) -> str:
        return self._config["system_agent"]["api_key"]

    @property
    def system_agent_base_url(self) -> str:
        return self._config["system_agent"]["base_url"]

    @property
    def summary_model(self) -> str:
        return self._config["system_agent"]["summary_model"]

    @property
    def embedding_model(self) -> str:
        return self._config["system_agent"]["embedding_model"]

# Global instance
config = ConfigManager()
