import os
import ast
from pathlib import Path
from typing import List, Dict, Any, Optional
from src.persistence.database import KanbanDB
from src.logger import setup_logger

logger = setup_logger("CodeIndexer")

class PythonParser:
    """Extracts symbols from Python code using AST."""
    def parse(self, code: str, file_path: str) -> List[Dict]:
        try:
            tree = ast.parse(code)
            symbols = []
            
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef):
                    symbols.append(self._make_symbol(node, "class", code))
                elif isinstance(node, ast.FunctionDef):
                    # Check if it's a method (inside a class)
                    symbol_type = "method" if any(isinstance(p, ast.ClassDef) for p in self._get_parents(tree, node)) else "function"
                    symbols.append(self._make_symbol(node, symbol_type, code))
            return symbols
        except Exception as e:
            logger.error(f"Failed to parse Python file {file_path}: {e}")
            return []

    def _get_parents(self, tree, target):
        """Helper to find parents of a node."""
        parents = []
        for node in ast.walk(tree):
            for child in ast.iter_child_nodes(node):
                if child is target:
                    parents.append(node)
                    parents.extend(self._get_parents(tree, node))
        return parents

    def _make_symbol(self, node: Any, symbol_type: str, code: str) -> Dict:
        lines = code.splitlines()
        start_line = node.lineno
        end_line = getattr(node, "end_lineno", start_line)
        
        # Simple signature extraction
        signature = lines[start_line-1].strip()
        
        # Extraction documentation
        docstring = ast.get_docstring(node)
        
        # Extract source code for this symbol
        code_content = "\n".join(lines[start_line-1:end_line])

        return {
            "symbol_name": node.name,
            "symbol_type": symbol_type,
            "signature": signature,
            "start_line": start_line,
            "end_line": end_line,
            "documentation": docstring,
            "code_content": code_content
        }

class CodeIndexer:
    """Manages project-wide code indexing."""
    def __init__(self, db: KanbanDB):
        self.db = db
        self.parsers = {
            ".py": PythonParser()
        }

    async def index_project(self, project_id: str, workspace_path: str):
        """Walks the workspace and indexes supported files."""
        if not workspace_path or not os.path.exists(workspace_path):
            logger.warning(f"Workspace path {workspace_path} does not exist.")
            return

        for root, _, files in os.walk(workspace_path):
            # Skip hidden folders and venv
            if any(part.startswith('.') or part == 'venv' or part == '__pycache__' for part in Path(root).parts):
                continue

            for file in files:
                ext = os.path.splitext(file)[1]
                if ext in self.parsers:
                    file_path = os.path.join(root, file)
                    rel_path = os.path.relpath(file_path, workspace_path)
                    await self.index_file(project_id, file_path, rel_path)

    async def index_file(self, project_id: str, abs_path: str, rel_path: str):
        """Indexes a single file."""
        ext = os.path.splitext(abs_path)[1]
        parser = self.parsers.get(ext)
        if not parser:
            return

        try:
            with open(abs_path, "r", encoding="utf-8") as f:
                code = f.read()
            
            symbols = parser.parse(code, rel_path)
            
            # Clear old symbols for this file
            self.db.code_symbols.delete_by_file(project_id, rel_path)
            
            for sym in symbols:
                self.db.code_symbols.upsert(
                    project_id=project_id,
                    file_path=rel_path,
                    **sym
                )
            logger.info(f"Indexed {len(symbols)} symbols in {rel_path}")
        except Exception as e:
            logger.error(f"Failed to index file {rel_path}: {e}")
