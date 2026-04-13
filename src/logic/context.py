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
    Level 2 (Related): Other card summaries (semantic search).
    Level 3 (Focus): Current card details and column-specific template.
    """
    def __init__(self, db: KanbanDB):
        self.db = db

    async def build_initial_context(self, card_id: str, column_prompt: Optional[str] = None) -> str:
        """
        Builds the comprehensive initial context string.
        Includes Level 1-3 content and optional column-specific prompt.
        """
        card = self.db.cards.get_by_id(card_id)
        if not card:
            return "Context: Card not found."

        project_id = card.get("project_id")
        project = self.db.projects.get_by_id(project_id) if project_id else None
        
        sections = []
        
        # --- Level 1: Global Context ---
        if project:
            sections.append(f"# Global Project Context: {project['name']}")
            if project.get("workspace_path"):
                sections.append(f"Root Workspace: {project['workspace_path']}")

        agent_md = self._load_agent_md(project.get("workspace_path") if project else None)
        if agent_md:
            sections.append(f"## System Guidelines (agent.md)\n{agent_md}")

        # --- Level 2: Related Context (Summaries) ---
        if project_id:
            # MED-1 Strategy: Limit to latest 5 to avoid context bloat
            summaries = self.db.summaries.get_all_for_project(project_id)
            if summaries:
                # Sort by update time desc and take 5
                sorted_summaries = sorted(summaries, key=lambda x: x.get('updated_at', ''), reverse=True)[:5]
                summaries_text = "\n".join([
                    f"### Card: {s['title']}\nSummary: {s['summary']}"
                    for s in sorted_summaries if s['card_id'] != card_id
                ])
                if summaries_text:
                    sections.append(f"## Knowledge Base (Related Cards)\n{summaries_text}")

        # --- Level 3: Focus Context (Current Card & Stage) ---
        sections.append(f"## Active Card: {card['title']}")
        if card.get("description"):
            sections.append(f"Card Description:\n{card['description']}")
        
        if card.get("last_summary"):
            sections.append(f"Status of previous stage:\n{card['last_summary']}")

        # --- Column Specific Prompt ---
        if column_prompt:
            sections.append(f"## Current Workflow Stage Instructions\n{column_prompt}")
        else:
            sections.append("## Instructions\nYou are currently working on this card. Focus on completing the described task.")

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
