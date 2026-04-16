import re

def estimate_tokens(text: str) -> int:
    """
    Estimates the number of tokens in a text string.
    Uses a standard heuristic: 1 token ~= 4 characters for English.
    For code, we use a more granular word-based heuristic.
    """
    if not text:
        return 0
    # Average of character count / 4 and word count * 1.3
    words = len(re.findall(r'\w+', text))
    chars = len(text)
    return int(( (chars / 4.0) + (words * 1.3) ) / 2)

def log_context_stats(logger, stage: str, context: str):
    """Logs the estimated token size of the built context."""
    tokens = estimate_tokens(context)
    logger.info(f"[TokenStats] {stage} Context Size: ~{tokens} tokens ({len(context)} chars)")
    return tokens
