"""דרישת תשלום (payment request). Each customer who still owes money on finished orders
(מוכן, נמסר) gets a numbered bill with its own link, /b/<token>. Bills are made on the
studio's billing day each month (config/billing.day, the 1st by default) and whenever Alex
asks. Alex sends the link on WhatsApp (the Pi never messages clients). A bill is a snapshot of
what was owed on the day it was made. Alex pastes the receipt app's message on it in the app,
which logs the payments and marks the bill paid.

Who writes what: here (Admin SDK) makes the bills and numbers them (counters/bills). The app
(firestore.rules) marks a bill sent, or paid with its receipt, or moves it to the trash
(deletedAt) and back. The daily job deletes bills that have been in the trash for 30 days.
"""

import html
import secrets
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse
from firebase_admin import firestore
from google.cloud.firestore_v1 import FieldFilter

from . import firebase, jobs, studio

router = APIRouter()
BILLED = ("ready", "delivered")
TRASH_DAYS = 30


def settings() -> dict:
    return firebase.db().document("config/billing").get().to_dict() or {}


def bill_lines(requests: list[tuple[str, dict]], quotes: dict[str, dict], paid: dict[str, int]) -> list[dict]:
    """What each finished request still owes on its approved quote, oldest request first."""
    lines = []
    for rid, r in sorted(requests, key=lambda x: str(x[1].get("createdAt") or "")):
        q = quotes.get(r.get("approvedQuoteId") or r.get("quoteId") or "")
        if r.get("status") not in BILLED or not q:
            continue
        m = studio.money(int(q.get("unit", 0)), int(q.get("qty", 1)), int(q.get("vatPercent", 18)), int(q.get("discount", 0)))
        due = max(m["total"] - paid.get(rid, 0), 0)
        if due:
            lines.append({"requestId": rid, "title": r.get("title", ""), "qty": m["qty"], "net": m["net"], "vat": m["vat"],
                          "total": m["total"], "paid": m["total"] - due, "due": due})
    return lines


def make_bill(cid: str) -> tuple[str, dict, bool] | None:
    """The customer's open bill, made again only if what they owe changed (the old one is then
    "replaced"). Returns (id, bill, new), or None when nothing is owed."""
    db = firebase.db()
    c = db.document(f"customers/{cid}").get().to_dict()
    if c is None:
        raise HTTPException(404, "No such customer")
    paid: dict[str, int] = defaultdict(int)
    for _, p in studio._mine(cid, "payments"):
        paid[p.get("requestId")] += int(p.get("amount", 0))
    lines = bill_lines(studio._mine(cid, "requests"), dict(studio._mine(cid, "quotes")), paid)
    open_ = [(bid, b) for bid, b in studio._mine(cid, "bills") if b.get("state") == "open" and not b.get("deletedAt")]
    for bid, b in open_:
        if b.get("lines") == lines:
            return bid, b, False
    if not lines:
        return None
    counter, ref = db.document("counters/bills"), db.collection("bills").document()
    now = datetime.now(jobs.ISRAEL)
    bill = {
        "customerId": cid, "customerName": c.get("name", ""), "phone": c.get("phone", ""), "lang": c.get("lang", "he"),
        "token": secrets.token_urlsafe(16), "period": f"{now:%Y-%m}", "lines": lines,
        **{k: sum(line[k] for line in lines) for k in ("net", "vat", "total", "paid", "due")},
        "state": "open", "createdAt": firestore.SERVER_TIMESTAMP,
    }

    @firestore.transactional
    def write(t) -> int:
        n = int((counter.get(transaction=t).to_dict() or {}).get("next", 1001))
        t.set(counter, {"next": n + 1})
        for bid, _ in open_:
            t.update(db.document(f"bills/{bid}"), {"state": "replaced"})
        t.set(ref, {**bill, "number": n})
        return n

    bill["number"] = write(db.transaction())
    return ref.id, bill, True


@router.post("/studio/customers/{cid}/bill")
def bill_now(cid: str, _: studio.User) -> dict:
    made = make_bill(cid)
    if made is None:
        raise HTTPException(409, "Nothing to bill")
    bid, b, new = made
    return {"id": bid, "number": b["number"], "token": b["token"], "due": b["due"], "new": new}


def daily(today: date | None = None) -> int:
    """09:00: empty the trash of bills older than 30 days; on the billing day, bill every
    customer who owes (unless their monthly bill is off) and tell Alex how many are ready to send."""
    db, now = firebase.db(), datetime.now(timezone.utc)
    for d in db.collection("bills").where(filter=FieldFilter("deletedAt", "<", now - timedelta(days=TRASH_DAYS))).stream():
        d.reference.delete()
    today = today or datetime.now(jobs.ISRAEL).date()
    if today.day != int(settings().get("day", 1)):
        return 0
    names = []
    for d in db.collection("customers").stream():
        if (d.to_dict() or {}).get("billing") is False:
            continue
        if (made := make_bill(d.id)) and made[2]:
            names.append(made[1]["customerName"])
    if names:
        jobs.send_to(jobs.users(), "billing", f"🧾 {len(names)} דרישות תשלום מוכנות לשליחה", " · ".join(names)[:300], {"route": "/bills"})
    return len(names)


# --- the bill page -----------------------------------------------------------------

TEXT = {
    "he": {"dir": "rtl", "title": "דרישת תשלום", "no": "מס׳", "date": "תאריך", "to": "לכבוד", "item": "תיאור", "qty": "כמות",
           "net": "לפני מע״מ", "vat": "מע״מ", "total": "סה״כ", "paid": "שולם", "due": "לתשלום", "sum_net": "סה״כ לפני מע״מ",
           "sum_total": "סה״כ כולל מע״מ", "sum_paid": "שולם עד כה", "sum_due": "יתרה לתשלום", "how": "אפשרויות תשלום",
           "bank": "העברה בנקאית", "bank_no": "בנק", "branch": "סניף", "account": "מספר חשבון", "holder": "על שם",
           "ref": "נא לציין בהעברה: דרישה מס׳", "copy": "העתקה", "copied": "הועתק", "bit": "ביט", "paybox": "PayBox",
           "phone": "למספר", "pay_paybox": "תשלום ב-PayBox", "print": "הדפסה / שמירה כ-PDF", "thanks": "שולם, תודה רבה!",
           "receipt": "קבלה מס׳", "open_receipt": "לצפייה בקבלה", "after": "קבלה תישלח אליך לאחר התשלום.",
           "replaced": "הדרישה הזו עודכנה, והקישור לדרישה החדשה נשלח אליך.", "gone": "הקישור הזה לא פעיל."},
    "en": {"dir": "ltr", "title": "Payment request", "no": "No.", "date": "Date", "to": "To", "item": "Item", "qty": "Qty",
           "net": "Before VAT", "vat": "VAT", "total": "Total", "paid": "Paid", "due": "Due", "sum_net": "Total before VAT",
           "sum_total": "Total incl. VAT", "sum_paid": "Paid so far", "sum_due": "Balance due", "how": "How to pay",
           "bank": "Bank transfer", "bank_no": "Bank", "branch": "Branch", "account": "Account no.", "holder": "Account name",
           "ref": "Please write in the transfer: request no.", "copy": "Copy", "copied": "Copied", "bit": "Bit", "paybox": "PayBox",
           "phone": "To", "pay_paybox": "Pay with PayBox", "print": "Print / save as PDF", "thanks": "Paid, thank you!",
           "receipt": "Receipt no.", "open_receipt": "View the receipt", "after": "A receipt will be sent to you after payment.",
           "replaced": "This request was updated; the link to the new one was sent to you.", "gone": "This link is not active."},
}

STYLE = """
:root{--ink:#1d2430;--muted:#667085;--line:#e3e7ee;--soft:#f5f7fa;--accent:#2f6fde;--ok:#1f8a4c;--warn:#b54708;--bg:#eef1f5;--paper:#fff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 Heebo,system-ui,sans-serif}
.paper{max-width:760px;margin:24px auto;background:var(--paper);border:1px solid var(--line);border-radius:14px;padding:32px;position:relative;overflow:hidden}
header{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;border-bottom:3px solid var(--ink);padding-bottom:16px}
.biz{font-size:22px;font-weight:700}.muted{color:var(--muted)}h1{margin:0;font-size:24px}.meta{text-align:end}
.to{margin:20px 0;padding:12px 16px;background:var(--soft);border-radius:10px}
table{width:100%;border-collapse:collapse;margin-top:8px}th,td{padding:10px 8px;border-bottom:1px solid var(--line);text-align:start}
th{font-size:13px;color:var(--muted);font-weight:500}.num{text-align:end;white-space:nowrap;direction:ltr;unicode-bidi:isolate}
.sum{margin-top:16px;margin-inline-start:auto;width:min(100%,320px)}.sum div{display:flex;justify-content:space-between;padding:4px 0}
.sum .big{border-top:2px solid var(--ink);margin-top:6px;padding-top:10px;font-size:20px;font-weight:700}
h2{font-size:17px;margin:28px 0 10px}.ways{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.way{border:1px solid var(--line);border-radius:12px;padding:14px}.way b{display:block;margin-bottom:6px}
.row{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:3px 0}
button,.btn{font:inherit;border:1px solid var(--line);background:var(--paper);border-radius:8px;padding:4px 10px;cursor:pointer;color:var(--accent);text-decoration:none}
.btn.main{display:inline-block;background:var(--accent);color:#fff;border-color:var(--accent);padding:8px 14px;margin-top:6px}
.ref{margin-top:10px;font-size:13px}.note{margin-top:24px;font-size:13px}
.stamp{margin:20px 0;padding:14px;border:2px solid var(--ok);color:var(--ok);border-radius:12px;font-weight:700;text-align:center;font-size:18px}
.stamp a{display:block;font-size:14px;font-weight:500;color:var(--ok)}.banner{margin:20px 0;padding:12px;border-radius:10px;background:#fff4e5;color:var(--warn)}
.actions{margin-top:24px;text-align:center}
@media (max-width:560px){.paper{margin:0;border-radius:0;padding:20px 16px}.hide-s{display:none}}
@media print{body{background:#fff}.paper{border:0;margin:0}.actions,button{display:none}}
"""

SCRIPT = """document.querySelectorAll('[data-copy]').forEach(b=>b.onclick=()=>{navigator.clipboard.writeText(b.dataset.copy)
.then(()=>{const t=b.textContent;b.textContent=b.dataset.done;setTimeout(()=>b.textContent=t,1500)})})"""


def _sh(agorot: int) -> str:
    return f"₪{agorot // 100:,}.{agorot % 100:02d}"


def bill_html(b: dict, s: dict) -> str:
    """The bill as the client sees it: snapshot amounts, the studio's current payment details."""
    t = TEXT["en" if b.get("lang") == "en" else "he"]
    e = lambda v: html.escape(str(v or ""))  # noqa: E731
    vat = any(line["vat"] for line in b["lines"])
    paid = b.get("paid", 0) > 0
    at = b.get("createdAt")
    day = at.astimezone(jobs.ISRAEL).strftime("%d.%m.%Y") if isinstance(at, datetime) else ""

    def copy(v: str) -> str:
        return f'<span class="row"><span class="num">{e(v)}</span><button data-copy="{e(v)}" data-done="{t["copied"]}">{t["copy"]}</button></span>'

    rows = "".join(
        f'<tr><td>{e(line["title"])}</td><td class="num">{line["qty"]}</td>'
        + (f'<td class="num hide-s">{_sh(line["net"])}</td><td class="num hide-s">{_sh(line["vat"])}</td>' if vat else "")
        + f'<td class="num">{_sh(line["total"])}</td>' + (f'<td class="num">{_sh(line["paid"])}</td>' if paid else "")
        + f'<td class="num"><b>{_sh(line["due"])}</b></td></tr>'
        for line in b["lines"])
    head = (f'<th>{t["item"]}</th><th class="num">{t["qty"]}</th>'
            + (f'<th class="num hide-s">{t["net"]}</th><th class="num hide-s">{t["vat"]}</th>' if vat else "")
            + f'<th class="num">{t["total"]}</th>' + (f'<th class="num">{t["paid"]}</th>' if paid else "") + f'<th class="num">{t["due"]}</th>')
    sums = (f'<div><span>{t["sum_net"]}</span><span class="num">{_sh(b["net"])}</span></div>'
            f'<div><span>{t["vat"]}</span><span class="num">{_sh(b["vat"])}</span></div>' if vat else "")
    sums += f'<div><span>{t["sum_total"] if vat else t["total"]}</span><span class="num">{_sh(b["total"])}</span></div>'
    if paid:
        sums += f'<div><span>{t["sum_paid"]}</span><span class="num">−{_sh(b["paid"])}</span></div>'
    sums += f'<div class="big"><span>{t["sum_due"]}</span><span class="num">{_sh(b["due"])}</span></div>'

    ways = []
    if s.get("account"):
        ways.append(f'<div class="way"><b>🏦 {t["bank"]}</b>'
                    + (f'<div class="row"><span>{t["bank_no"]}</span>{copy(s.get("bankNumber", ""))}</div>' if s.get("bankNumber") else "")
                    + (f'<div class="muted">{e(s.get("bankName"))}</div>' if s.get("bankName") else "")
                    + (f'<div class="row"><span>{t["branch"]}</span>{copy(s.get("branch", ""))}</div>' if s.get("branch") else "")
                    + f'<div class="row"><span>{t["account"]}</span>{copy(s["account"])}</div>'
                    + (f'<div class="row"><span>{t["holder"]}</span><span>{e(s.get("accountName"))}</span></div>' if s.get("accountName") else "")
                    + f'<div class="ref muted">{t["ref"]} {b["number"]}</div></div>')
    if s.get("bitOn") and s.get("bitPhone"):
        ways.append(f'<div class="way"><b>📱 {t["bit"]}</b><div class="row"><span>{t["phone"]}</span>{copy(s["bitPhone"])}</div></div>')
    if s.get("payboxOn") and (p := str(s.get("payboxLink") or "")):
        ways.append(f'<div class="way"><b>💳 {t["paybox"]}</b>'
                    + (f'<a class="btn main" href="{e(p)}" target="_blank" rel="noopener">{t["pay_paybox"]}</a>' if p.startswith("https://")
                       else f'<div class="row"><span>{t["phone"]}</span>{copy(p)}</div>') + "</div>")

    if b.get("state") == "paid":
        r = b.get("receipt") or {}
        status = (f'<div class="stamp">✓ {t["thanks"]}' + (f'<br><span class="muted">{t["receipt"]} {e(r.get("number"))}</span>' if r.get("number") else "")
                  + (f'<a href="{e(r["url"])}" target="_blank" rel="noopener">{t["open_receipt"]}</a>' if str(r.get("url", "")).startswith("https://") else "")
                  + "</div>")
        pay = ""
    else:
        status = f'<div class="banner">{t["replaced"]}</div>' if b.get("state") == "replaced" else ""
        pay = (f'<h2>{t["how"]}</h2><div class="ways">{"".join(ways)}</div>' if ways else "") + f'<p class="note muted">{t["after"]}</p>'
    biz = e(s.get("businessName")) or "Print Studio"
    return f"""<!doctype html><html lang="{'en' if t['dir'] == 'ltr' else 'he'}" dir="{t['dir']}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>{t['title']} {b['number']} · {biz}</title><meta property="og:title" content="{t['title']} {b['number']} · {biz}">
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Heebo:wght@400;500;700&display=swap" rel="stylesheet">
<style>{STYLE}</style></head><body><main class="paper">
<header><div><div class="biz">{biz}</div><div class="muted">{e(s.get('businessId'))}</div><div class="muted">{e(s.get('contact'))}</div></div>
<div class="meta"><h1>{t['title']}</h1><div>{t['no']} <b>{b['number']}</b></div><div class="muted">{t['date']}: {day}</div></div></header>
<div class="to">{t['to']}: <b>{e(b.get('customerName'))}</b></div>{status}
<table><thead><tr>{head}</tr></thead><tbody>{rows}</tbody></table><div class="sum">{sums}</div>{pay}
<div class="actions"><button onclick="print()">{t['print']}</button></div></main><script>{SCRIPT}</script></body></html>"""


@router.get("/b/{token}", response_class=HTMLResponse)
def bill_page(token: str) -> HTMLResponse:
    headers = {"Cache-Control": "no-store", "X-Frame-Options": "DENY", "X-Robots-Tag": "noindex",
               "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; "
               "font-src https://fonts.gstatic.com"}
    found = firebase.db().collection("bills").where(filter=FieldFilter("token", "==", token)).limit(1).get() if 16 <= len(token) <= 64 else []
    b = found[0].to_dict() if found else None
    if not b or b.get("deletedAt"):
        return HTMLResponse(f'<!doctype html><meta charset="utf-8"><p style="font:16px system-ui;text-align:center;margin-top:20vh">'
                            f'{TEXT["he"]["gone"]} · {TEXT["en"]["gone"]}</p>', status_code=404, headers=headers)
    return HTMLResponse(bill_html(b, settings()), headers=headers)
