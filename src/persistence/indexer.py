import os
import ast
from pathlib import Path
from typing import List, Dict, Any, Optional, Set
from src.persistence.database import KanbanDB
from src.logger import setup_logger

logger = setup_logger("CodeIndexer")

class PythonParser:
    """Enhanced symbols extractor for Python code."""
    
    def parse(self, code: str, file_path: str) -> List[Dict]:
        try:
            tree = ast.parse(code)
            symbols = []
            self._process_node(tree, "", symbols, code)
            return symbols
        except Exception as e:
            logger.error(f"Failed to parse Python file {file_path}: {e}")
            return []

    def _process_node(self, node: Any, parent_prefix: str, symbols: List[Dict], code: str):
        """Recursive node processor to handle nesting and prefixes."""
        lines = code.splitlines()
        
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                symbol = self._make_symbol(child, parent_prefix, lines, code)
                symbols.append(symbol)
                
                # Recursive call for nested structures
                new_prefix = f"{parent_prefix}{child.name}."
                self._process_node(child, new_prefix, symbols, code)

    def _make_symbol(self, node: Any, prefix: str, lines: List[str], code: str) -> Dict:
        start_line = node.lineno
        end_line = getattr(node, "end_lineno", start_line)
        
        symbol_type = "class"
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            symbol_type = "method" if prefix else "function"

        # 1. Extract Full Signature (including Decorators and Type Hints)
        # Decorators
        decorators = []
        for dec in getattr(node, "decorator_list", []):
            try:
                decorators.append(f"@{ast.unparse(dec)}")
            except: pass
        
        # Base signature
        raw_sig = lines[start_line-1].strip()
        full_signature = "\n".join(decorators) + ("\n" if decorators else "") + raw_sig

        # 2. Extract Documentation
        docstring = ast.get_docstring(node)
        
        # 3. Code Content
        # We include decorators in the code content
        actual_start = start_line
        if node.decorator_list:
            actual_start = min(d.lineno for d in node.decorator_list)
        
        code_content = "\n".join(lines[actual_start-1:end_line])

        return {
            "symbol_name": f"{prefix}{node.name}",
            "symbol_type": symbol_type,
            "signature": full_signature,
            "start_line": actual_start,
            "end_line": end_line,
            "documentation": docstring,
            "code_content": code_content
        }

class CodeIndexer:
    """Manages project-wide code indexing with concurrency and batching."""
    def __init__(self, db: KanbanDB):
        self.db = db
        self.parsers = {
            ".py": PythonParser()
        }
        self.max_concurrency = 10

    async def index_project(self, project_id: str, workspace_path: str):
        """Walks the workspace and indexes supported files in parallel batches."""
        if not workspace_path or not os.path.exists(workspace_path):
            return

        files_to_index = []
        for root, _, files in os.walk(workspace_path):
            if any(part.startswith('.') or part in ('venv', '__pycache__', 'node_modules') for part in Path(root).parts):
                continue

            for file in files:
                ext = os.path.splitext(file)[1]
                if ext in self.parsers:
                    abs_path = os.path.join(root, file)
                    rel_path = os.path.relpath(abs_path, workspace_path)
                    files_to_index.append((abs_path, rel_path))

        # Async batch processing
        logger.info(f"Starting index for {len(files_to_index)} files in project {project_id}")
        
        for i in range(0, len(files_to_index), self.max_concurrency):
            batch = files_to_index[i:i+self.max_concurrency]
            tasks = [self.index_file(project_id, abs_p, rel_p) for abs_p, rel_p in batch]
            await asyncio.gather(*tasks)
        
        logger.info(f"Completed indexing for project {project_id}")

    async def index_file(self, project_id: str, abs_path: str, rel_path: str):
        ext = os.path.splitext(abs_path)[1]
        parser = self.parsers.get(ext)
        if not parser: return

        try:
            with open(abs_path, "r", encoding="utf-8") as f:
                code = f.read()
            
            symbols = parser.parse(code, rel_path)
            
            # Use a transaction for upserting batch symbols from one file
            # This is handled by CodeSymbolRepository.delete_by_file + upsert
            self.db.code_symbols.delete_by_file(project_id, rel_path)
            for sym in symbols:
                self.db.code_symbols.upsert(project_id=project_id, file_path=rel_path, **sym)
        except Exception as e:
            logger.error(f"Error indexing {rel_path}: {str(e)}")
