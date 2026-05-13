import os
import asyncio
from pathlib import Path
from typing import List, Dict, Any, Optional, Callable
import tree_sitter
from tree_sitter_language_pack import get_language, get_parser
from src.persistence.database import KanbanDB
from src.utils.file_hasher import compute_file_hash
from src.logger import setup_logger

logger = setup_logger("CodeIndexer")

# --- Configuration ---
EXCLUDED_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.ico', '.woff', '.ttf', '.jar', '.dll', '.so', '.aar', '.exe', '.bin', '.pdf', '.zip', '.gz'}
EXCLUDED_DIRS = {'.git', 'node_modules', '__pycache__', 'build', 'dist', '.dart_tool', 'venv', '.venv', 'ios', 'android'}

class TreeSitterParser:
    """Robust multi-language symbol extractor using explicit type matching."""
    
    # Language-specific symbol types
    SYMBOL_TYPES = {
        "python": {
            "class": {"class_definition"},
            "function": {"function_definition", "async_function_definition"}
        },
        "dart": {
            "class": {"class_definition", "enum_declaration", "mixin_declaration", "extension_declaration"},
            "function": {"function_signature", "method_declaration", "getter_declaration", "setter_declaration"}
        }
    }

    def __init__(self, lang_name: str):
        self.lang_name = lang_name
        try:
            self.language = get_language(lang_name)
            self.parser = get_parser(lang_name)
            self.rules = self.SYMBOL_TYPES.get(lang_name, {})
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
        node_type = node.type
        sym_type = ""
        
        if node_type in self.rules.get("class", set()):
            sym_type = "class"
        elif node_type in self.rules.get("function", set()):
            sym_type = "function"

        if sym_type:
            # Robust name extraction
            name = "unknown"
            name_node = node.child_by_field_name("name")
            if not name_node:
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

        for child in node.children:
            self._walk_node(child, symbols, lines)

class CodeIndexer:
    """Unified Indexer using Tree-sitter Walking and Incremental Logic."""
    def __init__(self, db: KanbanDB):
        self.db = db
        self.parsers = {
            ".py": TreeSitterParser("python"),
            ".dart": TreeSitterParser("dart")
        }

    async def index_project(self, project_id: str, workspace_path: str, force_full: bool = False, on_progress: Optional[Callable] = None):
        """
        Main entry point for incremental indexing.
        """
        if not workspace_path or not os.path.exists(workspace_path):
            # For remote projects, the workspace path might not exist locally.
            # We skip local indexing gracefully.
            logger.debug(f"Workspace path not found locally: {workspace_path}. Skipping local indexing.")
            return

        if not os.access(workspace_path, os.R_OK):
            logger.error(f"Permission denied: {workspace_path}")
            return
        
        # 1. Gather all files to process
        all_files = []
        for root, dirs, files in os.walk(workspace_path):
            # Apply exclusion rules to directories
            dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS and not d.startswith('.')]
            
            for f in files:
                ext = os.path.splitext(f)[1].lower()
                if ext in self.parsers and ext not in EXCLUDED_EXTENSIONS:
                    abs_p = os.path.join(root, f)
                    rel_p = os.path.relpath(abs_p, workspace_path)
                    all_files.append((abs_p, rel_p))

        # 2. Incremental detection
        to_index = []
        if force_full:
            # Recompute all hashes
            for abs_p, rel_p in all_files:
                h = compute_file_hash(abs_p)
                if h: to_index.append((abs_p, rel_p, h))
        else:
            for abs_p, rel_p in all_files:
                current_hash = compute_file_hash(abs_p)
                if current_hash is None:
                    continue
                    
                db_entry = self.db.file_index.get(project_id, rel_p)
                if not db_entry or db_entry['file_hash'] != current_hash:
                    to_index.append((abs_p, rel_p, current_hash))

        total_files = len(all_files)
        total_to_index = len(to_index)
        logger.info(f"[*] Indexing project {project_id}: total={total_files}, to_index={total_to_index}")

        # 3. Clean up deleted files
        await self.cleanup_deleted_files(project_id, workspace_path, all_files)

        # 4. Process files
        if total_to_index > 0:
            progress_interval = max(1, total_to_index // 20)
            for i, item in enumerate(to_index):
                abs_p, rel_p, f_hash = item
                await self.index_file(project_id, abs_p, rel_p, f_hash)
                
                if on_progress and (i + 1) % progress_interval == 0:
                    await on_progress({
                        "current": i + 1,
                        "total": total_to_index,
                        "percent": round((i + 1) / total_to_index * 100, 1),
                        "current_file": rel_p
                    })

        # Update project level stats
        final_file_count = self.db.get_project_file_count(project_id)
        final_symbol_count = self.db.get_project_symbol_count(project_id)
        self.db.update_project_stats(
            project_id, 
            total_files=final_file_count, 
            total_symbols=final_symbol_count
        )

    async def index_file(self, project_id: str, abs_path: str, rel_path: str, f_hash: str = None):
        """Index a single file and update both file_index and code_symbols."""
        ext = os.path.splitext(abs_path)[1].lower()
        parser = self.parsers.get(ext)
        if not parser: return

        try:
            # Use thread for IO
            def read_and_parse():
                with open(abs_path, "r", encoding="utf-8") as f:
                    code = f.read()
                return parser.parse(code, rel_path), len(code)
            
            symbols, f_size = await asyncio.to_thread(read_and_parse)
            
            # Use provided hash or compute if missing
            actual_hash = f_hash or compute_file_hash(abs_path)
            
            # Atomic-ish update: delete old symbols and upsert new ones
            self.db.code_symbols.delete_by_file(project_id, rel_path)
            for sym in symbols:
                self.db.code_symbols.upsert(project_id=project_id, file_path=rel_path, **sym)
            
            # Update file index
            self.db.file_index.upsert(project_id, rel_path, actual_hash, f_size)
            
        except Exception as e:
            logger.error(f"Failed to index {rel_path}: {e}")

    async def cleanup_deleted_files(self, project_id: str, workspace_path: str, current_files_list: List):
        """Removes indices for files that no longer exist on disk."""
        current_rel_paths = {rel_p for _, rel_p in current_files_list}
        db_entries = self.db.file_index.get_by_project(project_id)
        db_paths = {e['file_path'] for e in db_entries}
        
        deleted_paths = db_paths - current_rel_paths
        if deleted_paths:
            logger.info(f"[*] Cleaning up {len(deleted_paths)} deleted files for project {project_id}")
            for dp in deleted_paths:
                self.db.code_symbols.delete_by_file(project_id, dp)
                self.db.file_index.delete(project_id, dp)
