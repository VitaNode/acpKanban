import os
import json
import logging
import asyncio
import subprocess
import datetime
import math
from pathlib import Path
from dotenv import load_dotenv

import google.generativeai as genai
from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, MessageHandler, filters

# --- Configuration & Setup ---
load_dotenv()
TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USER_ID = int(os.getenv("ALLOWED_USER_ID", "0"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
EMBEDDING_API_KEY = os.getenv("EMBEDDING_API_KEY")

# Configure Gemini for Embeddings
genai.configure(api_key=EMBEDDING_API_KEY)

# Logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

# --- Simple Vector Memory Manager ---
class VectorMemory:
    def __init__(self, storage_path="gemini_memory/memory.json"):
        self.storage_path = Path(storage_path)
        self.memory = self._load()

    def _load(self):
        if self.storage_path.exists():
            try:
                with open(self.storage_path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                logging.error(f"Error loading memory: {e}")
        return []

    def _save(self):
        self.storage_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.storage_path, "w", encoding="utf-8") as f:
            json.dump(self.memory, f, ensure_ascii=False, indent=2)

    def _cosine_similarity(self, v1, v2):
        dot_product = sum(a * b for a, b in zip(v1, v2))
        magnitude1 = math.sqrt(sum(a * a for a in v1))
        magnitude2 = math.sqrt(sum(b * b for b in v2))
        if magnitude1 == 0 or magnitude2 == 0:
            return 0
        return dot_product / (magnitude1 * magnitude2)

    async def add_entry(self, text):
        try:
            # Generate embedding using Google Cloud
            result = genai.embed_content(
                model="models/gemini-embedding-001",
                content=text,
                task_type="retrieval_document"
            )
            embedding = result['embedding']
            
            self.memory.append({
                "text": text,
                "embedding": embedding,
                "timestamp": datetime.datetime.now().isoformat()
            })
            self._save()
            logging.info(f"Added memory entry: {text[:50]}...")
        except Exception as e:
            logging.error(f"Failed to add memory: {e}")

    async def search(self, query, top_k=3):
        if not self.memory:
            return []
        try:
            # Generate embedding for the query
            result = genai.embed_content(
                model="models/gemini-embedding-001",
                content=query,
                task_type="retrieval_query"
            )
            query_embedding = result['embedding']
            
            # Compute similarities
            similarities = []
            for entry in self.memory:
                score = self._cosine_similarity(query_embedding, entry['embedding'])
                similarities.append((score, entry['text']))
            
            # Sort by similarity descending
            similarities.sort(key=lambda x: x[0], reverse=True)
            return similarities[:top_k]
        except Exception as e:
            logging.error(f"Search failed: {e}")
            return []

# Initialize Memory
memory_manager = VectorMemory()

# --- Telegram Handlers ---

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    # 1. Permission check
    user_id = update.effective_user.id
    if user_id != ALLOWED_USER_ID:
        logging.warning(f"Unauthorized access denied: User ID {user_id}")
        await update.message.reply_text("❌ Sorry, this bot is for authorized users only.")
        return

    user_text = update.message.text
    if not user_text:
        return

    # Handle /search command manually if needed
    if user_text.startswith("/search "):
        query = user_text.replace("/search ", "").strip()
        results = await memory_manager.search(query)
        if not results:
            await update.message.reply_text("🔍 No relevant memories found.")
        else:
            resp = "🔍 Found these relevant memories:\n\n"
            for score, text in results:
                resp += f"🔹 (Score: {score:.2f}) {text}\n\n"
            await update.message.reply_text(resp)
        return

    # 2. Context Retrieval (RAG)
    relevant_memories = await memory_manager.search(user_text, top_k=3)
    context_string = ""
    if relevant_memories:
        context_string = "\n\n[Relevant History/Context]:\n"
        for _, text in relevant_memories:
            context_string += f"- {text}\n"

    # 3. Status feedback
    status_msg = await update.message.reply_text("🧠 Gemini is thinking and executing (YOLO mode with Memory)...")

    # 4. Prepare Prompt and Command
    # We inject the context into the user text
    full_prompt = f"{user_text}{context_string}"
    
    cmd = ["gemini", full_prompt, "--approval-mode", "yolo", "--output-format", "json"]
    
    try:
        # Run Gemini CLI
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        
        if process.returncode == 0:
            try:
                result = json.loads(stdout.decode())
                response_text = result.get("response", "✅ Task executed successfully.")
            except json.JSONDecodeError:
                response_text = stdout.decode() or "✅ Task executed with empty output."
        else:
            response_text = f"❌ Gemini CLI execution failed:\n```bash\n{stderr.decode()}\n```"
        
        # 5. Store Interaction in Memory
        # We store both the question and the answer as a single context unit
        interaction_summary = f"User: {user_text}\nGemini: {response_text}"
        await memory_manager.add_entry(interaction_summary)
        
    except Exception as e:
        response_text = f"⚠️ An error occurred: {str(e)}"

    # 6. Final Update
    if len(response_text) > 4000:
        response_text = response_text[:3900] + "\n\n(Response truncated...)"
        
    try:
        await context.bot.edit_message_text(
            chat_id=update.effective_chat.id,
            message_id=status_msg.message_id,
            text=response_text,
            parse_mode='Markdown'
        )
    except Exception:
        await context.bot.edit_message_text(
            chat_id=update.effective_chat.id,
            message_id=status_msg.message_id,
            text=response_text
        )

if __name__ == '__main__':
    # Ensure GEMINI_API_KEY is also available for the subprocess
    os.environ["GEMINI_API_KEY"] = GEMINI_API_KEY
    
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), handle_message))
    
    print(f"--- Gemini Telegram Bot Started (YOLO + Vector Memory) ---")
    print(f"--- Authorized User ID: {ALLOWED_USER_ID} ---")
    
    app.run_polling()
