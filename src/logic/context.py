import os
import json
from pathlib import Path
from typing import List, Dict, Optional
from src.persistence.database import KanbanDB
from src.persistence.embedding import embedding_service
from src.logger import setup_logger

logger = setup_logger("ContextBuilder")

class ContextBuilder:
    """
    Assembles the system prompt and context for ACP sessions.
    Optimized for token efficiency:
    Level 1 (Global): Basic Project Info + Tooling Guidance.
    Level 2 (Related): Semantically related historical card summaries.
    Level 3 (Focus): Current card details + Recommended Files (from index).
    """
    def __init__(self, db: KanbanDB):
        self.db = db

    async def build_initial_context(self, card_id: str, column_prompt: Optional[str] = None) -> str:
        """
        Builds the comprehensive initial context string.
        Focuses on guiding the agent to use mcp-tools instead of bulk reading.
        """
        card = self.db.cards.get_by_id(card_id)
        if not card:
            return "Context: Card not found."

        project_id = card.get("project_id")
        project = self.db.projects.get_by_id(project_id) if project_id else None
        
        sections = []
        
        # --- Level 1: Global Context (Slimmed) ---
        if project:
            sections.append(f"# Global Project Context: {project['name']}")
            sections.append(f"Project ID: {project_id}")
            if project.get("workspace_path"):
                sections.append(f"Root Workspace: {project['workspace_path']}")
            
            # Guidelines on how to explore efficiently
            sections.append("""## Efficiency Guidelines
1. **Don't read full files immediately.** Use `code-tools` to get the project outline first.
2. **Use `get_symbol_code`** to read specific classes/functions instead of whole files.
3. **Semantic Search**: Use `search_code` if you are unsure where a feature is implemented.""")

        agent_md = self._load_agent_md(project.get("workspace_path") if project else None)
        if agent_md:
            # We only take the first 1000 chars of agent.md to save tokens, or assume it's small
            sections.append(f"## System Guidelines (agent.md)\n{agent_md[:2000]}")

        # --- Level 2: Related Context (Semantic Search) ---
        related_summaries = await self._get_related_summaries(card, project_id)
        if related_summaries:
            sections.append("## Related Historical Context")
            sections.append(related_summaries)

        # --- Level 3: Focus Context (Current Card & Stage) ---
        sections.append(f"## Active Card: {card['title']}")
        if card.get("description"):
            sections.append(f"Card Description:\n{card['description']}")
        
        if card.get("last_summary"):
            sections.append(f"Status of previous stage:\n{card['last_summary']}")

        # --- Recommended Files (Dynamic based on Card Intent) ---
        recommended = await self._get_recommended_files(card, project_id)
        if recommended:
            sections.append(f"## Recommended Files to Explore\n{recommended}")

        # --- Column Specific Prompt ---
        if column_prompt:
            sections.append(f"## Current Workflow Stage Instructions\n{column_prompt}")

        return "\n\n".join(sections)

    async def _get_related_summaries(self, card: Dict, project_id: str, limit: int = 2) -> Optional[str]:
        """Finds related cards using true semantic similarity."""
        if not embedding_service.is_available():
            return None
            
        card_text = f"{card['title']} {card.get('description', '')}"
        query_vector = embedding_service.get_embedding(card_text)
        if not query_vector:
            return None
            
        # Call the new semantic search method
        related = self.db.summaries.search_semantic(query_vector, project_id, limit=limit + 1)
        # Filter out current card
        related = [s for s in related if s['card_id'] != card['id']][:limit]
        
        if not related:
            return None
            
        matches = []
        for s in related:
            matches.append(f"### Historical Task: {s.get('title', 'Unknown')}\n{s['summary']}")
        
        return "\n".join(matches) if matches else None

    async def _get_recommended_files(self, card: Dict, project_id: str) -> Optional[str]:
        """Suggests files using semantic search against indexed code symbols."""
        if not embedding_service.is_available():
            # Fallback to keyword search (already implemented in previous step)
            return self._get_recommended_files_keyword(card, project_id)
            
        card_text = f"{card['title']} {card.get('description', '')}"
        query_vector = embedding_service.get_embedding(card_text)
        if not query_vector:
            return self._get_recommended_files_keyword(card, project_id)

        # Call real semantic search for code symbols
        symbols = self.db.code_symbols.search_semantic(query_vector, project_id, limit=5)
        
        matched_files = set()
        for s in symbols:
            matched_files.add(s['file_path'])
        
        if matched_files:
            return "- " + "\n- ".join(list(matched_files))
        return None

    def _get_recommended_files_keyword(self, card: Dict, project_id: str) -> Optional[str]:
        """Fallback keyword-based recommendation."""
        symbols = self.db.code_symbols.get_by_project(project_id)
        if not symbols: return None
        keywords = [word.lower() for word in card['title'].split() if len(word) > 3]
        matched_files = set()
        for s in symbols:
            if any(k in s['symbol_name'].lower() for k in keywords):
                matched_files.add(s['file_path'])
            if len(matched_files) >= 3: break
        return "- " + "\n- ".join(list(matched_files)) if matched_files else None

    def _load_agent_md(self, workspace_path: Optional[str]) -> Optional[str]:
        """Loads agent.md from the workspace or project root."""
        search_paths = []
        if workspace_path:
            search_paths.append(Path(workspace_path) / "agent.md")
        search_paths.append(Path(__file__).parent / "agent.md")

        for path in search_paths:
            if path.exists():
                try:
                    with open(path, "r") as f:
                        return f.read()
                except Exception as e:
                    logger.warning(f"Failed to read agent.md at {path}: {e}")
        return None
