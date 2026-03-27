import os
import json
from typing import List, Optional
from openai import OpenAI
from dotenv import load_dotenv

load_dotenv()


class EmbeddingService:
    _instance = None

    def __new__(cls, *args, **kwargs):
        if cls._instance is None:
            cls._instance = super(EmbeddingService, cls).__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self, model: str = "text-embedding-3-small", dimensions: int = 1536):
        if self._initialized:
            return
        self.model = model
        self.dimensions = dimensions

        api_key = os.getenv("KANBAN_API_KEY")
        base_url = os.getenv("KANBAN_BASE_URL", "https://api.openai.com/v1")

        if not api_key or api_key == "your_new_key_here":
            self.client = None
        else:
            self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=30.0)

        self._initialized = True

    def is_available(self) -> bool:
        return self.client is not None

    def get_embedding(self, text: str) -> Optional[List[float]]:
        if not self.client:
            return None

        try:
            response = self.client.embeddings.create(
                model=self.model, input=text, dimensions=self.dimensions
            )
            return response.data[0].embedding
        except Exception as e:
            print(f"[!] Embedding error: {e}")
            return None

    def get_embeddings(self, texts: List[str]) -> List[Optional[List[float]]]:
        if not self.client:
            return [None] * len(texts)

        try:
            response = self.client.embeddings.create(
                model=self.model, input=texts, dimensions=self.dimensions
            )
            return [item.embedding for item in response.data]
        except Exception as e:
            print(f"[!] Embedding batch error: {e}")
            return [None] * len(texts)

    def get_text_embedding(self, text: str) -> str:
        embedding = self.get_embedding(text)
        if embedding is None:
            return "[]"
        return json.dumps(embedding)

    def compute_card_embedding(
        self, title: str, description: str = ""
    ) -> Optional[List[float]]:
        combined = f"{title}. {description}" if description else title
        return self.get_embedding(combined)

    def compute_session_embedding(self, messages: List[dict]) -> Optional[List[float]]:
        if not messages:
            return None

        combined_text = " ".join(
            [
                msg.get("content", "")
                for msg in messages
                if msg.get("content") and msg.get("role") != "system"
            ]
        )
        return self.get_embedding(combined_text)


embedding_service = EmbeddingService()
