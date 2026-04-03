import logging
from database import KanbanDB
from embedding import embedding_service
import json

logger = logging.getLogger(__name__)

def generate_card_summary_task(card_id: str):
    """
    Background task to generate summary and embedding for a completed card.
    """
    db = KanbanDB()
    
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
            logger.error(f"Failed to generate summary for card {card_id}")
            return
            
        # 4. Save summary to database
        db.save_summary(card_id, summary)
        logger.info(f"Summary generated and saved for card {card_id}")
        
        # 5. Generate embedding for the summary
        emb = embedding_service.get_embedding(summary)
        if emb:
            db.upsert_card_embedding(card_id, emb)
            logger.info(f"Embedding generated and saved for card {card_id}")
        else:
            logger.warning(f"Failed to generate embedding for card {card_id}")
            
    except Exception as e:
        logger.error(f"Error in generate_card_summary_task for card {card_id}: {e}")
