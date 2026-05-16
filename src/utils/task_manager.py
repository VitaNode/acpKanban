import asyncio
import logging
from typing import Dict, Any, Optional, Callable

logger = logging.getLogger("TaskManager")

class BackgroundTaskManager:
    def __init__(self):
        self._tasks: Dict[str, asyncio.Task] = {}

    def start_task(self, task_id: str, coro, on_complete: Optional[Callable] = None):
        """Starts a background task and tracks it."""
        if task_id in self._tasks and not self._tasks[task_id].done():
            logger.warning(f"Task {task_id} is already running. Cancelling old task.")
            old = self._tasks[task_id]
            old.cancel()

        task = asyncio.create_task(coro)
        self._tasks[task_id] = task

        def _cleanup(t):
            self._tasks.pop(task_id, None)
            if on_complete:
                try:
                    on_complete(t)
                except Exception as e:
                    logger.error(f"Error in task {task_id} completion callback: {e}")

        task.add_done_callback(_cleanup)
        return task

    async def cancel_task(self, task_id: str):
        """Cancels a specific task."""
        task = self._tasks.get(task_id)
        if task and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            logger.info(f"Task {task_id} cancelled.")

    async def shutdown(self):
        """Cancels all tracked tasks."""
        logger.info(f"Shutting down TaskManager, cancelling {len(self._tasks)} tasks.")
        for tid in list(self._tasks.keys()):
            await self.cancel_task(tid)

# Global instance for easy access
task_manager = BackgroundTaskManager()
