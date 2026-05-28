from __future__ import annotations

import argparse
import html
import json
import os
import re
import smtplib
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path


DEFAULT_RESALE_URL = "https://events.humanitix.com/2026-pikes-peak-international-hill-climb/us/resale"
DEFAULT_TARGET_TERMS = (
    "Devils Playground",
    "Devil's Playground",
    "Devils Playground Carpool",
    "Devils Playground Single Motorcycle",
    "Devils Playground Double Motorcycle",
)
DEFAULT_NEGATIVE_TERMS = (
    "no tickets available",
    "no resale tickets available",
    "there are no tickets available",
    "currently no tickets",
    "nothing available",
)


@dataclass(frozen=True)
class Config:
    resale_url: str
    target_terms: tuple[str, ...]
    negative_terms: tuple[str, ...]
    poll_seconds: int
    state_file: Path
    smtp_host: str
    smtp_port: int
    smtp_username: str
    smtp_password: str
    smtp_enable_ssl: bool
    email_from: str
    email_to: str


def load_dotenv(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def csv_env(name: str, default: tuple[str, ...]) -> tuple[str, ...]:
    value = os.getenv(name)
    if not value:
        return default
    return tuple(item.strip() for item in value.split(",") if item.strip())


def read_config() -> Config:
    load_dotenv(Path(".env"))
    return Config(
        resale_url=os.getenv("RESALE_URL", DEFAULT_RESALE_URL),
        target_terms=csv_env("TARGET_TERMS", DEFAULT_TARGET_TERMS),
        negative_terms=csv_env("NEGATIVE_TERMS", DEFAULT_NEGATIVE_TERMS),
        poll_seconds=max(5, int(os.getenv("POLL_SECONDS", "30"))),
        state_file=Path(os.getenv("STATE_FILE", ".pikes_resale_state.json")),
        smtp_host=os.getenv("SMTP_HOST", ""),
        smtp_port=int(os.getenv("SMTP_PORT", "587")),
        smtp_username=os.getenv("SMTP_USERNAME", ""),
        smtp_password=os.getenv("SMTP_PASSWORD", ""),
        smtp_enable_ssl=os.getenv("SMTP_ENABLE_SSL", "true").lower() != "false",
        email_from=os.getenv("EMAIL_FROM", ""),
        email_to=os.getenv("EMAIL_TO", ""),
    )


def fetch_page(url: str, timeout_seconds: int = 20) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/125.0 Safari/537.36"
            ),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="replace")


def page_to_text(page: str) -> str:
    page = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", page)
    page = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", page)
    page = re.sub(r"(?s)<[^>]+>", " ", page)
    page = html.unescape(page)
    page = re.sub(r"\s+", " ", page)
    return page.strip()


def excerpt_around(text: str, start: int, length: int = 280) -> str:
    half = length // 2
    left = max(0, start - half)
    right = min(len(text), start + half)
    excerpt = text[left:right].strip()
    if left > 0:
        excerpt = "..." + excerpt
    if right < len(text):
        excerpt = excerpt + "..."
    return excerpt


def find_matches(page: str, target_terms: tuple[str, ...], negative_terms: tuple[str, ...]) -> list[str]:
    text = page_to_text(page)
    lowered = text.lower()

    if any(term.lower() in lowered for term in negative_terms):
        return []

    matches: list[str] = []
    for term in target_terms:
        for hit in re.finditer(re.escape(term.lower()), lowered):
            excerpt = excerpt_around(text, hit.start())
            excerpt_lower = excerpt.lower()
            if "sold out" in excerpt_lower and "resale" not in excerpt_lower:
                continue
            if excerpt not in matches:
                matches.append(excerpt)

    return matches


def load_previous_signature(state_file: Path) -> str:
    if not state_file.exists():
        return ""
    try:
        return json.loads(state_file.read_text(encoding="utf-8")).get("signature", "")
    except (OSError, json.JSONDecodeError):
        return ""


def save_signature(state_file: Path, signature: str) -> None:
    payload = {
        "signature": signature,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    state_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def send_email(config: Config, subject: str, body: str) -> None:
    required = {
        "SMTP_HOST": config.smtp_host,
        "SMTP_USERNAME": config.smtp_username,
        "SMTP_PASSWORD": config.smtp_password,
        "EMAIL_FROM": config.email_from,
        "EMAIL_TO": config.email_to,
    }
    missing = [key for key, value in required.items() if not value]
    if missing:
        raise RuntimeError(f"Missing required email settings: {', '.join(missing)}")

    message = EmailMessage()
    message["From"] = config.email_from
    message["To"] = config.email_to
    message["Subject"] = subject
    message.set_content(body)

    with smtplib.SMTP(config.smtp_host, config.smtp_port, timeout=20) as smtp:
        if config.smtp_enable_ssl:
            smtp.starttls()
        smtp.login(config.smtp_username, config.smtp_password)
        smtp.send_message(message)


def build_alert(url: str, matches: list[str]) -> tuple[str, str]:
    detail = matches[0][:500] if matches else "A matching resale listing appeared."
    return (
        "Pikes Peak Devils Playground resale alert",
        "Pikes Peak alert: Devils Playground resale tickets may be available now.\n"
        f"{url}\n\n"
        f"Match: {detail}",
    )


def check_once(config: Config, *, notify: bool) -> bool:
    page = fetch_page(config.resale_url)
    matches = find_matches(page, config.target_terms, config.negative_terms)
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")

    if not matches:
        print(f"[{now}] No matching Devils Playground resale listing found.")
        save_signature(config.state_file, "")
        return False

    signature = "\n".join(matches)
    previous_signature = load_previous_signature(config.state_file)
    if signature == previous_signature:
        print(f"[{now}] Matching listing is still present; alert already sent.")
        return True

    subject, message = build_alert(config.resale_url, matches)
    if notify:
        send_email(config, subject, message)
        print(f"[{now}] Matching listing found. Email sent.")
    else:
        print(f"[{now}] Matching listing found. Email disabled for this run.")
        print(message)

    save_signature(config.state_file, signature)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Watch Humanitix resale tickets and email when Devils Playground appears.")
    parser.add_argument("--once", action="store_true", help="Check once, then exit.")
    parser.add_argument("--no-email", action="store_true", help="Do not send email; print the alert instead.")
    parser.add_argument("--test-email", action="store_true", help="Send a test email using the configured SMTP settings, then exit.")
    args = parser.parse_args()

    config = read_config()

    if args.test_email:
        send_email(
            config,
            "Pikes Peak watcher test",
            "Pikes Peak watcher test: email delivery is configured correctly.",
        )
        print("Test email sent.")
        return 0

    notify = not args.no_email
    while True:
        try:
            check_once(config, notify=notify)
        except (RuntimeError, urllib.error.URLError, TimeoutError) as exc:
            now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
            print(f"[{now}] Check failed: {exc}", file=sys.stderr)

        if args.once:
            return 0
        time.sleep(config.poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
