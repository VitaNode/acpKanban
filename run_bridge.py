#!/usr/bin/env python3
"""
acpKanban Bridge - 入口脚本

用法:
    python3 run_bridge.py [参数]

参数与 acp_bridge_relay.py 相同:
    --user-id, --relay-url, --token, --workspace-cwd 等
"""

import sys
import os

# 确保项目根目录在 sys.path 中
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from src.transport.bridge import main

bridge_instance = None

async def run_with_export():
    global bridge_instance
    from src.transport.bridge import UnifiedBridge
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--user-id"); p.add_argument("--relay-url"); p.add_argument("--token"); p.add_argument("--e2ee-key"); p.add_argument("--workspace-cwd")
    args, unknown = p.parse_known_args()
    
    bridge_instance = UnifiedBridge(args.user_id, args.relay_url, token=args.token, session_key=args.e2ee_key, workspace_cwd=args.workspace_cwd)
    
    # Trigger indexing if workspace_cwd is set
    if args.workspace_cwd:
        async def background_index():
            from src.persistence.database import KanbanDB
            from src.persistence.embedding import embedding_service
            db = KanbanDB()
            # Try to find a project with this workspace path
            projects = db.get_projects()
            target_project = next((p for p in projects if p.get('workspace_path') == args.workspace_cwd), None)
            if target_project:
                print(f"[*] Auto-indexing workspace: {args.workspace_cwd}")
                await embedding_service.index_codebase(target_project['id'], args.workspace_cwd)
        
        asyncio.create_task(background_index())

    await bridge_instance.start()

if __name__ == "__main__":
    import asyncio
    import traceback
    try:
        asyncio.run(run_with_export())
    except KeyboardInterrupt:
        print("\nBridge stopped by user.")
    except Exception as e:
        print(f"\n❌ Bridge crashed with error: {e}")
        traceback.print_exc()
        sys.exit(1)
