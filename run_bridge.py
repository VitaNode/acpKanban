#!/usr/bin/env python3
"""
MyBot Bridge - 入口脚本

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

if __name__ == "__main__":
    main()
