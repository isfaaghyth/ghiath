#!/usr/bin/env python3
"""Ghiath vault tick — run by `hermes cron` in --no-agent mode, every minute.

Two jobs, both replacing n8n workflows:

1. Handoffs (was vault-watch): scan each agent's folder for a new "open" note and
   spawn that agent one-shot (`hermes -p <agent> -z ...`) to work it. hermes
   agents have NO HTTP endpoint — the gateway is only a Telegram/Discord poller —
   so a CLI one-shot, run detached, is how you invoke an agent from a script.
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
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

GHIATH_ROOT = Path(os.environ.get("GHIATH_ROOT", str(Path.home() / "ghiath")))
STATE_FILE = Path.home() / ".hermes" / "ghiath-vault-state.json"
SPAWN_LOG = Path.home() / ".hermes" / "ghiath-handoff.log"

# The hermes binary. A profile is invoked one-shot with `hermes -p <name> -z
# <prompt>` (the ~/.local/bin/<name> shims are just `exec hermes -p <name>`).
# HERMES_BIN overrides it, mainly for testing.
HERMES = (
    os.environ.get("HERMES_BIN")
    or shutil.which("hermes")
    or str(Path.home() / ".local" / "bin" / "hermes")
)

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


def spawn_agent(agent: str, prompt: str) -> None:
    """Launch `hermes -p <agent> -z <prompt>` detached and return immediately.

    hermes agents have no HTTP endpoint; the way to invoke one from a script is
    a one-shot CLI run, which executes the full agent loop (with tools) and
    exits. An extensive task can take minutes, so we must NOT wait on it — the
    tick has to finish within its minute. The agent works in the background and
    writes its result note when done; output is appended to SPAWN_LOG for
    debugging. start_new_session detaches it from this process group so it keeps
    running after the tick exits.
    """
    SPAWN_LOG.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat()
    with open(SPAWN_LOG, "a") as logf:
        logf.write(f"\n===== {stamp} spawn {agent} =====\n{prompt}\n----- output -----\n")
        logf.flush()
        subprocess.Popen(
            [HERMES, "-p", agent, "-z", prompt],
            stdout=logf, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )


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

            # 1. Handoff: a new "open" note -> spawn the owning agent one-shot.
            if status == "open" and fired.get(key) != digest:
                abs_path = str(fp)
                prompt = (
                    f"An open task note is waiting for you at: {abs_path}\n"
                    'Read it, set its status to "doing", do the work, then set its status '
                    'to "done". Record your result as a note with type "result", status '
                    '"done", owner yourself, in the same folder. If the task should move to '
                    "another agent, drop an \"open\" note in that agent's folder with owner "
                    "set to them."
                )
                try:
                    spawn_agent(agent, prompt)
                    fired[key] = digest
                except Exception as e:  # noqa: BLE001 - leave unfired so next tick retries
                    log(f"spawn {agent} for {key} failed: {e}")

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
