import asyncio
import json
from typing import Dict, Set, Any

class NotificationBus:
    """Simple async pub/sub for cross-module notifications with stale queue cleanup."""
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(NotificationBus, cls).__new__(cls)
            cls._instance._subscribers = {} # channel_id -> Set[asyncio.Queue]
        return cls._instance

    def publish(self, channel_id: str, message: dict):
        """Publish a message to all subscribers of a channel."""
        if channel_id in self._subscribers:
            # Create a copy to iterate while allowing modification (cleanup)
            queues = list(self._subscribers[channel_id])
            for queue in queues:
                try:
                    if queue.qsize() < 100: # Limit queue size to prevent memory leak
                        queue.put_nowait(message)
                    else:
                        # Drop oldest message if full
                        try:
                            queue.get_nowait()
                            queue.put_nowait(message)
                        except asyncio.QueueEmpty:
                            queue.put_nowait(message)
                except Exception:
                    pass

    def subscribe(self, channel_id: str) -> asyncio.Queue:
        """Subscribe to a channel."""
        queue = asyncio.Queue(maxsize=100)
        if channel_id not in self._subscribers:
            self._subscribers[channel_id] = set()
        self._subscribers[channel_id].add(queue)
        return queue

    def unsubscribe(self, channel_id: str, queue: asyncio.Queue):
        """Unsubscribe a specific queue from a channel."""
        if channel_id in self._subscribers:
            self._subscribers[channel_id].discard(queue)
            if not self._subscribers[channel_id]:
                del self._subscribers[channel_id]

    def cleanup_stale_queues(self, channel_id: str):
        """Explicitly cleanup channels with no active subscribers."""
        if channel_id in self._subscribers and not self._subscribers[channel_id]:
            del self._subscribers[channel_id]

# Global instance
bus = NotificationBus()
