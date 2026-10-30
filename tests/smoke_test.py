#!/usr/bin/env python3
"""End-to-end smoke test for the LDAP + Postfix + Dovecot + Rspamd stack.

The stack must be running and its ports published on MAIL_HOST (default
127.0.0.1).  Requires only the Python standard library plus the docker CLI
(for a few configuration checks).

    python3 tests/smoke_test.py

Exit code 0 means every check passed.
"""

from __future__ import annotations

import imaplib
import os
import smtplib
import ssl
import subprocess
import sys
import time
import uuid
from email import message_from_bytes
from email.message import EmailMessage
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CTX = ssl._create_unverified_context()


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


ENV = {**load_env(ROOT / ".env"), **os.environ}

HOST = ENV.get("MAIL_HOST", "127.0.0.1")
DOMAIN = ENV.get("MAIL_DOMAIN", "example.com")
HOSTNAME = ENV.get("MAIL_HOSTNAME", f"mail.{DOMAIN}")
USER_PASSWORD = ENV.get("DEMO_USER_PASSWORD", "")
SMTP_PORT = int(ENV.get("MAIL_SMTP_PORT", "25"))
SUBMISSION_PORT = int(ENV.get("MAIL_SUBMISSION_PORT", "587"))
IMAP_PORT = int(ENV.get("MAIL_IMAP_PORT", "993"))

RUN_ID = f"smoke-{int(time.time())}-{uuid.uuid4().hex[:6]}"
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"PASS  {name}")
    else:
        print(f"FAIL  {name}" + (f"  [{detail}]" if detail else ""))
        FAILURES.append(name)


def compose(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=ROOT,
        input=stdin,
        text=True,
        capture_output=True,
        timeout=60,
    )


def make_message(mail_from: str, to: str, subject: str, body: str) -> bytes:
    msg = EmailMessage()
    msg["From"] = mail_from
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
    msg.set_content(body)
    return msg.as_bytes()


def smtp_attempt(
    mail_from: str,
    to: str,
    subject: str,
    body: str = "smoke test\n",
    auth: tuple[str, str] | None = None,
) -> tuple[str, int, bytes]:
    """Return (stage, smtp_code, response).  stage is mail/rcpt/data/auth."""
    payload = make_message(mail_from, to, subject, body)
    try:
        with smtplib.SMTP(HOST, SUBMISSION_PORT if auth else SMTP_PORT, timeout=30) as smtp:
            smtp.ehlo()
            if auth:
                smtp.starttls(context=CTX)
                smtp.ehlo()
                smtp.login(*auth)
            code, resp = smtp.mail(mail_from)
            if code != 250:
                return "mail", code, resp
            code, resp = smtp.rcpt(to)
            if code != 250:
                return "rcpt", code, resp
            try:
                code, resp = smtp.data(payload)
            except smtplib.SMTPDataError as exc:
                return "data", exc.smtp_code, exc.smtp_error
            return "data", code, resp
    except smtplib.SMTPAuthenticationError as exc:
        return "auth", exc.smtp_code, exc.smtp_error


def imap_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def imap_search_subject(user: str, mailbox: str, subject: str) -> bytes | None:
    with imaplib.IMAP4_SSL(HOST, IMAP_PORT, ssl_context=CTX) as imap:
        imap.login(user, USER_PASSWORD)
        typ, _ = imap.select(mailbox, readonly=True)
        if typ != "OK":
            return None
        typ, data = imap.search(None, "SUBJECT", imap_quote(subject))
        if typ != "OK" or not data or not data[0].split():
            return None
        typ, fetched = imap.fetch(data[0].split()[-1], "(BODY.PEEK[HEADER])")
        if typ != "OK":
            return None
        raw = b"".join(part[1] for part in fetched if isinstance(part, tuple))
        return raw or None


def wait_subject(user: str, subject: str, mailbox: str = "INBOX", timeout: float = 20.0) -> object | None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            raw = imap_search_subject(user, mailbox, subject)
        except (imaplib.IMAP4.error, OSError):
            raw = None
        if raw:
            return message_from_bytes(raw)
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.5)


def cleanup() -> None:
    for user in ("jdoe@example.com", "taro@example.com"):
        try:
            with imaplib.IMAP4_SSL(HOST, IMAP_PORT, ssl_context=CTX) as imap:
                imap.login(user, USER_PASSWORD)
                for mailbox in ("INBOX", "Junk"):
                    typ, _ = imap.select(mailbox)
                    if typ != "OK":
                        continue
                    typ, data = imap.search(None, "SUBJECT", imap_quote(RUN_ID))
                    if typ != "OK" or not data or not data[0].split():
                        continue
                    imap.store(b",".join(data[0].split()), "+FLAGS", "(\\Deleted)")
                    imap.expunge()
        except (imaplib.IMAP4.error, OSError):
            pass


def main() -> int:
    if not USER_PASSWORD:
        print("DEMO_USER_PASSWORD is missing from .env", file=sys.stderr)
        return 2

    print(f"Smoke run {RUN_ID} against {HOST} ({DOMAIN})")
    print("-" * 72)

    # ------------------------------------------------------------------
    # Static configuration checks
    # ------------------------------------------------------------------
    master = compose("exec", "-T", "postfix", "postconf", "-M")
    chrooted = []
    if master.returncode == 0:
        for line in master.stdout.splitlines():
            if not line or line[0].isspace():
                continue
            parts = line.split()
            if len(parts) >= 5 and parts[4] != "n":
                chrooted.append(parts[0])
    check("postfix is reachable and all master.cf services use chroot=n", master.returncode == 0 and not chrooted,
          f"chrooted services: {chrooted}")

    userdb = compose("exec", "-T", "dovecot", "doveadm", "user", "john.doe@example.com")
    check("Dovecot maps the alias to /data/maildir/jdoe",
          userdb.returncode == 0 and "/data/maildir/jdoe" in userdb.stdout,
          userdb.stderr.strip())

    maildir_root = compose("exec", "-T", "dovecot", "sh", "-c", "test -d /data/maildir")
    check("/data/maildir exists", maildir_root.returncode == 0)

    cert = compose("exec", "-T", "postfix", "openssl", "x509", "-in",
                   "/etc/ssl/mail/fullchain.pem", "-noout", "-subject")
    check("TLS certificate is installed and matches MAIL_HOSTNAME",
          cert.returncode == 0 and HOSTNAME in cert.stdout,
          cert.stdout.strip())

    # ------------------------------------------------------------------
    # Delivery: primary address and alias
    # ------------------------------------------------------------------
    direct_subject = f"{RUN_ID} direct"
    alias_subject = f"{RUN_ID} alias"
    stage, code, _ = smtp_attempt("outside@example.net", f"jdoe@{DOMAIN}", direct_subject)
    check("SMTP accepts mail to the primary address", stage == "data" and code == 250)
    stage, code, _ = smtp_attempt("outside@example.net", f"john.doe@{DOMAIN}", alias_subject)
    check("SMTP accepts mail to an alias address", stage == "data" and code == 250)

    direct_header = wait_subject("jdoe@example.com", direct_subject)
    alias_header = wait_subject("jdoe@example.com", alias_subject)
    check("primary address is delivered to INBOX", direct_header is not None)
    check("alias address is delivered to the same mailbox", alias_header is not None)
    mailbox_path = compose("exec", "-T", "dovecot", "sh", "-c", "test -d /data/maildir/jdoe")
    check("mail is stored under /data/maildir/jdoe", mailbox_path.returncode == 0)

    # ------------------------------------------------------------------
    # Forwarding
    # ------------------------------------------------------------------
    forward_subject = f"{RUN_ID} forward"
    stage, code, _ = smtp_attempt("outside@example.net", f"asmith@{DOMAIN}", forward_subject)
    check("SMTP accepts mail for a forwarding account", stage == "data" and code == 250)
    check("mailForward sends mail to the target mailbox",
          wait_subject("jdoe@example.com", forward_subject) is not None)
    source_mailbox = compose("exec", "-T", "dovecot", "sh", "-c", "test ! -d /data/maildir/asmith")
    check("forwarding does not create a local mailbox for the source account", source_mailbox.returncode == 0)

    # ------------------------------------------------------------------
    # Rejections
    # ------------------------------------------------------------------
    stage, code, _ = smtp_attempt("outside@example.net", f"nobody@{DOMAIN}", f"{RUN_ID} unknown")
    check("unknown recipient is rejected with 550", stage == "rcpt" and code == 550, f"{stage} {code}")

    # ------------------------------------------------------------------
    # Authenticated submission: sender ownership, canonical envelope, DKIM
    # ------------------------------------------------------------------
    auth_subject = f"{RUN_ID} auth"
    stage, code, _ = smtp_attempt(
        f"j.doe@{DOMAIN}", f"taro@{DOMAIN}", auth_subject,
        auth=("jdoe@example.com", USER_PASSWORD),
    )
    check("authenticated submission is accepted", stage == "data" and code == 250, f"{stage} {code}")

    auth_header = wait_subject("taro@example.com", auth_subject)
    check("submitted mail is delivered", auth_header is not None)
    if auth_header is not None:
        return_path = (auth_header.get("Return-Path") or "").strip()
        from_header = (auth_header.get("From") or "").strip()
        check("envelope sender is canonicalized to <uid>@domain",
              return_path == f"<jdoe@{DOMAIN}>", return_path)
        check("From: header is preserved", from_header == f"j.doe@{DOMAIN}", from_header)
        check("outbound mail is DKIM-signed", auth_header.get("DKIM-Signature") is not None)

    stage, code, _ = smtp_attempt(
        f"alice@{DOMAIN}", f"taro@{DOMAIN}", f"{RUN_ID} spoof",
        auth=("jdoe@example.com", USER_PASSWORD),
    )
    check("sender outside the user's mail attribute is rejected",
          stage == "rcpt" and code in (550, 553), f"{stage} {code}")

    # ------------------------------------------------------------------
    # Spam
    # ------------------------------------------------------------------
    gtube = (
        "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X\n"
    )
    stage, code, _ = smtp_attempt(
        "spammer@example.net", f"jdoe@{DOMAIN}", f"{RUN_ID} gtube", body=gtube,
    )
    check("GTUBE is rejected by Rspamd at SMTP time",
          stage == "data" and code in (550, 554), f"{stage} {code}")

    # ------------------------------------------------------------------
    # IMAP alias login
    # ------------------------------------------------------------------
    try:
        with imaplib.IMAP4_SSL(HOST, IMAP_PORT, ssl_context=CTX) as imap:
            imap.login("john.doe@example.com", USER_PASSWORD)
            typ, _ = imap.select("INBOX", readonly=True)
            typ, data = imap.search(None, "SUBJECT", imap_quote(direct_subject))
            check("IMAP login with an alias sees the same INBOX",
                  typ == "OK" and bool(data and data[0].split()))
    except (imaplib.IMAP4.error, OSError) as exc:
        check("IMAP login with an alias sees the same INBOX", False, str(exc))

    print("-" * 72)
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    finally:
        cleanup()
