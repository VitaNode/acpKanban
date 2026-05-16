import logging
import uuid
import sys
import contextvars
from datetime import datetime

# Context variables to store the current IDs
request_id_var = contextvars.ContextVar("request_id", default=None)
project_id_var = contextvars.ContextVar("project_id", default=None)
card_id_var = contextvars.ContextVar("card_id", default=None)

class RequestIdFilter(logging.Filter):
    """
    Logging filter that adds the current IDs to the log record.
    """
    def filter(self, record):
        record.request_id = request_id_var.get() or "N/A"
        record.project_id = project_id_var.get() or "N/A"
        record.card_id = card_id_var.get() or "N/A"
        return True

def setup_logger(name="Kanban", level="INFO"):
    """
    Configure and return a structured logger.
    """
    logger = logging.getLogger(name)
    logger.setLevel(level)
    
    # Avoid duplicate handlers
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        
        # Define a structured format: [Timestamp] [Level] [ReqID] [PID] [CID] [Logger] Message
        formatter = logging.Formatter(
            "%(asctime)s [%(levelname)s] [%(request_id)s] [%(project_id)s] [%(card_id)s] [%(name)s] %(message)s"
        )
        handler.setFormatter(formatter)
        
        # Add the Request ID filter
        handler.addFilter(RequestIdFilter())
        
        logger.addHandler(handler)
        
        # Disable propagation to prevent double logging if root logger also has handlers
        logger.propagate = False
        
    return logger

def set_context_ids(request_id: str = None, project_id: str = None, card_id: str = None):
    """Set the current context IDs."""
    if request_id:
        request_id_var.set(request_id)
    if project_id:
        project_id_var.set(project_id)
    if card_id:
        card_id_var.set(card_id)

def set_request_id(req_id: str = None):
    """Set the current request ID in the context."""
    if not req_id:
        req_id = str(uuid.uuid4())[:8]
    request_id_var.set(req_id)
    return req_id

def clear_context():
    """Clear all context IDs."""
    request_id_var.set(None)
    project_id_var.set(None)
    card_id_var.set(None)

# Global base logger
logger = setup_logger()
