# Roadmap

What's planned for Brim. Ideas and requests are welcome: [open a feature request](https://github.com/martinsrepos/Brim/issues/new?template=feature_request.yml).

## Done in 1.4.5

- Calls in the pill show the app and the time together ("FaceTime • 2:14"), and the waveform on the right now moves with your voice.

## Done in 1.4.4

- The teleprompter section keeps the panel open while you fetch a script from Finder, so a dragged file lands in the teleprompter instead of on the shelf.
- Pasting into the script editor works again, from any app.
- LaunchOS and other full-screen launchers tuck the island away, so their search field isn't hidden behind it.
- On the lock screen, the artwork fills the screen only for Apple Music and Spotify; from a browser it stays in the card.

## Done in 1.4.3

- AirPods follow what you do instead of a timer. Opening the case next to the Mac shows Nearby with the battery, putting them in shows Connected, and then nothing until they disconnect. Putting them back in the open case shows Disconnected only. Moving them between your iPhone and Mac shows Connected or Disconnected once, as it happens, with no more missing or late banners.

## Done in 1.4.2

- AirPods are quieter. The case card shows only at the moment the lid opens (not every few minutes while you wear them), each device gets at most one banner every ten minutes, and opening the case and putting them in shows one card instead of two.
- A notification an app keeps re-sending unchanged shows once. During a FaceTime call on your iPhone, the Mac's "move this call" notification no longer pops up every few seconds.

## Next major update

- **Report a Bug button.** In Settings › About and the menu bar menu. It opens the bug report form on GitHub with your Mac, macOS, Brim version and style already filled in, makes the diagnostics report and shows it in Finder, ready to drag into the form. Nothing is sent until you press Submit on GitHub.

## Done in 1.2

- Cleared notifications stay cleared after a restart or an update, and only the last six hours come back at startup.
- Timers, stopwatches, Focus rounds and breaks show their symbol inside the pill's ring.
- The page dots in the circle sit inside the progress ring, so the artwork and the time look centered.

## Done in 1.3

- Live Activities from your iPhone and other apps in the island, with live match scores, banners for goals and important updates, real app icons, and a card per activity in the panel.
- A subtle progress line along the music pill.
- Reminders stay in view until you tick them off or hide them, even when they're late.
- The panel steps back for Spotlight, and the header never runs past the panel.
- MacBook brightness keys show Brim's brightness banner, and the widest panel is no longer cut off in the notch style.

## Done in 1.4

- Truer Liquid Glass: Apple's clear glass, with the black inside it, so the edges keep their lens effect from clear to solid black.
- A music player card on the lock screen. Click the artwork and it fills the screen.
- AirPods Pro, AirPods 4 and AirPods Max turn in 3D in their banners: the earbuds, the open case, and the closed case.
- Text Size in Appearance; the pill, banners and panel grow with it.
- A wider panel gives the extra room to the notifications.
- A small waveform on calls (decorative; Brim doesn't use the microphone for it).
- Live Activities with progress (scans, cleanups, downloads) show a filling ring and a check mark when done.
- Deliveries and rides read properly: the app's title, status, short text and progress bar, in the app's colour, also on the lock screen.

## Done in 1.4.1

- Text Size is Default, Large or Extra Large. With larger text the player's artwork, controls and spacing grow in step, and the panel grows only as much as it needs, so there's no empty space under the player.
- The code is scanned by GitHub's CodeQL on every change, the repository has an OpenSSF Scorecard, releases are immutable, and every DMG comes with a signature you can check.

## Next

- **3D clips for Beats**, rendered like the AirPods ones.

## Watching

- **Logitech devices after sleep.** Some devices may not reconnect to Brim until the next wake, so their battery banners could be missing for a while. Looking into it if it shows up again in reports.
