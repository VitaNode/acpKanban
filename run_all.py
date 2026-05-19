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
    """启动 FastAPI 后端"""
    import uvicorn
    from api.main import app
    logger.info(f"[*] Starting API Server on {config.api_bind_host}:8000...")
    uvicorn.run(app, host=config.api_bind_host, port=8000, log_level="warning")

def run_bridge_and_relay():
    """启动 Bridge 和本地 Relay 服务"""
    import asyncio
    from src.transport.bridge import UnifiedBridge
    from src.transport.relay_server import RelayServer
    
    async def _run():
        # 1. 启动 Relay Server (监听 8766 端口)
        # 传入 config.relay_token 以确保鉴权通过
        relay = RelayServer(host="0.0.0.0", port=8766, token=config.relay_token)
        relay_task = asyncio.create_task(relay.start())
        logger.info("[*] Local Relay Server started on 0.0.0.0:8766")

        # 等一下确保 Relay 起来了
        await asyncio.sleep(1)

        # 2. 启动 Bridge 并连到这个本地 Relay
        bridge = UnifiedBridge(
            user_id=config.user_id,
            relay_url="ws://127.0.0.1:8766",
            token=config.relay_token
        )
        logger.info(f"[*] Bridge connecting to local relay for user: {config.user_id}")
        await bridge.start()

    asyncio.run(_run())

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MyBot All-in-One Launcher")
    args = parser.parse_args()

    # 打印凭据方便用户拷贝
    print("="*50)
    print("      MYBOT ALL-IN-ONE SERVICE IS STARTING")
    print("="*50)
    print(f"  USER_ID:     {config.user_id}")
    print(f"  RELAY_TOKEN: {config.relay_token}")
    print(f"  API_TOKEN:   {config.api_token}")
    print("="*50)
    print("  Use these credentials in your iPhone App.")
    print("  Mode: Local (Home/Office)")
    print("  Target: Your Mac's LAN IP (or localhost on Mac)")
    print("="*50)

    # 启动 API 进程
    api_p = Process(target=run_api)
    api_p.start()

    # 启动 Bridge/Relay 进程
    service_p = Process(target=run_bridge_and_relay)
    service_p.start()

    def signal_handler(sig, frame):
        logger.info("\n[!] Shutting down services...")
        api_p.terminate()
        service_p.terminate()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    
    # 保持主进程运行
    api_p.join()
    service_p.join()
