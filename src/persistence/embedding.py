import os
import json
import asyncio
from typing import List, Optional, Dict, Any
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

    def __init__(self, model: str = None, dimensions: int = 1536):
        target_model = model or os.getenv("EMBEDDING_MODEL", "text-embedding-3-small")
        
        # If already initialized with different params, force re-initialization of client
        if self._initialized:
            if target_model != self.default_model or dimensions != self.dimensions:
                print(f"[EmbeddingService] Reconfiguring: {self.default_model} -> {target_model}")
                self.default_model = target_model
                self.dimensions = dimensions
                self.client = None # Will be recreated on next _get_client()
            return

        self.default_model = target_model
        self.dimensions = dimensions
        self.client = None
        self._last_api_key = None
        self._last_base_url = None
        self._initialized = True

    def _get_client(self):
        api_key = os.getenv("KANBAN_API_KEY")
        base_url = os.getenv("KANBAN_BASE_URL")

        if not api_key or not base_url:
            try:
                from src.persistence.database import KanbanDB
                db = KanbanDB()
                raw_config = db.get_setting("system_config")
                if raw_config:
                    system_config = raw_config
                    if isinstance(raw_config, str):
                        try:
                            system_config = json.loads(raw_config)
                        except json.JSONDecodeError:
                            system_config = {}

                    if isinstance(system_config, dict):
                        api_key = api_key or system_config.get("api_key") or system_config.get("apiKey")
                        base_url = base_url or system_config.get("base_url") or system_config.get("baseUrl")
                        
                        if not os.getenv("SUMMARY_MODEL"):
                            summary_model = system_config.get("summary_model") or system_config.get("summaryModel") or "gpt-4o-mini"
                            os.environ["SUMMARY_MODEL"] = summary_model
                        if not os.getenv("EMBEDDING_MODEL"):
                            embedding_model = system_config.get("embedding_model") or system_config.get("embeddingModel") or "text-embedding-3-small"
                            os.environ["EMBEDDING_MODEL"] = embedding_model
                else:
                    pass
            except Exception as e:
                print(f"[EmbeddingService] Database settings fallback failed: {e}")

        base_url = base_url or "https://api.openai.com/v1"

        if not api_key or api_key == "your_new_key_here":
            return None

        if self.client is None or api_key != self._last_api_key or base_url != self._last_base_url:
            masked_key = api_key[:8] + "..." if api_key else "None"
            print(f"[EmbeddingService] Initializing OpenAI client with base_url: {base_url}, api_key: {masked_key}")
            self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=30.0)
            self._last_api_key = api_key
            self._last_base_url = base_url
        
        return self.client

    def is_available(self) -> bool:
        return self._get_client() is not None

    def get_embedding(self, text: str) -> Optional[List[float]]:
        client = self._get_client()
        if not client:
            return None

        model = os.getenv("EMBEDDING_MODEL", self.default_model)
        try:
            response = client.embeddings.create(
                model=model, input=text, dimensions=self.dimensions
            )
            return response.data[0].embedding
        except Exception as e:
            print(f"[!] Embedding error with model {model}: {e}")
            return None

    def get_embeddings(self, texts: List[str]) -> List[Optional[List[float]]]:
        client = self._get_client()
        if not client:
            return [None] * len(texts)

        model = os.getenv("EMBEDDING_MODEL", self.default_model)
        try:
            response = client.embeddings.create(
                model=model, input=texts, dimensions=self.dimensions
            )
            return [item.embedding for item in response.data]
        except Exception as e:
            print(f"[!] Embedding batch error with model {model}: {e}")
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

    def generate_summary(self, title: str, messages: List[dict], model: str = None) -> Optional[str]:
        client = self._get_client()
        if not client:
            print("[EmbeddingService] Client not available for summary generation")
            return None

        model = model or os.getenv("SUMMARY_MODEL", "gpt-4o-mini")
        
        logs = "\n".join(
            [
                f"[{msg.get('role', 'unknown')}] {msg.get('content', '')}"
                for msg in messages
                if msg.get("content")
            ]
        )
        
        if len(logs) > 3000:
            logs = logs[:1500] + "\n... [truncated] ...\n" + logs[-1500:]

        prompt = f"""
You are an expert at summarizing technical discussions and task execution. 
Summarize the following card development process for card titled "{title}". 

Include:
1. What was the core problem solved?
2. What key technical changes were made?
3. Any important context or technical debt left for the future?

Discussion and execution logs:
{logs}

Provide a concise summary (max 300 words).
"""

        try:
            response = client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": "You are a helpful assistant that summarizes technical tasks."},
                    {"role": "user", "content": prompt}
                ],
                max_tokens=500
            )
            content = response.choices[0].message.content
            if not content or not content.strip():
                print(f"[!] LLM returned empty summary for model {model}")
                return None
            return content
        except Exception as e:
            print(f"[!] Summary generation error with model {model}: {e}")
            return None

    async def index_codebase(self, project_id: str, workspace_path: str):
        """Indexes the entire codebase and generates embeddings for symbols."""
        from src.persistence.database import KanbanDB
        from src.persistence.indexer import CodeIndexer
        
        db = KanbanDB()
        indexer = CodeIndexer(db)
        
        # 1. Structural indexing
        await indexer.index_project(project_id, workspace_path)
        
        # 2. Vectorization (Phase 1)
        symbols = db.code_symbols.get_by_project(project_id)
        for sym in symbols:
            # Check if embedding already exists (stored as JSON string in DB)
            if not sym.get("embedding") or sym["embedding"] == "null":
                text_to_embed = f"{sym['symbol_type']} {sym['symbol_name']}\nSignature: {sym['signature']}"
                if sym.get("documentation"):
                    text_to_embed += f"\nDocumentation: {sym['documentation']}"
                
                embedding = self.get_embedding(text_to_embed)
                if embedding:
                    db.code_symbols.upsert(
                        project_id=project_id,
                        file_path=sym['file_path'],
                        symbol_name=sym['symbol_name'],
                        symbol_type=sym['symbol_type'],
                        signature=sym['signature'],
                        start_line=sym['start_line'],
                        end_line=sym['end_line'],
                        documentation=sym['documentation'],
                        code_content=sym['code_content'],
                        embedding=embedding
                    )
        print(f"[EmbeddingService] Completed indexing and vectorization for project {project_id}")


embedding_service = EmbeddingService()
