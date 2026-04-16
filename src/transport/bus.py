import asyncio
import json
from typing import Dict, Set

class NotificationBus:
    """Simple async pub/sub for cross-module notifications."""
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(NotificationBus, cls).__new__(cls)
            cls._instance._subscribers = {} # card_id -> Set[asyncio.Queue]
        return cls._instance

    def publish(self, card_id: str, message: dict):
        # logger.debug is not available here without import, use print for now
        # print(f"[Bus] Publishing to {card_id}: {message.get('type')}")
        if card_id in self._subscribers:
            for queue in self._subscribers[card_id]:
                queue.put_nowait(message)

    def subscribe(self, card_id: str) -> asyncio.Queue:
        queue = asyncio.Queue()
        if card_id not in self._subscribers:
            self._subscribers[card_id] = set()
        self._subscribers[card_id].add(queue)
        return queue

    def unsubscribe(self, card_id: str, queue: asyncio.Queue):
        if card_id in self._subscribers:
            self._subscribers[card_id].discard(queue)
            if not self._subscribers[card_id]:
                del self._subscribers[card_id]

# Global instance
bus = NotificationBus()
