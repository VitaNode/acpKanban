import os
import json
import asyncio
from typing import List, Optional, Dict, Any, Callable
from openai import OpenAI
from dotenv import load_dotenv
from src.logger import setup_logger

load_dotenv()
logger = setup_logger("EmbeddingService")

class EmbeddingService:
    _instance = None

    def __new__(cls, *args, **kwargs):
        if cls._instance is None:
            cls._instance = super(EmbeddingService, cls).__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self, model: str = None, dimensions: int = 1536):
        target_model = model or os.getenv("EMBEDDING_MODEL", "text-embedding-3-small")
        
        if self._initialized:
            if target_model != self.default_model or dimensions != self.dimensions:
                logger.info(f"Reconfiguring: {self.default_model} -> {target_model}")
                self.default_model = target_model
                self.dimensions = dimensions
                self.client = None
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
            except Exception as e:
                logger.error(f"Database settings fallback failed: {e}")

        base_url = base_url or "https://api.openai.com/v1"

        if not api_key or api_key == "your_new_key_here":
            return None

        if self.client is None or api_key != self._last_api_key or base_url != self._last_base_url:
            masked_key = api_key[:8] + "..." if api_key else "None"
            logger.info(f"Initializing OpenAI client with base_url: {base_url}, api_key: {masked_key}")
            self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=30.0)
            self._last_api_key = api_key
            self._last_base_url = base_url
        
        return self.client

    def is_available(self) -> bool:
        return self._get_client() is not None

    def get_embedding(self, text: str) -> Optional[List[float]]:
        client = self._get_client()
        if not client: return None
        model = os.getenv("EMBEDDING_MODEL", self.default_model)
        try:
            response = client.embeddings.create(model=model, input=text, dimensions=self.dimensions)
            return response.data[0].embedding
        except Exception as e:
            logger.error(f"Embedding error with model {model}: {e}")
            return None

    async def batch_generate_embeddings(self, texts: List[str], batch_size: int = 20) -> List[Optional[List[float]]]:
        """Batch embedding with error isolation. Returns list of embeddings (can contain None)."""
        results = []
        client = self._get_client()
        if not client: return [None] * len(texts)
        model = os.getenv("EMBEDDING_MODEL", self.default_model)
        
        for i in range(0, len(texts), batch_size):
            batch = texts[i:i+batch_size]
            try:
                def call_batch():
                    response = client.embeddings.create(model=model, input=batch, dimensions=self.dimensions)
                    return [item.embedding for item in response.data]
                
                embeddings = await asyncio.to_thread(call_batch)
                results.extend(embeddings)
            except Exception as e:
                logger.error(f"Batch embedding {i//batch_size} failed: {e}")
                results.extend([None] * len(batch))
        return results

    async def index_codebase(self, project_id: str, workspace_path: str, force_full: bool = False, on_progress: Optional[Callable] = None):
        """Indexes the entire codebase and generates embeddings for symbols (Incremental)."""
        from src.persistence.database import KanbanDB
        from src.persistence.indexer import CodeIndexer
        
        db = KanbanDB()
        indexer = CodeIndexer(db)
        
        # 1. Structural indexing (Incremental)
        await indexer.index_project(project_id, workspace_path, force_full=force_full, on_progress=on_progress)
        
        # 2. Vectorization
        symbols = db.code_symbols.get_by_project(project_id)
        to_embed = []
        for sym in symbols:
            if not sym.get("embedding") or sym["embedding"] in ("null", "[]"):
                text = f"{sym['symbol_type']} {sym['symbol_name']}\nSignature: {sym['signature']}"
                if sym.get("documentation"): text += f"\nDoc: {sym['documentation']}"
                to_embed.append((sym, text))
        
        if to_embed:
            logger.info(f"Vectorizing {len(to_embed)} symbols for project {project_id}")
            texts = [item[1] for item in to_embed]
            embeddings = await self.batch_generate_embeddings(texts)
            
            failed_count = 0
            for (sym, _), emb in zip(to_embed, embeddings):
                if emb:
                    db.code_symbols.upsert(
                        project_id=project_id, file_path=sym['file_path'],
                        symbol_name=sym['symbol_name'], symbol_type=sym['symbol_type'],
                        signature=sym['signature'], start_line=sym['start_line'],
                        end_line=sym['end_line'], documentation=sym['documentation'],
                        code_content=sym['code_content'], embedding=emb
                    )
                else:
                    failed_count += 1
            
            if failed_count > 0:
                logger.warning(f"{failed_count} symbols failed to vectorize, will retry next time")

        # Update stats
        final_files = db.get_project_file_count(project_id)
        final_symbols = db.get_project_symbol_count(project_id)
        final_vec = db.get_project_vectorized_symbol_count(project_id)
        db.update_project_stats(
            project_id, total_files=final_files, total_symbols=final_symbols,
            total_vectorized_symbols=final_vec
        )
        logger.info(f"Completed indexing for project {project_id}")

embedding_service = EmbeddingService()
