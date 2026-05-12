import os
import json
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
        # src/config/manager.py -> src/config -> src -> root
        self.project_root = Path(__file__).parent.parent.parent.absolute()
        self.config_path = self.project_root / "acp_config.json"
        self._config: Dict[str, Any] = {}
        self._load_defaults()
        
        # Also ensure the DB path defaults to the project root or a specific data dir
        self._config["system"]["db_path"] = str(self.project_root / "src/config/kanban.db")
        
        self._load_from_file()
        self._load_from_env()
        
        self._initialized = True
        logger.info(f"ConfigManager initialized. Project root: {self.project_root}")

    def _load_defaults(self):
        """Set default values for all configurations."""
        self._config = {
            "system": {
                "db_path": str(self.project_root / "kanban.db"),
                "workspace_root": str(Path.home()),
                "log_level": "INFO",
            },
            "relay": {
                "url": "wss://mybot.siliconpulse.cc",
                "token": "default_secret",
                "user_id": "test_user",
            },
            "providers": {
                "default": "gemini",
                "list": []
            },
            "cloud": {
                "api_key": os.getenv("KANBAN_API_KEY", ""),
                "base_url": os.getenv("KANBAN_BASE_URL", "https://api.openai.com/v1"),
                "model_id": os.getenv("KANBAN_MODEL_ID", "gpt-4o-mini"),
            }
        }

    def _load_from_file(self):
        """Load configuration from acp_config.json if it exists."""
        if self.config_path.exists():
            try:
                with open(self.config_path, "r") as f:
                    file_config = json.load(f)
                    
                # Map old acp_config.json structure to new unified structure
                if "providers" in file_config:
                    self._config["providers"]["list"] = file_config["providers"]
                if "default_provider" in file_config:
                    self._config["providers"]["default"] = file_config["default_provider"]
                if "max_sessions" in file_config:
                    self._config["system"]["max_sessions"] = file_config["max_sessions"]
                
                # Merge other root-level keys if any
                for key in ["relay", "system", "cloud"]:
                    if key in file_config:
                        self._config[key].update(file_config[key])
                        
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
            
        # Relay
        if os.getenv("RELAY_URL"):
            self._config["relay"]["url"] = os.getenv("RELAY_URL")
        if os.getenv("RELAY_TOKEN"):
            self._config["relay"]["token"] = os.getenv("RELAY_TOKEN")
        if os.getenv("USER_ID"):
            self._config["relay"]["user_id"] = os.getenv("USER_ID")

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

# Global instance
config = ConfigManager()
