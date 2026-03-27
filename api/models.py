from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from datetime import datetime
from enum import Enum


class CardCreateRequest(BaseModel):
    column_id: str = Field(..., min_length=1, max_length=50)
    title: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(default="", max_length=5000)


class CardUpdateRequest(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=5000)


class CardMoveRequest(BaseModel):
    target_column_id: str = Field(..., min_length=1, max_length=50)
    target_position: Optional[int] = Field(None, ge=0)


class SessionRole(str, Enum):
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"
    TOOL = "tool"


class SessionMessageRequest(BaseModel):
    role: SessionRole = Field(..., description="Role of the message sender")
    content: str = Field(..., min_length=1)
    metadata: Optional[Dict[str, Any]] = None


class CardResponse(BaseModel):
    id: str
    column_id: str
    title: str
    description: str
    position: int
    session_count: int
    created_at: str
    updated_at: str
    column_name: Optional[str] = None
    project_id: Optional[str] = None


class CardListResponse(BaseModel):
    cards: List[CardResponse]
    total: int


class SessionMessageResponse(BaseModel):
    id: int
    card_id: str
    role: str
    content: str
    metadata: Optional[Dict[str, Any]]
    created_at: str


class SessionHistoryResponse(BaseModel):
    card_id: str
    card_title: str
    messages: List[SessionMessageResponse]
    total: int


class TimelineEventResponse(BaseModel):
    id: int
    project_id: str
    card_id: Optional[str]
    card_title: Optional[str] = None
    event_type: str
    content: Optional[str]
    metadata: Optional[Dict[str, Any]]
    timestamp: str


class ProjectTimelineResponse(BaseModel):
    project_id: str
    project_name: str
    events: List[TimelineEventResponse]
    total: int


class ErrorResponse(BaseModel):
    error: str
    message: str
    details: Optional[Dict[str, Any]] = None


class SuccessResponse(BaseModel):
    message: str
    data: Optional[Dict[str, Any]] = None
