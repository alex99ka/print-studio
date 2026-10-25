"""The home server: /health, /report, and the background jobs (jobs.py)."""

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import backup, firebase, jobs, telegram

logging.basicConfig(level=logging.INFO)
APP = os.environ.get("APP_NAME") or "האפליקציה"


@asynccontextmanager
async def lifespan(_: FastAPI):
    tasks = []
    if os.environ.get("RUN_JOBS", "1") == "1":
        tasks = [asyncio.create_task(jobs.every_minute()), asyncio.create_task(jobs.every_day(jobs.daily_backup, 3))]
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)
# The web app calls from its Hosting origin; tokens, not cookies, so no credentials.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o for o in os.environ.get("WEB_ORIGINS", "").split(",") if o] or ["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


@app.middleware("http")
async def safety_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


@app.get("/health")
def health() -> dict:
    """For Uptime Kuma and the app's diagnostics screen. No secrets."""
    return {
        "ok": True,
        "last_backup": backup.last(),
        "backup": backup.configured(),
        "telegram": telegram.configured(),
    }


class Report(BaseModel):
    text: str = Field(max_length=4000)
    email: str | None = None
    version: str = Field(default="", max_length=50)
    platform: str = Field(default="", max_length=20)
    errors: list[str] = Field(default_factory=list, max_length=20)
    diagnostics: list[str] = Field(default_factory=list, max_length=30)


@app.post("/report")
def report(r: Report, user: Annotated[dict, Depends(firebase.current_user)]) -> dict:
    """Settings › "דיווח על בעיה" → the builder's Telegram."""
    telegram.send(
        f"🐞 {APP} · {user.get('email')} · {r.version} {r.platform}\n{r.text}\n\n"
        + "\n".join(r.diagnostics)
        + ("\n\nשגיאות:\n" + "\n".join(r.errors) if r.errors else "")
    )
    return {"ok": True}


@app.post("/backup")
def backup_now(_: Annotated[dict, Depends(firebase.current_user)]) -> dict:
    return {"file": backup.run()}
