import logging
import time
from database import KanbanDB
from embedding import embedding_service
import json

logger = logging.getLogger(__name__)

def generate_card_summary_task(card_id: str, max_retries: int = 3):
    """
    Background task to generate summary and embedding for a completed card with retry logic.
    """
    db = KanbanDB()
    
    for attempt in range(max_retries):
        try:
            # 1. Get card details
            card = db.get_card(card_id)
            if not card:
                logger.error(f"Card {card_id} not found for summary task")
                return
                
            # 2. Get session history
            messages = db.get_session_history(card_id, limit=100)
            if not messages:
                logger.info(f"No messages for card {card_id}, skipping summary")
                return
                
            # 3. Generate summary using LLM
            summary = embedding_service.generate_summary(card['title'], messages)
            if not summary:
                raise Exception("LLM returned empty summary")
                
            # 4. Save summary to database (incremental handled by db)
            db.save_summary(card_id, summary)
            logger.info(f"Summary generated and saved for card {card_id}")
            
            # 5. Generate embedding for the summary
            emb = embedding_service.get_embedding(summary)
            if emb:
                db.upsert_card_embedding(card_id, emb)
                logger.info(f"Embedding generated and saved for card {card_id}")
            else:
                logger.warning(f"Failed to generate embedding for card {card_id}")
            
            return # Success
                
        except Exception as e:
            wait_time = 2 ** attempt
            logger.warning(f"Attempt {attempt + 1} failed for card {card_id}: {e}. Retrying in {wait_time}s...")
            if attempt < max_retries - 1:
                time.sleep(wait_time)
            else:
                logger.error(f"Failed to generate summary after {max_retries} attempts for card {card_id}")
