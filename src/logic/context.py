import os
from pathlib import Path
from typing import List, Dict, Optional
from src.persistence.database import KanbanDB
from src.logger import setup_logger

logger = setup_logger("ContextBuilder")

class ContextBuilder:
    """
    Assembles the system prompt and context for ACP sessions.
    Follows the 3-level strategy:
    Level 1 (Global): Project Info, agent.md, Summaries.
    Level 2 (Related): Other card summaries.
    Level 3 (Focus): Current card session details.
    """
    def __init__(self, db: KanbanDB):
        self.db = db

    async def build_initial_context(self, card_id: str) -> str:
        """
        Builds the comprehensive initial context string.
        (Called asynchronously via Dispatcher.create_task)
        """
        # Fixed: Repository methods are synchronous (with threads)
        card = self.db.cards.get_by_id(card_id)
        if not card:
            return "Context: Card not found."

        project_id = card.get("project_id")
        project = self.db.projects.get_by_id(project_id) if project_id else None
        
        sections = []
        
        # 1. Project Info
        if project:
            sections.append(f"# Project: {project['name']}")
            if project.get("workspace_path"):
                sections.append(f"Workspace Path: {project['workspace_path']}")

        # 2. agent.md (Global Instructions)
        agent_md = self._load_agent_md(project.get("workspace_path") if project else None)
        if agent_md:
            sections.append(f"## Agent Instructions (agent.md)\n{agent_md}")

        # 3. Global Summaries (Other cards in the same project)
        if project_id:
            summaries = self.db.summaries.get_all_for_project(project_id)
            if summaries:
                summaries_text = "\n".join([
                    f"- Card: {s['title']}\n  Summary: {s['summary']}"
                    for s in summaries if s['card_id'] != card_id
                ])
                if summaries_text:
                    sections.append(f"## Related Card Summaries\n{summaries_text}")

        # 4. Current Card Info
        sections.append(f"## Current Card: {card['title']}")
        if card.get("description"):
            sections.append(f"Description: {card['description']}")

        return "\n\n".join(sections)

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
