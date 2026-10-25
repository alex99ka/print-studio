"""Firebase Admin with the server's own service account: verify ID tokens,
read Firestore, send pushes. The account has only `Cloud Datastore User` and
`Firebase Cloud Messaging API Admin` (README), never firebase-adminsdk."""

import os
import time
from typing import Annotated

import firebase_admin
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth, firestore, messaging

_app = None


def app():
    global _app
    if _app is None:
        _app = firebase_admin.initialize_app(options={"projectId": os.environ["GOOGLE_CLOUD_PROJECT"]})
    return _app


def db():
    return firestore.client(app())


_access: tuple[float, set[str], set[str]] = (0.0, set(), set())


def access() -> tuple[set[str], set[str]]:
    """config/access: the allowlist (the same document the rules read) and the
    early users. Cached for five minutes."""
    global _access
    at, emails, early = _access
    if time.time() - at > 300:
        d = db().document("config/access").get().to_dict() or {}
        emails = {e.lower() for e in d.get("emails", [])}
        early = {e.lower() for e in d.get("earlyUsers", [])}
        _access = (time.time(), emails, early)
    return emails, early


def current_user(creds: Annotated[HTTPAuthorizationCredentials, Depends(HTTPBearer())]) -> dict:
    """Only verified accounts on the allowlist get through."""
    try:
        user = auth.verify_id_token(creds.credentials, app=app())
    # Only a bad token is the caller's fault; anything else surfaces as a 500.
    except (auth.InvalidIdTokenError, auth.ExpiredIdTokenError):
        raise HTTPException(401, "Invalid or expired token") from None
    if not user.get("email_verified") or user.get("email", "").lower() not in access()[0]:
        raise HTTPException(403, "Not allowed")
    return user


def push(tokens: list[str], title: str, body: str, data: dict | None = None) -> list[str]:
    """Sends to each token; returns the tokens FCM says are gone, to remove."""
    if not tokens:
        return []
    res = messaging.send_each_for_multicast(
        messaging.MulticastMessage(
            tokens=tokens,
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
        ),
        app=app(),
    )
    return [
        t
        for t, r in zip(tokens, res.responses)
        if not r.success and isinstance(r.exception, messaging.UnregisteredError)
    ]
