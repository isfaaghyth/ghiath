#!/usr/bin/env python3
"""Ghiath vault tick — run by `hermes cron` in --no-agent mode, every minute.

Two jobs, both replacing n8n workflows:

1. Handoffs (was vault-watch): scan each agent's folder for a new "open" note and
   POST it to that agent's gateway on the host, so the owning agent picks it up.
2. Result notify (was vault-notify): when a delegated agent writes a finished
   "result" note, print a summary to stdout — which `hermes cron --deliver
   telegram` sends to the chat. The assistant's own results are skipped (you
   already saw those in the chat).

Deduped by content hash in a state file, so nothing fires or notifies twice.
Handoff calls are silent side effects; only result summaries go to stdout, so
Telegram stays quiet unless there is something worth telling you.

Install (on the host, once):
    cp scripts/hermes-cron/vault-tick.py ~/.hermes/scripts/
    hermes cron create '1m' --no-agent --script vault-tick.py \
        --deliver telegram --name ghiath-vault

Config from <GHIATH_ROOT>/.env: GHIATH_ROUTES (agent -> {port, model, folder}),
PRIMARY_VAULT. Agent gateways are reached on the host loopback.
"""
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

GHIATH_ROOT = Path(os.environ.get("GHIATH_ROOT", str(Path.home() / "ghiath")))
STATE_FILE = Path.home() / ".hermes" / "ghiath-vault-state.json"
GATEWAY_HOST = os.environ.get("GHIATH_GATEWAY_HOST", "http://127.0.0.1")

DEFAULT_ROUTES = {
    "assistant":  {"port": 8642, "model": "deepseek/deepseek-v2-flash", "folder": "scratchpads", "default": True},
    "engineer":   {"port": 8643, "model": "anthropic/claude-opus-4-8", "folder": "projects"},
    "researcher": {"port": 8644, "model": "z-ai/glm-4.6", "folder": "memory"},
}


def log(msg: str) -> None:
    print(f"[vault-tick] {msg}", file=sys.stderr)


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


def field(block: str, key: str) -> str:
    for line in block.split("\n"):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip().lower()
    return ""


def fm_block(raw: str):
    if not raw.startswith("---\n"):
        return None
    end = raw.find("\n---", 4)
    return raw[4:end] if end != -1 else None


def call_gateway(port: int, model: str, prompt: str) -> None:
    url = f"{GATEWAY_HOST}:{port}/v1/chat/completions"
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    # Fire-and-forget: a long agent run must not block the tick. A short timeout
    # is enough to hand the request off; the agent keeps working after.
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
    except Exception as e:  # noqa: BLE001
        log(f"gateway {port} call failed: {e}")
        raise


def main() -> int:
    env = load_env(GHIATH_ROOT / ".env")
    vault_dir = GHIATH_ROOT / env.get("PRIMARY_VAULT", "vault-work")

    routes = DEFAULT_ROUTES
    try:
        if env.get("GHIATH_ROUTES"):
            routes = json.loads(env["GHIATH_ROUTES"])
    except json.JSONDecodeError:
        log("GHIATH_ROUTES not valid JSON; using defaults")

    agent_by_folder = {c["folder"]: a for a, c in routes.items() if c.get("folder")}
    assistant = next((a for a, c in routes.items() if c.get("default")), None)

    try:
        state = json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        state = {}
    fired = state.setdefault("fired", {})
    notified = state.setdefault("notified", {})

    seen = set()
    pings = []

    for folder, agent in agent_by_folder.items():
        fdir = vault_dir / folder
        if not fdir.is_dir():
            continue
        cfg = routes[agent]
        for fp in sorted(fdir.glob("*.md")):
            key = f"{folder}/{fp.name}"
            seen.add(key)
            try:
                raw = fp.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            block = fm_block(raw)
            status = field(block, "status") if block else "open"
            digest = hashlib.sha256(raw.encode()).hexdigest()

            # 1. Handoff: a new "open" note -> trigger the owning agent.
            if status == "open" and fired.get(key) != digest:
                prompt = (
                    f"An open note was placed in your folder: {key}\n"
                    'Read it, set its status to "doing", act on it, then set its status '
                    'to "done". Record your result as a note with type "result", status '
                    '"done", owner yourself. If the task should move to another agent, '
                    "drop an \"open\" note in that agent's folder with owner set to them."
                )
                try:
                    call_gateway(int(cfg["port"]), cfg["model"], prompt)
                    fired[key] = digest
                except Exception:  # noqa: BLE001 - leave unfired so next tick retries
                    pass

            # 2. Notify: a finished result from a non-assistant agent -> Telegram.
            if block and status == "done" and field(block, "type") == "result":
                owner = field(block, "owner")
                if owner and owner != assistant and notified.get(key) != digest:
                    body = raw[raw.find("\n---", 4) + 4:].strip()
                    room = 3500
                    snippet = body if len(body) <= room else body[:room] + "\n\n[...truncated, full note in the vault]"
                    pings.append(f"✅ {owner} finished a task\n{key}\n\n{snippet}")
                    notified[key] = digest

    # Forget vanished notes so state cannot grow forever.
    for m in (fired, notified):
        for k in list(m):
            if k not in seen:
                del m[k]

    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state))
    except OSError as e:
        log(f"state write failed: {e}")

    if pings:
        print("\n\n———\n\n".join(pings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
