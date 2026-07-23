---
name: reminders
description: "Set a time-based reminder for the user. Urgent repeating phone alarm (ntfy), and/or a Google Calendar event. Ask which channel when unspecified."
version: 1.0.0
author: ghiath
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Reminders, Alarm, Calendar, ntfy, Productivity, Notifications]
---

# Reminders

Create a time-based reminder for the user. There are two delivery channels, and
they are for different needs:

- **Alarm (ntfy)** - an *urgent* push to the user's phone that breaks through Do
  Not Disturb and repeats every minute for up to `ackWindowMin` minutes. Use for
  things that must not be missed: "wake me", "alarm", "alert me", "ping me",
  "make sure I don't forget".
- **Calendar (Google Calendar)** - a normal calendar event with a reminder.
  Passive, shows up in the user's calendar, good for appointments and soft
  reminders. Use when the user says "calendar", "schedule", "put it on my
  calendar", "book", "event", "meeting".

## When to Use

Trigger on any request to be reminded of something at a time or after a delay:
"remind me to ...", "set an alarm for ...", "wake me at ...", "alert me in 20
minutes", "put a reminder / event on my calendar for ...", "don't let me forget
to ...".

## Choosing the channel - ASK IF UNSURE

1. If the user **explicitly names a channel** (alarm/notify/wake/ping ⇒ ntfy;
   calendar/schedule/event/book ⇒ Google Calendar), use that one. Do not ask.
2. If the request implies urgency but names no channel ("make sure I don't miss
   ..."), default to the **alarm**.
3. If it is a plain "remind me ..." with **no** urgency cue and **no** channel,
   **ask the user one short question** before doing anything:
   > Urgent phone **alarm** (rings repeatedly), or a **calendar event**? You can
   > also say **both**.
   Then proceed with their answer. "Both" means do the alarm AND the calendar
   steps.

Never guess silently when it is ambiguous - a missed urgent alarm and a
forgotten calendar entry fail in opposite ways.

## Resolve the time first

Compute an absolute local time (Asia/Jakarta) before writing anything:
- "in 20 minutes" / "in 2 hours" → now + delta.
- "at 5pm" → today 17:00 if still future, else tomorrow.
- "tomorrow 9am", "next Monday", etc. → resolve to a concrete date-time.
Confirm the resolved time back to the user in your reply ("Okay - alarm at 17:00
today.").

## Channel: Alarm (ntfy)

Write a reminder note into the vault. A hermes cron job (`reminder-tick.py`)
scans this folder every minute, fires the ntfy alarm when due, re-nags until the
acknowledge window elapses, and sends one Telegram ping on first fire. You do
NOT call ntfy yourself - just write the note.

Path: `<vault>/reminders/<id>.md`, where `<id>` is
`rmd-YYYYMMDD-HHMM-<short-slug>`. Use the absolute vault path you were given in
your role, with `reminders/` appended. Create that folder if it does not exist.

Contents:

```
---
type: reminder
status: scheduled
channel: ntfy
when: 2026-07-15T17:00:00+07:00
title: Call the plumber
message: Call the plumber about the kitchen leak
priority: 5
tags: [alarm]
ackWindowMin: 15
id: rmd-20260715-1700-plumber
from: <your-agent-name>
created: 2026-07-15
---
Optional longer context for the reminder goes in the body.
```

Field notes:
- `when` - ISO-8601 **with the +07:00 offset**. Do not omit the offset.
- `priority` - 1-5; use 5 for a real alarm, 4 for "important but not blaring".
- `ackWindowMin` - how many minutes to keep nagging before giving up (default
  15). Larger for "get me out of bed", smaller for a gentle nudge.
- `status` - always start at `scheduled`. The tick moves it to `firing`, then to
  `missed` once the window elapses.

After writing the note, tell the user it is set, at what time, and that it will
keep ringing on their phone for up to `ackWindowMin` minutes.

## Channel: Calendar (Google Calendar)

Delegate to the **google-workspace** skill - it owns Google auth and the
Calendar API. Create an event at the resolved time with a popup reminder. If
Google is not yet authorized, that skill will walk the user through a one-time
OAuth setup; hand off to it rather than trying to reach Google yourself.

Do NOT write a vault reminder note for a calendar-only request - Google fires
the notification natively, so the scheduler is not involved.

For **"both"**: create the calendar event via google-workspace AND write the
ntfy reminder note above.

## After creating

Give the user a one-line confirmation: channel(s), the resolved local time, and
for alarms how long it will keep ringing. If you asked and they picked a
channel, do not ask again for the same request.
