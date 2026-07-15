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
      │             └─ n8n "Reminder Scheduler" (every minute) sees it come due,
      │                POSTs to ntfy → phone rings, re-nags until acknowledged,
      │                one Telegram ping on first fire. Tapping Acknowledge hits
      │                the "Reminder Ack" webhook, which stops the nagging.
      │
      └─ calendar → google-workspace skill creates the event (Google fires it)
```

The alarm engine is two n8n workflows (`n8n-workflows/reminder-scheduler.json`,
`reminder-ack.json`) plus the self-hosted `ntfy` container. The skill lives in
`skills/reminders/` and is seeded into each primary agent by `scripts/hermes.sh`.

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
token (for n8n):
```bash
sudo docker compose exec ntfy ntfy user add --role=admin ghiath   # set a password
sudo docker compose exec ntfy ntfy token add ghiath               # prints tk_...
```
Put the token in `.env` and recreate n8n so it can publish:
```bash
# .env:  NTFY_TOKEN=tk_xxxxxxxx
sudo docker compose --profile prod up -d n8n
```

### 4. Install the ntfy app on your phone
- Play Store → **ntfy**. Settings → **Default server** = `https://ntfy.ghiath.id`,
  and add your username `ghiath` + password under Manage users / login.
- Subscribe to the topic **`ghiath-alarm`** (must match `NTFY_TOPIC` in `.env`).
- On that subscription, enable **"Override Do Not Disturb"** (and set a loud
  sound). This is what turns a push into an alarm you can't sleep through.

### 5. Import the n8n workflows
In n8n (https://n8n.ghiath.id): Import from File →
`n8n-workflows/reminder-scheduler.json` and `reminder-ack.json`. **Activate
both.** The scheduler needs to be active to poll; the ack webhook needs to be
active to receive the button tap.

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
