import os
from pathlib import Path
from typing import List, Dict, Any, Optional
import tree_sitter
from tree_sitter_language_pack import get_language, get_parser
from src.persistence.database import KanbanDB
from src.logger import setup_logger

logger = setup_logger("CodeIndexer")

class TreeSitterParser:
    """Robust multi-language symbol extractor using Node Walking instead of fragile Queries."""
    
    def __init__(self, lang_name: str):
        self.lang_name = lang_name
        try:
            self.language = get_language(lang_name)
            self.parser = get_parser(lang_name)
        except Exception as e:
            logger.error(f"Failed to initialize Tree-sitter for {lang_name}: {e}")
            self.parser = None

    def parse(self, code: str, file_path: str) -> List[Dict]:
        if not self.parser: return []
        
        try:
            tree = self.parser.parse(bytes(code, "utf8"))
            symbols = []
            code_lines = code.splitlines()
            self._walk_node(tree.root_node, symbols, code_lines)
            return symbols
        except Exception as e:
            logger.error(f"Tree-sitter parse error in {file_path}: {e}")
            return []

    def _walk_node(self, node: tree_sitter.Node, symbols: List[Dict], lines: List[str]):
        """Recursively walk the tree to find symbol-like nodes."""
        node_type = node.type.lower()
        
        # Determine if this node is a symbol we care about
        is_symbol = False
        sym_type = ""
        
        if "class" in node_type and "definition" in node_type:
            is_symbol = True
            sym_type = "class"
        elif "function" in node_type or "method" in node_type:
            # Avoid matching too many small nodes, ensure it looks like a declaration
            if "definition" in node_type or "declaration" in node_type or "signature" in node_type:
                is_symbol = True
                sym_type = "function"

        if is_symbol:
            # Robust name extraction
            name = "unknown"
            name_node = node.child_by_field_name("name")
            if not name_node:
                # Search children for first identifier
                for child in node.children:
                    if "identifier" in child.type:
                        name_node = child
                        break
            
            if name_node:
                try:
                    name = name_node.text.decode("utf8")
                except: pass

            if len(name) > 1:
                symbols.append({
                    "symbol_name": name,
                    "symbol_type": sym_type,
                    "signature": lines[node.start_point[0]].strip() if node.start_point[0] < len(lines) else "",
                    "start_line": node.start_point[0] + 1,
                    "end_line": node.end_point[0] + 1,
                    "documentation": "",
                    "code_content": node.text.decode("utf8") if hasattr(node, 'text') else ""
                })

        # Recurse into children
        for child in node.children:
            self._walk_node(child, symbols, lines)

class CodeIndexer:
    """Unified Indexer using Tree-sitter Walking."""
    def __init__(self, db: KanbanDB):
        self.db = db
        self.parsers = {
            ".py": TreeSitterParser("python"),
            ".dart": TreeSitterParser("dart")
        }

    async def index_project(self, project_id: str, workspace_path: str):
        if not workspace_path or not os.path.exists(workspace_path): return
        
        files_to_process = []
        for root, _, files in os.walk(workspace_path):
            if any(p.startswith('.') or p in ('venv', 'build', 'ios', 'android', 'node_modules', '.dart_tool') for p in Path(root).parts):
                continue
            for f in files:
                ext = os.path.splitext(f)[1]
                if ext in self.parsers:
                    abs_p = os.path.join(root, f)
                    rel_p = os.path.relpath(abs_p, workspace_path)
                    files_to_process.append((abs_p, rel_p))
        
        logger.info(f"[*] Tree-sitter walking {len(files_to_process)} files for project {project_id}")
        # Process in batches for performance
        batch_size = 20
        for i in range(0, len(files_to_process), batch_size):
            batch = files_to_process[i:i+batch_size]
            await asyncio.gather(*(self.index_file(project_id, ap, rp) for ap, rp in batch))

    async def index_file(self, project_id: str, abs_path: str, rel_path: str):
        ext = os.path.splitext(abs_path)[1]
        parser = self.parsers.get(ext)
        if not parser: return

        try:
            with open(abs_path, "r", encoding="utf-8") as f:
                code = f.read()
            
            symbols = parser.parse(code, rel_path)
            self.db.code_symbols.delete_by_file(project_id, rel_path)
            for sym in symbols:
                self.db.code_symbols.upsert(project_id=project_id, file_path=rel_path, **sym)
        except Exception as e:
            logger.error(f"Failed to index {rel_path}: {e}")
