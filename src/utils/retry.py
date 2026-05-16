import asyncio
import functools
import logging
from typing import Type, Union, Tuple, Callable, Any

logger = logging.getLogger("Retry")

def with_retry(
    retries: int = 3,
    delay: float = 1.0,
    backoff: float = 2.0,
    exceptions: Union[Type[Exception], Tuple[Type[Exception], ...]] = Exception
):
    """
    Decorator for retrying async functions.
    :param retries: Number of retry attempts.
    :param delay: Initial delay between retries in seconds.
    :param backoff: Multiplier for delay after each retry.
    :param exceptions: Exception type(s) to catch and retry.
    """
    def decorator(func):
        @functools.wraps(func)
        async def wrapper(*args, **kwargs):
            attempt_delay = delay
            for attempt in range(retries + 1):
                try:
                    return await func(*args, **kwargs)
                except exceptions as e:
                    if attempt == retries:
                        logger.error(f"Function {func.__name__} failed after {retries} retries: {e}")
                        raise
                    
                    logger.warning(
                        f"Attempt {attempt + 1}/{retries + 1} for {func.__name__} failed: {e}. "
                        f"Retrying in {attempt_delay:.2f}s..."
                    )
                    await asyncio.sleep(attempt_delay)
                    attempt_delay *= backoff
            return await func(*args, **kwargs)
        return wrapper
    return decorator

async def with_timeout(coro, timeout: float, name: str = "Task"):
    """Wrapper to run a coroutine with a timeout."""
    try:
        return await asyncio.wait_for(coro, timeout=timeout)
    except asyncio.TimeoutError:
        logger.error(f"{name} timed out after {timeout}s")
        raise
