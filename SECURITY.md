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
- **Network:** two things only. The weather (Open-Meteo, with MET Norway as a backup), sent nothing but your city's coordinates. And the update check: once a day (or when you click Check for Updates) Brim asks GitHub's public API for the latest release of this repository, sending no ID and nothing about you. You can turn the automatic check off in Settings › About. No analytics, no account, no other connections.
- **Updates:** Brim installs an update only when you click Update. It downloads the DMG attached to the GitHub release, checks that the app inside is Brim, newer, intact (`codesign --verify --deep --strict`) and signed with the same certificate as the copy you're running, and refuses it otherwise. Then it swaps the app in and opens it again.
- **Live Activities:** with the same Full Disk Access, Brim reads the list of Live Activities macOS keeps (`group.com.apple.liveactivitiesd`) and the iPhone app icons WidgetKit keeps (`group.com.apple.chronod`), read-only, on your Mac. Nothing from them leaves the Mac. You can turn this off in Settings › Live Activities.
- **Microphone and Speech Recognition:** only while the teleprompter's Follow My Voice is on, using on-device recognition only. Nothing is recorded or sent. The waveform during calls is decorative and doesn't use the microphone.
- **Lock screen player:** while the Mac is locked, Brim only shows the music player (play, pause, skip), the full-screen artwork and your Live Activities. Notifications, the shelf, Shortcuts and everything else stay hidden until you unlock. Brim never types or handles your password.
- **Camera:** only while the mirror is open in the panel.
- **Input Monitoring:** only to talk to Logitech keyboards and mice over HID++ for their battery and backlight.
- **Helper:** the Now Playing helper (Vendor/mediaremote-adapter, BSD licence) runs inside Brim to read what's playing.

## How releases are checked

- Every change to the code is scanned by GitHub's CodeQL, and the results are public in the Security tab.
- OpenSSF Scorecard rates the repository's security practices every week (the badge in the README).
- Releases are immutable: once one is published, its DMG and its tag can't be swapped or moved, and GitHub signs a record of them.
