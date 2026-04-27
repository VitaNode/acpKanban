from pydantic import BaseModel, Field, field_validator
from typing import Optional, List, Dict, Any
from datetime import datetime
from enum import Enum
import re


class CardCreateRequest(BaseModel):
    column_id: str = Field(..., min_length=1, max_length=50)
    title: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(default="", max_length=5000)
    acp_provider_id: Optional[str] = Field(None, max_length=50)
    feature_id: Optional[str] = Field(None, max_length=50)

    @field_validator('title')
    @classmethod
    def sanitize_title(cls, v):
        return re.sub(r'[<>\'"]', '', v).strip()


class CardUpdateRequest(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=5000)
    feature_id: Optional[str] = Field(None, max_length=50)

    @field_validator('title')
    @classmethod
    def sanitize_title(cls, v):
        if v is None: return v
        return re.sub(r'[<>\'"]', '', v).strip()


class CardMoveRequest(BaseModel):
    target_column_id: str = Field(..., min_length=1, max_length=50)
    target_position: Optional[int] = Field(None, ge=0)


class CardResponse(BaseModel):
    id: str
    column_id: str
    title: str
    description: str
    position: int
    status: str = "active"
    plan_status: str = "plan"
    feature_id: Optional[str] = None
    completed_at: Optional[str] = None
    parent_id: Optional[str] = None
    session_count: int
    acp_session_id: Optional[str] = None
    acp_provider_id: Optional[str] = None
    summary: Optional[str] = None
    created_at: str
    updated_at: str
    column_name: Optional[str] = None
    project_id: Optional[str] = None


class CardListResponse(BaseModel):
    cards: List[CardResponse]
    total: int


class SessionMessageRequest(BaseModel):
    role: str = Field(..., pattern="^(user|assistant|system)$")
    content: str = Field(..., min_length=1)
    metadata: Optional[Dict[str, Any]] = None


class SessionMessageResponse(BaseModel):
    id: int
    card_id: str
    role: str
    content: str
    metadata: Optional[Dict[str, Any]] = None
    is_complete: bool
    created_at: str


class SessionHistoryResponse(BaseModel):
    card_id: str
    card_title: str
    messages: List[SessionMessageResponse]
    total: int


class TimelineEventResponse(BaseModel):
    id: int
    project_id: str
    card_id: Optional[str] = None
    card_title: Optional[str] = None
    event_type: str
    content: str
    metadata: Optional[Dict[str, Any]] = None
    timestamp: str


class ProjectTimelineResponse(BaseModel):
    project_id: str
    project_name: str
    events: List[TimelineEventResponse]
    total: int


class MilestoneCreateRequest(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=2000)
    target_date: Optional[str] = None

    @field_validator('title')
    @classmethod
    def sanitize_title(cls, v):
        return re.sub(r'[<>\'"]', '', v).strip()


class MilestoneUpdateRequest(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=2000)
    status: Optional[str] = Field(None, pattern="^(active|completed|archived)$")
    target_date: Optional[str] = None

    @field_validator('title')
    @classmethod
    def sanitize_title(cls, v):
        if v is None: return v
        return re.sub(r'[<>\'"]', '', v).strip()


class FeatureCreateRequest(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=2000)

    @field_validator('title')
    @classmethod
    def sanitize_title(cls, v):
        return re.sub(r'[<>\'"]', '', v).strip()


class FeatureUpdateRequest(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=200)
    description: Optional[str] = Field(None, max_length=2000)
    status: Optional[str] = Field(None, pattern="^(active|completed|archived)$")

    @field_validator('title')
    @classmethod
    def sanitize_title(cls, v):
        if v is None: return v
        return re.sub(r'[<>\'"]', '', v).strip()


class FeatureResponse(BaseModel):
    id: str
    milestone_id: str
    title: str
    description: Optional[str]
    status: str
    progress: float
    counts: Optional[Dict[str, int]] = None
    cards: Optional[List[Dict[str, Any]]] = None


class MilestoneResponse(BaseModel):
    id: str
    project_id: str
    title: str
    description: Optional[str]
    status: str
    target_date: Optional[str] = None
    progress: float
    features: List[FeatureResponse]


class SuccessResponse(BaseModel):
    message: str
    data: Optional[Dict[str, Any]] = None


class ErrorResponse(BaseModel):
    error: str
    message: str
    details: Optional[Dict[str, Any]] = None


class ProviderInfo(BaseModel):
    id: str
    name: str
    icon: Optional[str] = None


class ProviderListResponse(BaseModel):
    providers: List[ProviderInfo]
    default_provider: str


class ProjectResponse(BaseModel):
    id: str
    name: str
    description: Optional[str] = None
    workspace_path: Optional[str] = None
    created_at: str
    updated_at: str
    card_count: int = 0
