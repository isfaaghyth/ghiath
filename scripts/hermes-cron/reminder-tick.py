#!/usr/bin/env python3
"""Ghiath reminder tick — run by `hermes cron` in --no-agent mode, every minute.

Scans the vault's reminders/ folder, fires an ntfy phone alarm when a reminder
comes due, and re-nags (up to ackWindowMin) until the window elapses. Because it
runs under `hermes cron --no-agent --deliver telegram`, ANYTHING printed to
stdout is delivered to the Telegram chat — so we print a one-line ping on first
fire and stay silent otherwise. ntfy is published directly here; Telegram is just
stdout. No n8n, no LLM.

Install (on the host, once):
    cp scripts/hermes-cron/reminder-tick.py ~/.hermes/scripts/
    hermes cron create '1m' --no-agent --script reminder-tick.py \
        --deliver telegram --name ghiath-reminders

Config is read from <GHIATH_ROOT>/.env (GHIATH_ROOT defaults to ~/ghiath):
NTFY_TOPIC, NTFY_TOKEN, and PRIMARY_VAULT. ntfy is reached on the host loopback
(127.0.0.1:8080, the port the container publishes).
"""
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

GHIATH_ROOT = Path(os.environ.get("GHIATH_ROOT", str(Path.home() / "ghiath")))
NTFY_HOST = os.environ.get("NTFY_HOST_URL", "http://127.0.0.1:8080")


def log(msg: str) -> None:
    # stderr -> journald, never delivered to Telegram
    print(f"[reminder-tick] {msg}", file=sys.stderr)


def load_env(path: Path) -> dict:
    env = {}
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("'").strip('"')
    except FileNotFoundError:
        log(f"no .env at {path}")
    return env


def parse_fm(raw: str):
    if not raw.startswith("---\n"):
        return None
    end = raw.find("\n---", 4)
    if end == -1:
        return None
    block = raw[4:end]
    fm = {}
    for line in block.split("\n"):
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return {"fm": fm, "block": block, "rest_at": end + 4}


def set_field(block: str, key: str, val: str) -> str:
    lines = block.split("\n")
    for i, line in enumerate(lines):
        if line.startswith(key + ":"):
            lines[i] = f"{key}: {val}"
            return "\n".join(lines)
    lines.append(f"{key}: {val}")
    return "\n".join(lines)


def publish_ntfy(topic: str, token: str, title: str, message: str, priority: int) -> None:
    body = json.dumps({
        "topic": topic, "title": title, "message": message,
        "priority": priority, "tags": ["alarm_clock"],
    }).encode()
    req = urllib.request.Request(NTFY_HOST, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


def main() -> int:
    env = load_env(GHIATH_ROOT / ".env")
    topic = env.get("NTFY_TOPIC", "ghiath-alarm")
    token = env.get("NTFY_TOKEN", "")
    vault = env.get("PRIMARY_VAULT", "vault-work")
    reminders = GHIATH_ROOT / vault / "reminders"

    if not reminders.is_dir():
        return 0

    now = time.time()
    pings = []

    for fp in sorted(reminders.glob("*.md")):
        try:
            raw = fp.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        parsed = parse_fm(raw)
        if not parsed:
            continue
        fm = parsed["fm"]
        if fm.get("type") != "reminder":
            continue
        if fm.get("channel", "ntfy").lower() == "calendar":
            continue  # calendar fires natively

        status = fm.get("status", "scheduled").lower()
        when = fm.get("when", "")
        try:
            when_ts = datetime.fromisoformat(when).timestamp()
        except ValueError:
            continue

        ack_window = int(fm.get("ackWindowMin", "15") or 15)
        priority = max(1, min(5, int(fm.get("priority", "5") or 5)))
        title = fm.get("title", "Reminder")
        message = fm.get("message") or title

        do_send = first_fire = False
        new_status = None
        fired_at = fm.get("firedAt", "")

        if status == "scheduled" and now >= when_ts:
            do_send = first_fire = True
            new_status = "firing"
            fired_at = datetime.now(timezone.utc).isoformat()
        elif status == "firing":
            try:
                fired_ts = datetime.fromisoformat(fired_at).timestamp()
            except ValueError:
                fired_ts = now
            if now <= fired_ts + ack_window * 60:
                do_send = True  # keep nagging
            else:
                new_status = "missed"
        else:
            continue

        if do_send and token:
            try:
                publish_ntfy(topic, token, title, message, priority)
            except Exception as e:  # noqa: BLE001 - transient; retry next tick
                log(f"ntfy publish failed for {fp.name}: {e}")

        if first_fire:
            pings.append(f"⏰ {title}\n{message}")

        if new_status or first_fire:
            block = parsed["block"]
            if new_status:
                block = set_field(block, "status", new_status)
            if first_fire:
                block = set_field(block, "firedAt", fired_at)
            rest = raw[parsed["rest_at"]:]
            try:
                fp.write_text(f"---\n{block}\n---{rest}", encoding="utf-8")
            except OSError as e:
                log(f"status write failed for {fp.name}: {e}")

    # stdout -> Telegram (only when there's something to say)
    if pings:
        print("\n\n".join(pings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
