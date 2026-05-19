import asyncio
import sys
import os
import signal
import argparse
from multiprocessing import Process

# 确保能找到 src 模块
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from src.config.manager import config
from src.logger import setup_logger

logger = setup_logger("Launcher")

def run_api():
    """启动 FastAPI 后端 (它会自动启动一个集成的 Bridge)"""
    import uvicorn
    from api.main import app
    
    # 设置环境变量，让 API 内部的 Bridge 连到本地 Relay
    os.environ["RELAY_URL"] = "ws://127.0.0.1:8766"
    os.environ["RELAY_TOKEN"] = config.relay_token
    
    logger.info(f"[*] Starting API Server on {config.api_bind_host}:8000...")
    # 注意：API 内部 Bridge 启动时如果发现 8766 被占用会报错，
    # 所以我们要确保 API 启动前，端口是分配好的。
    uvicorn.run(app, host=config.api_bind_host, port=8000, log_level="warning")

def run_relay():
    """仅启动本地 Relay 服务"""
    import asyncio
    from src.transport.relay_server import RelayServer
    
    async def _run():
        # 启动 Relay Server (监听 8766 端口)
        # 这是 iPhone 接入的唯一入口
        relay = RelayServer(host="0.0.0.0", port=8766, token=config.relay_token)
        logger.info("[*] Local Relay Server starting on 0.0.0.0:8766...")
        await relay.start()

    asyncio.run(_run())

if __name__ == "__main__":
    # 1. 打印凭据
    print("="*50)
    print("      MYBOT ALL-IN-ONE SERVICE IS STARTING")
    print("="*50)
    print(f"  USER_ID:     {config.user_id}")
    print(f"  RELAY_TOKEN: {config.relay_token}")
    print(f"  API_TOKEN:   {config.api_token}")
    print("="*50)
    print("  Use these credentials in your iPhone App.")
    print("  Mode: Local (Home/Office)")
    print("  Target: Your Mac's LAN IP")
    print("="*50)

    # 2. 先启动 Relay (抢占 8766 端口)
    relay_p = Process(target=run_relay)
    relay_p.start()

    # 等一下确保 Relay 占住了端口
    import time
    time.sleep(1)

    # 3. 启动 API (它内部的 Bridge 会去连上面的 Relay)
    # 我们需要修改 Bridge 代码，如果端口被占用（说明是在 All-in-one 模式），不崩溃而是跳过本地 Server 启动
    api_p = Process(target=run_api)
    api_p.start()

    def signal_handler(sig, frame):
        logger.info("\n[!] Shutting down services...")
        api_p.terminate()
        relay_p.terminate()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    
    api_p.join()
    relay_p.join()
