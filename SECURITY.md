# Security policy

## Supported versions

Security fixes go into the latest release. Please update to it before reporting.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability** and describe the problem, the steps to reproduce it, and what an attacker could do with it.

You'll get a reply within a few days. Once it's fixed, a new release goes out and you'll be credited in its notes if you'd like.

## What Brim can reach

So you know what to look at:

- **Notifications:** with Full Disk Access, Brim reads macOS's own Notification Center database, read-only, on your Mac. Nothing from it leaves the Mac.
- **Network:** only the weather (Open-Meteo, with MET Norway as a backup), sent nothing but your city's coordinates. No analytics, no account, no other connections.
- **Microphone and Speech Recognition:** only while the teleprompter's Follow My Voice is on, using on-device recognition only. Nothing is recorded or sent.
- **Camera:** only while the mirror is open in the panel.
- **Input Monitoring:** only to talk to Logitech keyboards and mice over HID++ for their battery and backlight.
- **Helper:** the Now Playing helper (Vendor/mediaremote-adapter, BSD licence) runs inside Brim to read what's playing.
