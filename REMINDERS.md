# Ghiath Reminders — urgent phone alarms + calendar

Ask an agent (over Telegram) to remind you of something. It picks a channel:

- **Alarm (ntfy)** — an urgent push to your Android phone that breaks through Do
  Not Disturb, repeats every minute, and keeps nagging until you tap
  **Acknowledge**. For things you must not miss.
- **Calendar (Google Calendar)** — a normal calendar event with a reminder, via
  the existing `google-workspace` skill. For appointments and soft nudges.

If your request doesn't name a channel, the agent asks which you want.

## How it works

```
you (Telegram) → assistant agent runs the "reminders" skill
      │
      ├─ alarm  → writes vault-work/reminders/<id>.md  (status: scheduled)
      │             │
      │             └─ hermes cron `ghiath-reminders` (every minute) sees it come
      │                due, POSTs to ntfy → phone rings, re-nags until the
      │                ackWindowMin elapses, one Telegram ping on first fire.
      │
      └─ calendar → google-workspace skill creates the event (Google fires it)
```

The alarm engine is a **hermes cron job** running `scripts/hermes-cron/reminder-tick.py`
(no LLM, no n8n) plus the self-hosted `ntfy` container. The skill lives in
`skills/reminders/` and is seeded into each primary agent by `scripts/hermes.sh`.

> **Note — this replaced the n8n workflows.** Reminders and vault handoffs used to
> run as n8n workflows (`reminder-scheduler.json`, `reminder-ack.json`,
> `vault-watch.json`, `vault-notify.json`). They now run as `hermes cron` jobs
> driving plain scripts, which is deterministic, costs no tokens, needs no extra
> container, and avoids the unavailable Local File Trigger node. The n8n JSONs are
> kept for reference; deactivate them in n8n if you migrated. Tap-to-acknowledge
> (stopping the nag early) is not wired in this version — the alarm self-limits
> after `ackWindowMin`; it can be re-added later via `hermes webhook`.

## One-time setup

### 1. DNS
Point `ntfy.ghiath.id` at the VPS (same as your other subdomains):
```
ntfy.ghiath.id.  A  43.159.42.70
```

### 2. Bring up ntfy on the VPS
```bash
cd ghiath && git pull
sudo docker compose --profile prod up -d ntfy caddy
```
Caddy gets the TLS cert on first request. Check: `curl https://ntfy.ghiath.id/v1/health` → `{"healthy":true}`.

### 3. Create the ntfy user + publish token
ntfy runs deny-all, so nothing works until you make a user (for the phone) and a
token (for the reminder tick to publish with):
```bash
sudo docker compose exec ntfy ntfy user add --role=admin ghiath   # set a password
sudo docker compose exec ntfy ntfy token add ghiath               # prints tk_...
```
Put the token in `.env` (the tick script reads it from there):
```bash
# .env:  NTFY_TOKEN=tk_xxxxxxxx
```

### 4. Install the ntfy app on your phone
- Play Store → **ntfy**. Settings → **Default server** = `https://ntfy.ghiath.id`,
  and add your username `ghiath` + password under Manage users / login.
- Subscribe to the topic **`ghiath-alarm`** (must match `NTFY_TOPIC` in `.env`).
- On that subscription, enable **"Override Do Not Disturb"** (and set a loud
  sound). This is what turns a push into an alarm you can't sleep through.

### 5. Register the hermes cron jobs
Seed the tick scripts and register the jobs (both run every minute, no LLM):
```bash
cd ~/ghiath && ./scripts/hermes.sh        # copies tick scripts to ~/.hermes/scripts/
# or copy by hand: cp scripts/hermes-cron/*.py ~/.hermes/scripts/

hermes cron create '1m' --no-agent --script reminder-tick.py \
    --deliver telegram --name ghiath-reminders
hermes cron create '1m' --no-agent --script vault-tick.py \
    --deliver telegram --name ghiath-vault

hermes cron status      # confirm the scheduler is running
hermes cron list        # see both jobs
```
`ghiath-vault` also replaces the old vault-watch/vault-notify workflows (agent
handoffs + pushing finished results to Telegram). If you previously imported the
n8n reminder/vault workflows, deactivate them so nothing runs twice.

### 6. (Optional) Calendar
The calendar channel uses the built-in `google-workspace` skill. The first time
you ask an agent for a calendar reminder, it walks you through a one-time Google
OAuth setup. No extra infra here.

## Test it

Ask the assistant over Telegram: **"remind me to drink water in 2 minutes as an
alarm."** Within ~2 minutes your phone should ring with a persistent alarm and an
Acknowledge button, plus a Telegram ping. Tapping Acknowledge stops it.

Manual smoke test of just ntfy (no agent):
```bash
curl -H "Authorization: Bearer $NTFY_TOKEN" \
  -d '{"topic":"ghiath-alarm","title":"Test","message":"hi","priority":5,"tags":["alarm_clock"]}' \
  https://ntfy.ghiath.id
```

## Reminder note format

Written by the skill into `vault-work/reminders/<id>.md`:
```
---
type: reminder
status: scheduled        # scheduled → firing → acknowledged | missed
channel: ntfy            # ntfy (calendar reminders are not written here)
when: 2026-07-15T17:00:00+07:00
title: Call the plumber
message: Call the plumber about the leak
priority: 5              # 1–5; 5 = full alarm
tags: [alarm]
ackWindowMin: 15         # keep nagging up to N minutes, then mark missed
id: rmd-20260715-1700-plumber
---
```
