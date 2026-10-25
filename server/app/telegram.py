"""Messages to the builder's Telegram: problem reports and job failures. The
bot is shared by every app (messages start with APP_NAME), so this only ever
calls sendMessage. Token and chat id live only in the Pi's .env."""

import logging
import os

import requests

log = logging.getLogger(__name__)


def configured() -> bool:
    return bool(os.environ.get("TELEGRAM_BOT_TOKEN") and os.environ.get("TELEGRAM_CHAT_ID"))


def send(text: str) -> None:
    if not configured():
        log.warning("Telegram is not set up; dropped: %s", text[:200])
        return
    r = requests.post(
        f"https://api.telegram.org/bot{os.environ['TELEGRAM_BOT_TOKEN']}/sendMessage",
        json={"chat_id": os.environ["TELEGRAM_CHAT_ID"], "text": text[:4000]},
        timeout=20,
    )
    r.raise_for_status()
