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
        from src.config.manager import config
        
        api_key = config.system_agent_api_key
        base_url = config.system_agent_base_url

        # Fallback to DB if config is empty (mostly for legacy support or if ConfigManager failed)
        if not api_key:
            try:
                from src.persistence.database import KanbanDB
                db = KanbanDB()
                raw_config = db.get_setting("system_config")
                # ... rest of fallback logic can be simplified or kept if needed
                # For now, let's prioritize ConfigManager which is more robust
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
            except Exception as e:
                logger.error(f"Database settings fallback failed: {e}")

        base_url = base_url or "https://api.openai.com/v1"

        if not api_key:
            return None

        if self.client is None or api_key != self._last_api_key or base_url != self._last_base_url:
            masked_key = api_key[:8] + "..." if api_key else "None"
            logger.info(f"Initializing OpenAI client for System Agent with base_url: {base_url}, api_key: {masked_key}")
            self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=30.0)
            self._last_api_key = api_key
            self._last_base_url = base_url
        
        return self.client

    def is_available(self) -> bool:
        return self._get_client() is not None

    def get_embedding(self, text: str) -> Optional[List[float]]:
        client = self._get_client()
        if not client: return None
        
        from src.config.manager import config
        model = config.embedding_model or self.default_model
        try:
            response = client.embeddings.create(model=model, input=text, dimensions=self.dimensions)
            return response.data[0].embedding
        except Exception as e:
            logger.error(f"Embedding error with model {model}: {e}")
            return None

    def completion(self, messages: List[Dict[str, str]], model: str = None, temperature: float = 0.7) -> Optional[str]:
        client = self._get_client()
        if not client: return None
        
        from src.config.manager import config
        target_model = model or config.summary_model or "gpt-4o-mini"
        
        try:
            response = client.chat.completions.create(
                model=target_model,
                messages=messages,
                temperature=temperature
            )
            return response.choices[0].message.content
        except Exception as e:
            logger.error(f"LLM Completion error with model {target_model}: {e}")
            return None

    def generate_summary(self, title: str, messages: List[Dict[str, Any]], model: str = None) -> Optional[str]:
        """Summarizes a session history into a structured technical handoff."""
        # ... logic kept same, model passed to completion()
        history_text = ""
        for msg in messages[-30:]:
            role = msg.get("role", "unknown")
            content = msg.get("content", "")
            history_text += f"{role}: {content[:500]}\n"

        prompt = f"""Summarize the technical progress for the task: '{title}'.

History:
{history_text}

Provide a structured technical handoff in Markdown using exactly these sections:

### 📝 Phase Summary
{{One-sentence core progress}}

### 🛠 Technical Decisions
- **Decision**: {{What}} -> **Why**: {{Reasoning}}

### ⚠️ Lessons & Blacklist
- {{Failed attempts, bugs found, or paths to avoid to save time for the next Agent}}

### 🚧 Status & Issues
- **Completed**: {{Brief list of achieved items}}
- **Pending**: {{Blockers or remaining todos}}

### ⏭ Next Actions
- {{Concrete next steps for the next Agent}}

Keep it concise but technically rich. Avoid generic fluff.
"""
        
        return self.completion([
            {"role": "system", "content": "You are a senior technical lead providing a handoff for another AI agent."},
            {"role": "user", "content": prompt}
        ], model=model)

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
