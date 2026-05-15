import logging
import asyncio
import os
from datetime import datetime
from src.persistence.database import KanbanDB
from src.persistence.embedding import embedding_service
import json

logger = logging.getLogger(__name__)

async def generate_card_summary_task(card_id: str, max_retries: int = 3, transition_header: str = None):
    """
    Background task to generate summary and embedding for a card.
    Always generates a new summary of the current session state and 
    prepends it to the existing summary history.
    """
    db = KanbanDB()
    
    # --- PHASE 1: SUMMARY GENERATION ---
    new_summary_content = None
    for attempt in range(max_retries):
        try:
            # 1. Get card details
            card = await asyncio.to_thread(db.cards.get_by_id, card_id)
            if not card:
                logger.error(f"Card {card_id} not found for summary task")
                return
                
            # 2. Get session history
            messages = await asyncio.to_thread(db.sessions.get_history, card_id, limit=100)
            if not messages:
                logger.info(f"No messages for card {card_id}, skipping summary")
                return
                
            # 3. Generate NEW summary for the current state using LLM
            await asyncio.to_thread(embedding_service.is_available)
            summary_model = os.getenv("SUMMARY_MODEL", "gpt-4o-mini")
            logger.info(f"Generating new summary for card {card_id} using model: {summary_model} (Attempt {attempt+1})")
            
            new_summary_content = await asyncio.to_thread(
                embedding_service.generate_summary, 
                card['title'], messages, model=summary_model
            )
            if not new_summary_content:
                raise Exception("LLM returned empty summary")
            
            # 4. Handle Incremental Storage
            # Get existing history
            summary_obj = await asyncio.to_thread(db.summaries.get, card_id)
            existing_history = summary_obj['summary'] if summary_obj else ""
            
            # Prepare the new block
            new_block = new_summary_content
            if transition_header:
                new_block = f"{transition_header}{new_summary_content}"
            
            # Combine: [New Block] \n\n [Old History]
            combined_summary = new_block
            if existing_history:
                combined_summary = f"{new_block}\n\n{existing_history}"
            
            # 5. Save combined summary to database
            # Sync to card display ONLY if NOT completed
            sync_to_card = card.get("status") != "completed"
            await asyncio.to_thread(db.update_card_summary, card_id, combined_summary, sync_to_card=sync_to_card)
            
            logger.info(f"Incremental summary saved for card {card_id}")
            break # Success, move to embedding phase
            
        except Exception as e:
            wait_time = 2 ** attempt
            if attempt < max_retries - 1:
                logger.warning(f"Summary phase failed for card {card_id}: {e}. Retrying in {wait_time}s...")
                await asyncio.sleep(wait_time)
            else:
                logger.error(f"Failed to generate summary after {max_retries} attempts for card {card_id}")
                return

    # --- PHASE 2: EMBEDDING GENERATION ---
    if new_summary_content:
        # We generate embedding ONLY for the new summary content to keep it representative 
        # of the current state, or for the whole history? 
        # Usually, the current block is what's most relevant for search.
        for emb_attempt in range(max_retries):
            try:
                logger.info(f"Generating embedding for card {card_id} (Attempt {emb_attempt+1})")
                emb = await asyncio.to_thread(embedding_service.get_embedding, new_summary_content)
                if emb:
                    await asyncio.to_thread(db.cards.update_card_embedding, card_id, emb)
                    logger.info(f"Embedding generated and saved for card {card_id}")
                    return # Success
                else:
                    raise Exception("Embedding service returned None")
            except Exception as emb_e:
                wait_time = 2 ** emb_attempt
                if emb_attempt < max_retries - 1:
                    logger.warning(f"Embedding attempt {emb_attempt+1} failed for card {card_id}: {emb_e}. Retrying...")
                    await asyncio.sleep(wait_time)
                else:
                    logger.error(f"Non-fatal: Failed to generate embedding for card {card_id} after {max_retries} attempts")

