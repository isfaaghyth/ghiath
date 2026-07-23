# Ghiath Reminders - urgent phone alarms + calendar

Ask an agent (over Telegram) to remind you of something. It picks a channel:

- **Alarm (ntfy)** - an urgent push to your phone that breaks through Do Not
  Disturb, repeats every minute, and keeps nagging until the acknowledge window
  elapses. For things you must not miss.
- **Calendar (Google Calendar)** - a normal calendar event with a reminder, via
  the built-in `google-workspace` skill. For appointments and soft nudges.

If your request does not name a channel, the agent asks which you want.

Both agents can set reminders. The work agent writes into the work vault and
rings the work topic; the home agent writes into the home vault and rings the
household topic. That way a household alarm can go to both phones while a work
alarm only goes to yours.

## How it works

```
you (Telegram) -> agent runs the "reminders" skill
      |
      |- alarm  -> writes <vault>/reminders/<id>.md  (status: scheduled)
      |             |
      |             +- hermes cron `ghiath-reminders` (every minute) sees it come
      |                due, POSTs to ntfy, the phone rings and re-nags until
      |                ackWindowMin elapses, one Telegram ping on first fire.
      |
      +- calendar -> google-workspace skill creates the event (Google fires it)
```

The alarm engine is a **hermes cron job** running
`scripts/hermes-cron/reminder-tick.py` (no LLM, no n8n) plus the self-hosted
`ntfy` container. The skill lives in `skills/reminders/` and is seeded into both
agents by `scripts/hermes.sh`.

Tap-to-acknowledge (stopping the nag early) is not wired in this version. The
alarm self-limits after `ackWindowMin`. It can be re-added later via
`hermes webhook`.

## One-time setup

### 1. DNS

Point `ntfy.ghiath.id` at the VPS (same as your other subdomains):

```
ntfy.ghiath.id.  A  <vps-public-ip>
```

### 2. Bring up ntfy on the VPS

```bash
cd ghiath && git pull
sudo docker compose --profile prod up -d ntfy caddy
```

Caddy gets the TLS cert on first request.
Check: `curl https://ntfy.ghiath.id/v1/health` returns `{"healthy":true}`.

### 3. The two topics

Each agent publishes to its own predefined topic:

| Topic | Set by | Rings on | `.env` variable |
| --- | --- | --- | --- |
| `ghiath-work-alarm` | the work agent | your phone only | `NTFY_TOPIC` |
| `ghiath-home-alarm` | the home agent | both phones | `NTFY_HOME_TOPIC` |

Keep them distinct.
Pointing both at one topic would send every work reminder to your partner's
phone as well, and the per-topic access control below would stop meaning
anything. `reminder-tick.py` logs a warning to stderr if it sees them equal.

### 4. Create the ntfy accounts

ntfy runs deny-all, so nothing works until you create accounts.
There are three, doing different jobs:

```bash
# a) The publisher. Its token is what reminder-tick.py authenticates with.
#    It is not used on any phone.
sudo docker compose exec ntfy ntfy user add --role=admin ghiath   # set a password
sudo docker compose exec ntfy ntfy token add ghiath               # prints tk_...

# b) Your phone: both topics.
sudo docker compose exec ntfy ntfy user add isfa
sudo docker compose exec ntfy ntfy access isfa ghiath-work-alarm rw
sudo docker compose exec ntfy ntfy access isfa ghiath-home-alarm rw

# c) Your partner's phone: the household topic and nothing else. This grant is
#    the thing that keeps work alarms off that device.
sudo docker compose exec ntfy ntfy user add rumah
sudo docker compose exec ntfy ntfy access rumah ghiath-home-alarm rw
```

Verify with `sudo docker compose exec ntfy ntfy access`.
The `rumah` account must show `ghiath-home-alarm` and nothing else.

Put the publish token and the topics in `.env`, which is where the tick script
reads them from:

```
NTFY_TOKEN=tk_xxxxxxxx
NTFY_TOPIC=ghiath-work-alarm
NTFY_HOME_TOPIC=ghiath-home-alarm
```

### 5. Install the ntfy app on the phones

Do this on both phones, using that phone's own account.

1. Install **ntfy** from the Play Store or App Store.
2. **Settings, Default server**: `https://ntfy.ghiath.id`.
   It must be the public HTTPS domain, not a loopback address.
3. **Settings, Manage users, Add user**: the server URL plus the username and
   password for this phone (`isfa` on yours, `rumah` on your partner's).
4. Subscribe to the topics that account may read:
   - your phone: `ghiath-work-alarm` and `ghiath-home-alarm`
   - your partner's phone: `ghiath-home-alarm` only
5. On **each** subscription, open its settings, enable
   **"Override Do Not Disturb"**, and pick a loud sound.
   This is what turns a push into an alarm you cannot sleep through.
   It is a per-subscription setting, so do it twice on your phone.

An authentication error on a subscription means that account has no `access`
grant for that topic. Re-run the matching `ntfy access` command.

### 6. Register the hermes cron job

```bash
# Copy the tick scripts to ~/.hermes/scripts/ (safe and non-destructive).
cd ~/ghiath && make seed-cron        # == ./scripts/seed-cron.sh

# Use a cron EXPRESSION for recurring. A bare duration like '1m' means "once,
# 1 minute from now" - it fires a single time and stops. '* * * * *' runs every
# minute.
hermes cron create '* * * * *' --no-agent --script reminder-tick.py \
    --deliver telegram --name ghiath-reminders

hermes cron status      # confirm the scheduler is running
hermes cron list        # the job should show as RECURRING, not "once in ..."
```

Register it under the profile whose Telegram chat should receive the ping.
`reminder-tick.py` scans both vaults regardless of which profile runs it, so one
job covers everything; register a second one under the other profile only if you
want the pings delivered to both chats.

`--deliver telegram` sends the script's **stdout** to the chat. The tick prints
only a first-fire line, so the chat stays quiet otherwise.

### 7. (Optional) Calendar

The calendar channel uses the built-in `google-workspace` skill. The first time
you ask an agent for a calendar reminder, it walks you through a one-time Google
OAuth setup. No extra infrastructure here.

## Test it

Ask an agent over Telegram: **"remind me to drink water in 2 minutes as an
alarm."** Within about two minutes the phone should ring with a persistent alarm,
plus a Telegram ping.

Manual smoke test of just ntfy, with no agent involved. Run it once per topic
and confirm each one rings on the phones you expect, and only those:

```bash
curl -H "Authorization: Bearer $NTFY_TOKEN" \
  -d '{"topic":"ghiath-work-alarm","title":"Work test","message":"hi","priority":5,"tags":["alarm_clock"]}' \
  https://ntfy.ghiath.id

curl -H "Authorization: Bearer $NTFY_TOKEN" \
  -d '{"topic":"ghiath-home-alarm","title":"Home test","message":"hi","priority":5,"tags":["alarm_clock"]}' \
  https://ntfy.ghiath.id
```

The work test must NOT appear on your partner's phone. If it does, that account
has a grant it should not; check `ntfy access`.

To watch the tick itself:

```bash
GHIATH_ROOT=~/ghiath python3 ~/.hermes/scripts/reminder-tick.py
```

It prints nothing when there is nothing due, which is the healthy case.

## Reminder note format

Written by the skill into `<vault>/reminders/<id>.md`:

```
---
type: reminder
status: scheduled        # scheduled -> firing -> missed
channel: ntfy            # ntfy (calendar reminders are not written here)
when: 2026-07-15T17:00:00+07:00
title: Call the plumber
message: Call the plumber about the leak
priority: 5              # 1-5; 5 = full alarm
tags: [alarm]
ackWindowMin: 15         # keep nagging up to N minutes, then mark missed
id: rmd-20260715-1700-plumber
---
```

## History

Reminders and agent handoffs used to run as n8n workflows
(`reminder-scheduler.json`, `reminder-ack.json`, `vault-watch.json`,
`vault-notify.json`).
They now run as a `hermes cron` job driving a plain script, which is
deterministic, costs no tokens, needs no extra container, and avoids the
unavailable Local File Trigger node.

The handoff workflows are gone entirely: with a single agent per side there is
nothing to hand off. If you imported any of those workflows into n8n previously,
deactivate them so nothing runs twice.
