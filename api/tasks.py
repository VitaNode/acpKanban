import logging
import time
import os
from src.persistence.database import KanbanDB
from src.persistence.embedding import embedding_service
import json

logger = logging.getLogger(__name__)

def generate_card_summary_task(card_id: str, max_retries: int = 3):
    """
    Background task to generate summary and embedding for a completed card.
    Phase 1: Generate summary (retry whole task if fails)
    Phase 2: Generate embedding (retry only embedding if summary exists)
    """
    db = KanbanDB()
    
    # --- PHASE 1: SUMMARY GENERATION ---
    summary = None
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
                
            # 3. Check if summary already exists
            summary_obj = db.get_summary(card_id)
            if summary_obj:
                summary = summary_obj['summary']
                logger.info(f"Summary already exists for card {card_id}")
                break # Move to embedding phase
            
            # 4. Generate summary using LLM
            embedding_service.is_available()
            summary_model = os.getenv("SUMMARY_MODEL", "gpt-4o-mini")
            logger.info(f"Generating summary for card {card_id} using model: {summary_model} (Attempt {attempt+1})")
            
            summary = embedding_service.generate_summary(card['title'], messages, model=summary_model)
            if not summary:
                raise Exception("LLM returned empty summary")
            
            # 5. Save summary to database
            db.save_summary(card_id, summary)
            logger.info(f"Summary generated and saved for card {card_id}")
            break # Success, move to embedding phase
            
        except Exception as e:
            wait_time = 2 ** attempt
            if attempt < max_retries - 1:
                logger.warning(f"Summary phase failed for card {card_id}: {e}. Retrying in {wait_time}s...")
                time.sleep(wait_time)
            else:
                logger.error(f"Failed to generate summary after {max_retries} attempts for card {card_id}")
                return # Give up entirely

    # --- PHASE 2: EMBEDDING GENERATION ---
    if summary:
        for emb_attempt in range(max_retries):
            try:
                logger.info(f"Generating embedding for card {card_id} (Attempt {emb_attempt+1})")
                emb = embedding_service.get_embedding(summary)
                if emb:
                    db.upsert_card_embedding(card_id, emb)
                    logger.info(f"Embedding generated and saved for card {card_id}")
                    return # Success
                else:
                    raise Exception("Embedding service returned None")
            except Exception as emb_e:
                wait_time = 2 ** emb_attempt
                if emb_attempt < max_retries - 1:
                    logger.warning(f"Embedding attempt {emb_attempt+1} failed for card {card_id}: {emb_e}. Retrying...")
                    time.sleep(wait_time)
                else:
                    logger.error(f"Non-fatal: Failed to generate embedding for card {card_id} after {max_retries} attempts")
