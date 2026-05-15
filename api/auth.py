import random
import time
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from typing import Dict, Optional
from src.config.manager import config
from src.logger import setup_logger

logger = setup_logger("AuthAPI")
router = APIRouter(prefix="/api/auth", tags=["auth"])

# In-memory storage for pairing codes: { code: {"expires": timestamp} }
# For a single-user system, we just need to know if the code is valid.
# When validated, it returns the current machine's config.
pairing_codes: Dict[str, float] = {}

class PairingResponse(BaseModel):
    code: str
    expires_in: int

class ExchangeRequest(BaseModel):
    code: str

class ExchangeResponse(BaseModel):
    user_id: str
    relay_token: str
    relay_url: str

@router.get("/pairing-code", response_model=PairingResponse)
async def generate_pairing_code():
    """Generate a 6-digit pairing code valid for 5 minutes."""
    # Clean up expired codes
    now = time.time()
    expired = [c for c, t in pairing_codes.items() if t < now]
    for c in expired:
        del pairing_codes[c]
        
    code = "".join([str(random.randint(0, 9)) for _ in range(6)])
    expiry = now + 300  # 5 minutes
    pairing_codes[code] = expiry
    
    logger.info(f"Generated pairing code: {code}")
    return {"code": code, "expires_in": 300}

@router.post("/pair", response_model=ExchangeResponse)
async def exchange_pairing_code(req: ExchangeRequest):
    """Exchange a pairing code for full credentials."""
    now = time.time()
    code = req.code
    
    if code not in pairing_codes:
        logger.warning(f"Invalid pairing code attempt: {code}")
        raise HTTPException(status_code=401, detail="Invalid or expired pairing code")
    
    if pairing_codes[code] < now:
        del pairing_codes[code]
        logger.warning(f"Expired pairing code used: {code}")
        raise HTTPException(status_code=401, detail="Invalid or expired pairing code")
    
    # Valid code! Consume it and return config
    del pairing_codes[code]
    logger.info(f"Pairing successful using code: {code}")
    
    return {
        "user_id": config.user_id,
        "relay_token": config.relay_token,
        "relay_url": config.relay_url
    }
