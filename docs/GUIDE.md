# Brim: the full guide

Everything about Brim in detail: every feature, every setting and permission, how it works under the hood, and its limits. For the short version, see the [README](../README.md).

## Everything it does

> **Brim used to be called Halo.** The first time Brim starts it takes over Halo's settings and teleprompter scripts, and `./build.sh install` removes the old Halo.app. macOS ties permissions to the app, so Brim asks for them again (Full Disk Access, Input Monitoring and the rest; the Permissions pane in Settings shows what's left). If you made a signing certificate for Halo, keep using it: `BRIM_SIGN_IDENTITY="Halo Developer" ./build.sh install`.

- **Notifications** from every app (Messages, WhatsApp, Mail, Slack...), mirrored from Notification Center, with the real app icon. Website notifications from Safari show Safari's icon and the site's name. Click one to open the app.
- **System events**: charger plugged in or unplugged, low battery, Bluetooth accessories connecting (headphones, speakers, keyboards, mice, controllers; one banner per change). Your Watch, iPhone, iPad and Macs are left out: they link up in the background all the time.
- **AirPods battery, like iPhone**: when your AirPods connect, or when you open their case right next to the Mac, a card shows each AirPod and the case as battery rings (green, red at 20% and below, a bolt while charging).
- **Volume**: change the volume (any keyboard's volume keys, the menu bar, Control Center, AirPods) and a banner shows a bar and the speakers or headphones it applies to (or "Muted"), updating live while you press or drag. The icon is Apple's speaker symbol with all three waves, greyed out until they light up: one from the first step, two from halfway, three at full volume. The speaker never moves; each wave fades in or out as you go up or down. Muting crossfades to the slashed speaker. Switching to other speakers shows nothing; only volume changes do. macOS has no setting to hide its own volume pop-up, so you'll see both. Outputs whose volume is set on the device itself (many HDMI monitors) don't report one, so there's no banner for those.
- **Monitor brightness**: for an external monitor, a sun button in the panel's header slides out a brightness slider. Two shortcuts step it in sixteenths, like an Apple display: **⌃⌥⌘↑** brighter and **⌃⌥⌘↓** dimmer, each showing a banner like the keyboard backlight's (the monitor's name, "Level 8", the bar, and a filled sun, small up to halfway and big from level 8). They're meant for two buttons on the MX Creative Console keypad: in Logi Options+, select the keypad, pick a button, choose a keyboard shortcut action and press the shortcut; you can give the button a sun icon there too. Links work as well: `brim://brightness?step=up`, `?step=down` or `?set=40`. Brim uses macOS's own brightness control when it can, the same one as Control Center's Display slider, so the two always agree and Brim picks up changes you make there. When macOS can't dim the monitor, Brim talks to it over the cable instead (DDC/CI; tested: Samsung U28R55 over USB-C to DisplayPort on an M4 Pro Mac mini). Settings shows which one is in use. If neither works, the button simply doesn't appear. Nothing is sent to the monitor while the Mac is locked or its displays are asleep. No permission needed.
- **Teleprompter**: your script in the island, right under the camera, for video calls and recordings. In the panel, the text button next to the mirror opens the teleprompter section: drop a script on it (or drag a file onto the island, which opens it), click **Browse…**, start a **New** one, or pick one of your recent scripts. Text, Markdown, RTF, Word and PDF files work; Brim keeps its own copy and never changes the original. The script opens in a small editor window with Bold, Highlight (select words, or switch it on and type), a Pause marker, Find and Replace, the word count and reading time, and the language you'll read in. **Start Prompter** (⌘Return) turns the island into the prompter: the line you're on sits a third of the way down, nearest the lens, read lines fade out above it and the next ones fade in below; bold stays bold and highlights show in yellow. **Follow My Voice** (on by default) scrolls as you speak and waits when you stop: Apple's speech recognition, on the Mac only (nothing is recorded or sent anywhere), in the script's language, English or Italian. It matches the last few words you said to the script near where you are, so a misheard word or a skipped phrase doesn't lose your place, and the text glides along word by word. Four orange bars in the corner move with your voice while it listens. macOS asks for the Microphone and Speech Recognition the first time; if either is off, or the language can't be recognized offline on this Mac, a note says so (with a button to the right Settings page) and it falls back to the steady scroll. On calls, wear headphones so the other person's voice doesn't move your script. The waveform button switches to **Steady Speed**: a 3, 2, 1 countdown, then a steady pace in words a minute. The time left shows in the top corner, a progress line along the bottom. Hover it for the controls (edit, back, play/pause, forward, slower and faster, close); the scroll wheel or trackpad moves the script by hand. It eases into motion when it starts, and jumps glide. **Start Prompter** closes the editor; the prompter's edit button opens it again, and starting again from there keeps your place. Shortcuts, also for MX Creative Console buttons: **⌃⌥⌘P** start (the last script), pause and resume, **⌃⌥⌘=** faster, **⌃⌥⌘−** slower, **⌃⌥⌘]** forward half a line, **⌃⌥⌘[** back half a line (give these to the dial's two directions in Logi Options+), **⌃⌥⌘.** close. While it's open, banners wait (the last few show when you close it), hovering doesn't open the panel, the display stays on, and the island asks macOS to keep it out of screen shares and recordings (see Limitations). Settings > Teleprompter sets the text size, width, height, speed, countdown, mirrored text and screen-sharing hiding. 
- **File Shelf**: drag any file onto the island and the panel opens; drop it and it stays on the shelf (at the top of the panel's right column) until you take it out. Drag a file out to wherever you need it, click to open it, or send the whole shelf (or one file, from its menu) with AirDrop. Scripts on the shelf can go straight to the teleprompter. It keeps where the files are, not copies, up to 12, and remembers them across restarts; files you've moved or deleted drop off. No permission needed.
- **Shortcuts buttons**: up to three of your own Apple Shortcuts as buttons in the panel's header (Settings > General). Each one is a card in Settings: pick a shortcut and the card takes a color and a glyph guessed from its name ("Desk Lights" gets the light bulb, in English or Italian). Click the glyph to choose another from 64 in eight groups, or another color; the card's … button runs it, swaps the shortcut or removes it. In the panel each button wears its card's color. A banner says when one is done, or why it didn't run. No permission needed.
- **Charge alert (MacBooks)**: a banner when the battery charges to the level you choose (80, 85, 90, 95% or fully charged), so you can unplug in time (Settings > Devices > Battery).
- **Microphone mute**: when the microphone is muted or turned back on, a banner says so, with a crossed-out mic. It follows the microphone itself, so it works whatever mutes it: the keyboard's Mute Microphone key (through Logi Options+), Control Center, or Brim's own call button. Mute buttons inside Zoom or FaceTime only mute the call, so they don't show. Turn off Options+'s own mic pop-up to avoid seeing it twice.
- **Logitech battery**: every Logitech device paired over Bluetooth that reports its battery over HID++ (an MX Keys keyboard, an MX Master mouse, the MX Dialpad...) gets warnings at 20%, 10% and 5% (once each), plus a banner when it starts charging and when it's fully charged, with the battery ring. The keyboard reports changes as they happen; the others are checked once a minute while you're using the Mac, so a charging banner can take up to a minute. Those devices are left out of the general accessory battery check, so nothing warns twice. Devices on a Bolt or Unifying receiver, or wired only (like the Creative Console keypad), aren't covered.
- **Keyboard backlight, for Logitech MX Keys**: change the backlight on an MX Keys keyboard (tested on the MX Keys Mini over Bluetooth) and a banner shows the level as a bar that fills step by step, plus **Off** and **Auto**. Its icon has four looks: dots when off, short rays from level 1, longer from level 4, longest at level 7. It updates live while you keep pressing the keys and goes away by itself after 2 seconds, like the macOS brightness HUD. The keyboard handles its backlight in firmware, so Brim asks it directly over Logitech's HID++ protocol (feature 0x1982). It works with Logi Options+ running; turn off Options+'s own backlight pop-up so the two don't overlap. Brim needs Input Monitoring for this (see below). Changes the light sensor makes in Auto mode don't show a banner, only yours do.
- **Any app's media, browsers included**: YouTube in Safari or Chrome, SoundCloud, Spotify, Music... through macOS's Now Playing system (see "Now Playing helper" below). Music, Spotify, Podcasts and TV show the real artwork; browsers and other apps show their app icon.
- **Upcoming meetings**: 15 minutes before a meeting the island counts down (in the circle when music is playing); the panel has a **Join** button for Zoom, Meet, Teams, Webex and FaceTime links. Calendar's own alerts arrive as normal notifications. Works with every calendar added to the Mac.
- **Reminders**: a reminder with a time shows 15 minutes before it's due, with the Reminders icon, until you tick it off (there's a **Done** button in the panel). Reminders' own alert comes through as a normal notification.
- **Camera and microphone dots**: green when an app uses the camera, orange for the microphone, inside the island at the top center, where they stand out against the black. On a MacBook's notch they sit inside the black, just right of the camera; when nothing else is showing, the notch grows a little to make room for them. If the island is set to hide when idle, it still appears while either is on.
- **Timers, stopwatches and Focus**, as many at once as you like: start from the panel's timer button (its options slide out of it: 5, 10 or 15 minutes, Focus, Stopwatch, or Custom, where you scroll the hours, minutes and seconds with the mouse wheel, trackpad or a Logitech wheel, then tick to start; it remembers your last custom time), the menu bar (Timer), or Shortcuts. Each new one appears at the top of the panel's list. In the island, every timer and stopwatch is its own activity: the one ending soonest comes first, and clicking the circle steps through the rest along with music and everything else. Focus is a Pomodoro: 25 minutes, then a 5 minute break (shown with a walking figure). When the break ends, a "Break Over" banner stays up for 10 seconds; click it (or its row in the panel later) to start the next Focus round. Nothing repeats on its own, so rounds never run while you're away. A timer shows a ring and the time left; a stopwatch shows ticking dashes like a clock face.
- **Sounds**: Settings > Live Activities picks the tone for when a timer ends (Glass by default) and Settings > Notifications, if you like, a tone for each new notification banner, from the Mac's own alert sounds (plus any in ~/Library/Sounds). macOS still plays an app's own sound, so turn that off in System Settings > Notifications for apps where you'd rather hear Brim's.
- **Downloads and AirDrop**: a progress ring while a file downloads (Safari, Chrome, Firefox) or arrives over AirDrop, then a "Download Complete" or "AirDrop Received" banner; click it in the list to show the file in Finder. The AirDrop request itself (Accept / Decline) is macOS's own notification, mirrored like any other.
- **Two things at once, like iPhone**: what's playing always keeps the pill. Anything else going on at the same time (a timer, a meeting, a reminder, a download) pops out of the pill's right end into a small circle: the island stays in place and keeps its width, its right side pulls back with a liquid stretch, and the circle snaps free. When that activity ends, or a notification or the panel opens, the circle melts back in. With no music, the most important activity takes the pill and the next one takes the circle. In the notch style the notch grows an extra wing on the right instead, past a thin divider, holding the same glyph (the timer's ring, the meeting countdown...); it grows to the right only, so the camera stays covered. Click the circle or the wing to swap which activity is in front.
  - The circle shows a short time inside a ring: "1h", "12m", then "9:59" for a timer or stopwatch, minutes for a meeting (a video icon when it starts and has a link), the Reminders icon for a reminder, and for music (when you've swapped it into the circle) round artwork with the song's progress around the edge.
  - **Click the circle** to swap: its activity moves into the pill and the pill's goes into the circle, music included. With three or more, each click brings the next one forward (dots at the circle's bottom show how many). Hovering the circle doesn't open the panel; hover the pill for that.
- **Song changes swipe**: on Next the new title and artwork come in from the left, moving right; after Previous from the right, moving left (the same on screen whatever the Mac's language), in the pill and in the panel. Click the song or its artwork in the panel to open the app playing it.
- **Play and pause**: the pill shows six bars in the shape of Apple's waveform symbol, in the song's color, bouncing while it plays; paused, they shrink into a row of round dots and rise again when it plays, the title dims, play and pause morph into each other. After 5 minutes paused the song leaves the pill (the panel still has it) and plays back in when you resume.
- **Calls**: while a calling app is on a call (FaceTime, including iPhone calls answered on the Mac, Zoom, Teams, Webex, Skype, GoTo), the island shows a green phone and the call's length (it takes the pill; click the circle to swap). The panel has a **Mute** button that switches off the Mac's microphone; Brim switches it back on when the call ends. Click the call to bring its window forward. Brim knows which app, not who's calling, and can't answer or hang up. Messaging apps and browsers (WhatsApp, Telegram, Meet in Chrome...) aren't shown as calls, since they also record voice notes and dictation; they just light the orange or green dot.
- **Clock and weather when idle**: the time, quietly, in the empty island, with the clock on the left and the temperature and the sky's SF Symbol (in color, like the Weather app) on the right. Search for your city in Settings ("Milan", "Milano" or "Milan, Italy") and pick it from the list, or press Return for the first match; Brim needs no location access. City search uses Apple's geocoder (as in Maps), with Open-Meteo's place search as a backup; the weather comes from Open-Meteo, with the Norwegian Meteorological Institute (MET Norway) as a backup. Both are free and only receive the city's coordinates. Settings > Live Activities > Now shows the last update, or the exact error. The weather refreshes every 15 minutes. While the clock or weather shows, the idle pill (and the lock pill) is 200 points wide whatever width you set, so they never get squeezed.
- **Keep Awake**: keeps the display from sleeping for 1 hour, 4 hours or until you switch it off (menu bar > Keep Awake, or the cup button in the panel, whose options slide out of it). While it's on, a small orange cup pops into the left of the idle island, the clock slides to the middle, and the weather stacks its symbol on top of a smaller temperature to fit beside it.
- **Panel width**: 540 to 760 points. The notifications column grows a little with the panel, and the header makes room when a menu slides out, so nothing gets cut off.
- **Low battery for your keyboard, mouse and trackpad**: a banner at 20%, 10% and 5%, once each, like iPhone.
- **Respect Focus**: when a Focus is on, notifications from apps it silences go into the list without a banner; apps the Focus allows still pop up. (Read from macOS's own Focus files, which are undocumented; changes show in the Notification Log.)
- **Full-screen apps and games**: the island tucks away above the screen. Touch the top edge with the pointer and it drops down; move away and it slides back up. Notifications still drop down for a few seconds. Games that raise their window above normal apps or take over the display (like League of Legends in Full Screen mode) would otherwise cover the island, so while one does, Brim lifts the island just above it and drops it back afterwards. If a game still hides it, its Borderless (or Windowed Full Screen) mode is a normal window and always works. While League of Legends is full screen (the client or a match, which runs as its own app inside League of Legends.app), the island doesn't tuck away at all: it stays in view and shows banners as usual, but hovering does nothing, so moving the camera along the top edge never opens the panel and clicks there go to the game. When League isn't full screen, it behaves like any other app.
- **Media controls** for Spotify and Apple Music: artwork, progress bar you can drag to seek, previous / play-pause / next.
- **Live activity** while a song is loaded: artwork, the song title with the artist under it in a smaller size, and an equalizer (flat when paused).
- **Hover to expand**: the player (with shuffle, repeat, and a favourite star for Apple Music) plus a scrollable list of recent notifications. The **Mirror** button in the panel's header shows your camera as a square mirror in the player's place (the panel grows to fit it), to check how you look before a call. Real cameras come before virtual ones like OBS; with several, a button switches between them. The camera runs only while the mirror is open. Several notifications from one app stack up, iPhone style; click a stack and the cards roll down out from behind the top one (Show Less rolls them back up). Swipe a notification sideways with two fingers to clear it, or hover it and click the small x on its icon (it leaves Brim's list; macOS's Notification Center keeps its own). Click a banner to open what it's about (the app that sent it, like WhatsApp or Mail, a downloaded file in Finder, or the next Focus round for "Break Over"); the banner goes away. A banner showing in the island can be flicked away like on iPhone, with a mouse by clicking it and dragging up a little, or with a two-finger swipe up on a trackpad: it goes into the list and the next one (if any) comes in. Hovering a banner opens the panel a moment later than the pill does, to leave time for the swipe.
- **Lock screen**: the island stays visible when your Mac is locked, with a lock in the middle (in the left wing beside a notch), like iPhone. When you unlock, the lock swings open, then the island settles. Notifications still arrive while locked, but only show the app, not the message.
- **One look, from black to clear**: the island is dark Liquid Glass, pill and panel alike, in light mode too. Settings > **Transparency** goes all the way from solid black (exactly like Dynamic Island) through smoky black glass to clear glass. The split pill and circle are one piece of glass. On the lock screen the island is always black. When you unlock, once the lock screen has gone the black fades to your transparency while the lock opens, then the lock fades and the island's content appears.

On a Mac without a notch (Mac mini, external display) Brim is a real **Dynamic Island**: a black capsule floating at the top center that grows into rounded shapes. On a MacBook with a notch, it hugs the notch instead. Brim reads the real size of the camera housing from macOS and never draws under it: it keeps a few points clear on each side, every activity stays in its own wing (a time too long for its wing shrinks rather than sliding under the camera), the song title is left out of the compact state, and the expanded panel puts its buttons on a row below the camera instead of beside it. How far the wings reach out is up to you (Settings > Appearance > Notch Wings).

## Feedback and contributing

- **Ideas and feature requests:** open a [feature request](https://github.com/martinsrepos/Brim/issues/new?template=feature_request.yml). Say what you'd use it for; that helps more than how it should look.
- **Bugs:** open a [bug report](https://github.com/martinsrepos/Brim/issues/new?template=bug_report.yml) with your Mac, your macOS version and what you expected. For notifications that don't show, attach the Notification Log (menu bar icon > Notification Log); for anything slow or odd, the Diagnostics report (Settings > About). Both stay on your Mac until you share them.
- **Code:** pull requests are welcome. For anything bigger than a fix, open an issue first so we can agree on the approach. See [CONTRIBUTING.md](../CONTRIBUTING.md).
- **Security:** please don't open a public issue; see [SECURITY.md](../SECURITY.md).

## Build and install

You only need Apple's Command Line Tools, not full Xcode.

```bash
xcode-select --install        # once, if you don't have the tools yet
cd Brim
chmod +x build.sh
./build.sh install            # builds, copies to /Applications and launches
```

Requires macOS 14 Sonoma or newer. Liquid Glass needs macOS 26 Tahoe and its Command Line Tools; on older systems the glass uses a frosted blur instead.

### Making a DMG to share

```bash
BRIM_SIGN_IDENTITY="Halo Developer" ./build.sh dmg
```

This builds Brim for Apple silicon and Intel Macs in one app and packs it into `build/Brim-1.0.dmg` (the version comes from `Info.plist`), with Brim on the left and an Applications shortcut on the right. The first time, macOS may ask to let Terminal control Finder: that's only for arranging the window, and the DMG works either way. Upload the DMG to a GitHub release.

Sign every release with the same certificate. macOS remembers the permissions people give Brim by its signature, so a new version signed the same way keeps them.

**Opening it on another Mac.** Without an Apple Developer account Brim can't be notarized, so the first time someone opens it macOS says it can't check it for malware. They open it once from System Settings › Privacy & Security, where there's an **Open Anyway** button for Brim, and after that it opens normally. Put that line in the release notes. With a Developer account ($99 a year) you'd sign with a Developer ID certificate and notarize with `xcrun notarytool`, and the warning goes away.

## Turning on notifications (one time)

macOS keeps your notifications in a protected database. To let Brim read it:

1. On first launch Brim opens **System Settings > Privacy & Security > Full Disk Access** for you.
2. Click **+**, choose **Brim** from Applications, and switch it on.
3. Within a couple of seconds the notch says "Notifications connected". No restart needed.

Brim only reads that database to display notifications. Nothing leaves your Mac.

**Tip:** macOS will still show its own banner in the top-right corner. If you'd rather see notifications only in the notch, set an app's alert style to **None** in System Settings > Notifications. Its notifications should still reach Notification Center, and therefore Brim.

### Keep permissions across rebuilds

macOS remembers permissions per app signature. The default build uses a throwaway signature, so after each rebuild you'd have to switch Full Disk Access off and on again. To avoid that, create a free signing certificate once:

1. Open **Keychain Access** > menu **Keychain Access > Certificate Assistant > Create a Certificate…**
2. Name: `Brim Developer`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**. Create.
3. Build with it:

```bash
BRIM_SIGN_IDENTITY="Brim Developer" ./build.sh install
```

## Other permissions

| Prompt | Why |
| --- | --- |
| "Brim wants to control Spotify / Music" | Now-playing info and the playback buttons. |
| Bluetooth | The device connected / disconnected banners and the AirPods battery card. |
| Calendars | Upcoming meetings and their Join links. |
| Reminders | Reminders due soon, and ticking them off. |
| Camera | The Mirror, only while it's open. |
| Input Monitoring | The Logitech banners (keyboard backlight, batteries). A Bluetooth keyboard is a single device to macOS, so talking to its Logitech channel needs this permission. Brim only looks at the keyboard's HID++ messages; your typing passes through unread. macOS asks once a Logitech keyboard shows up; if you said no, Settings > Devices has a button that opens the right page. |
| Microphone and Speech Recognition | The teleprompter's Follow My Voice. Recognition runs on the Mac only; nothing is recorded or sent anywhere. macOS asks the first time you start the prompter with it on. |

## Settings

Brim menu bar icon > **Settings…** (or Cmd + , while the menu is open). It's laid out like System Settings, with panes in a sidebar (General first, About last, the rest in alphabetical order), each with its own glyph (each glyph is centered on what it actually paints, not on its box, so none of them lean left):

- **General**: which displays show the island, Show on Lock Screen, Hide When Idle (the floating island), Launch at Login, and your Shortcuts buttons as cards.
- **Appearance**: the shape (Automatic: a notch on a MacBook's notch and a floating island on other displays; or always Notch, hanging from the top edge; or always Floating Island, below the top edge and, on a MacBook, just under the notch), Transparency (from solid black to clear glass), the pill's width, height and distance from the top (screens without a notch; on a MacBook it matches the notch), how wide the notch's wings are, the expanded panel's width and height (turn on **Keep Open While Adjusting** to watch it change), and Restore Defaults.
- **Devices**: the battery's charge alert (MacBooks), monitor brightness (the monitor found, whether macOS or DDC/CI controls it, and the shortcuts), and Logitech devices, with the ones Brim found or a button to allow Input Monitoring.
- **Live Activities**: clock, weather and its city, camera and microphone dots, meetings, reminders, calls, downloads and AirDrop, and the tone when a timer ends.
- **Notifications**: Respect Focus and an optional banner sound.
- **Permissions**: every permission Brim uses (Full Disk Access, Calendars, Reminders, Camera, Microphone, Speech Recognition, Input Monitoring, Bluetooth, and control of Music and Spotify), what each is for, and whether it's allowed, not allowed or not asked yet, with a button to the right page of System Settings when one is off. It updates when you come back from System Settings.
- **Sound**: volume and microphone mute banners.
- **Teleprompter**: Follow My Voice, text size, width, height, speed, countdown, hiding from screen sharing, mirrored text, and the shortcuts.
- **About**: the version and the diagnostics report (see below).

## Menu bar options

Click the Brim icon in the menu bar for: **Show Mac Notifications**, **Timer**, **Clear Notifications**, **Notification Log…** (see below), **Appearance** (Show on Lock Screen, hide the pill when idle on screens without a notch), **Launch at Login**, **Send Test Notification**, and **Quit**.

## How the lock screen works

macOS hides every app's windows while the screen is locked, except a special layer that Notification Center itself uses there. Brim moves its window into that layer using SkyLight, a private macOS framework, the same technique as the open-source SkyLightWindow package (MIT, by Lakr233) used by MewNotch.

The lock and unlock symbols are SF Symbols `lock.fill` and `lock.open.fill`, animated with Magic Replace on macOS 15 and later so only the shackle moves. You can browse alternatives in the SF Symbols app and swap the names in `LockGlyph` (in `NotchView.swift`).

While locked, hovering does nothing: your notification history and controls stay private until you unlock.

## Now Playing helper (browser audio)

Since macOS 15.4, apps can't read the system's "Now Playing" info directly. Brim uses the open-source [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD license, used by Boring Notch): macOS's own `/usr/bin/perl` loads a small helper framework that reports what's playing. `build.sh` compiles it from `Vendor/mediaremote-adapter` into Brim.app.

If it ever fails to build (the build prints a note) or a future macOS blocks it, Brim falls back to talking to Spotify and Apple Music directly, as before.

## When a notification doesn't show

Notifications are read the moment macOS saves them (Brim watches the database file), and when several arrive at once each banner gives way to the next after 1.5 seconds; all of them stay in the list.

Menu bar > Brim > **Notification Log…** opens a log in Console. Every notification macOS stores is listed there with the app that sent it, its title (shortened) and what Brim did with it: shown as a banner, put in the history only, or skipped and why. Message text is never written to the log, only its length. The file is `~/Library/Logs/Brim/Notifications.log`.

If a notification you saw in macOS's Notification Center isn't in the log at all, macOS didn't store it where Brim reads. iPhone notifications reach a Mac only through iPhone Mirroring, which Apple doesn't offer on EU accounts; Apple Watch notifications never reach the Mac.

## Sending your own notifications

Anything that can open a link can post to the notch:

```bash
open "brim://notify?title=Build%20finished&body=All%20tests%20passed&icon=checkmark.circle.fill&color=green"
```

`title`, `body`, `icon` (any SF Symbol name) and `color` (red, orange, yellow, green, blue, purple, pink, teal). `brim://clear` clears the history.

Timers: `brim://timer?minutes=10`, `brim://focus`, `brim://stopwatch`, `brim://stop-timer`. In Shortcuts, add an "Open URLs" action with one of these, e.g. a "Pasta timer" shortcut. From Shortcuts, use an "Open URLs" action.

Monitor brightness: `brim://brightness?step=up`, `brim://brightness?step=down`, `brim://brightness?set=40` (percent).

Teleprompter: `brim://prompter?action=toggle` (also `faster`, `slower`, `forward`, `back`, `stop`).

## Design

Built following Apple's interface guidelines (via Emil Kowalski's `apple-design` and `write-swift` skills):

- **One object, not a crossfade.** Like Dynamic Island, the album artwork physically flies from the pill into its spot in the panel (and back) while the shape springs open. The old content blurs away quickly and the new content arrives a beat later, so they never overlap.
- **Dynamic Island springs.** Opening has a little give (damping 0.74, response 0.46 s), closing settles with less (0.86, 0.4 s). Moving in and out mid-animation reverses smoothly from wherever it is.
- **Spatial consistency.** The glass card emerges from the notch and returns into it along the same path, with blur and scale together so it reads as a material arriving rather than a fade.
- **One number drives the split.** The circle, its glyph and the liquid neck are drawn from a single sprung value, and the pill's right edge moves with the same spring, so they never drift apart. The neck is the classic metaball curve, pinching thinner until it snaps just before the circle settles.
- **Feedback on press.** Buttons shrink the instant you press them.
- **Vibrancy over glass.** Text uses system primary / secondary / tertiary styles, which stay legible on any wallpaper.
- **Notifications look like macOS notifications**: app icon, bold title, "now" timestamp, subtitle, two lines of body.
- **Accessibility.** Reduce Motion turns everything into short crossfades and freezes the equalizer. Reduce Transparency replaces glass with a solid surface.

## Diagnostics report

Settings > About > **Create Report…** measures Brim for five seconds and saves a text file to `~/Library/Logs/Brim/` (it opens in Finder). It covers:

- CPU (right now, on average since launch, and minute by minute for the last hour) and memory.
- How often each part of Brim did something since launch, with a per-minute rate: the hover check, the full-screen check, camera and microphone checks, call detection, Downloads checks, notification database reads, AppleScript calls to music apps, Logitech requests and events, monitor brightness reads and writes, banners posted.
- Your settings, the displays, which brightness control is in use, the Logitech devices.
- The Mac's recent wakes and sleeps with their reasons, and what is keeping it or its displays awake right now (from `pmset`).
- Recent events: locks and unlocks, displays sleeping and waking, devices connecting, League mode.

It holds no notification text, song titles or anything you type, and stays on your Mac unless you share it.

## Staying out of the way

- **When the Mac is locked or its displays are off, Brim stops talking to hardware.** No Logitech requests, no monitor commands, no window checks. A message to a monitor or keyboard can count as activity and wake the display, and with an Apple Watch nearby that also unlocks the Mac. When a display merely sleeps or wakes (macOS reports that as a display change too), Brim no longer rebuilds its windows or reconnects to the monitor; only a display really added or removed does that.
- **Clicks pass through the open panel's empty space.** Brim's window is bigger than the panel, so it can grow; only the panel itself takes clicks now, and anything behind the rest (a call banner's buttons, a menu) gets them.
- **Lighter checks**: the hover check runs 30 times a second only while the pointer is near the top of the screen, 8 times a second elsewhere, and rests while the displays are off; the full-screen check runs every 2 seconds (and right away when you switch apps or Spaces); Logitech devices that reconnect while the Mac is locked are left alone until you unlock; a display waking is handled once, not twice; call detection only looks at which app is recording while a microphone is actually open; Downloads is watched for changes instead of being listed every second; the Focus check runs every 5 seconds; the playing waveform draws 20 times a second.

## Limitations

- **Hiding the teleprompter from screen sharing doesn't work with FaceTime and other apps that use macOS's current capture (ScreenCaptureKit).** Brim marks its window as not to be captured, but on recent macOS versions that's only respected by older capture methods; Apple has an open bug report about it. To keep the script private, share a window or an app instead of the entire screen.

- **The notification database is undocumented.** It's the same approach Notchy uses, but a major macOS update can change the format. If that happens, the menu shows "Not readable on this macOS version" and everything else keeps working.
- **The lock screen layer is a private API.** If a future macOS removes it, Brim simply stops appearing on the lock screen; everything else keeps working.
- **AirDrop progress** comes from the same progress reports the Dock's Downloads stack shows. If a macOS version stops reporting AirDrop that way, items still arrive and the finished banner may not show.
- **Media**: with the Now Playing helper, any app (browsers too). Without it, only Spotify and Apple Music. Their own "now playing" notifications are skipped, since the island already shows the song.
- **AirPods battery uses undocumented sources.** When connected, Brim reads the levels macOS keeps on the Bluetooth device; for the case-open card it listens for the same Bluetooth message your iPhone uses. To avoid showing a stranger's AirPods, the card only appears for AirPods very close to the Mac, only if AirPods are paired with this Mac, and at most every 3 minutes.
- **Artwork:** comes from the player itself (through the system's Now Playing information). If a player publishes none, the island shows the player's icon.
- **Keyboard backlight: Bluetooth only, and Brim has to keep asking.** Keyboards on a Logi Bolt or Unifying receiver aren't supported yet. On the MX Keys Mini the keyboard's HID++ channel goes quiet about a second and a half after the Mac last sent it something, so change notifications stop arriving. Brim asks for the level once a second while you're using the Mac, and four times a second for 2 seconds after a change so a quick run of presses keeps up (one 20-byte message each time; it stops after 2 minutes without any input), which keeps them coming. If the very first press after you've been away is missed, the banner shows within a second of you touching the mouse or keyboard.
- **Monitor brightness uses private parts of macOS**: DisplayServices (what Control Center's slider uses) and, as a fallback, IOAVService (the same one MonitorControl, BetterDisplay and m1ddc use on Apple silicon). A future macOS could change them; then the brightness button just doesn't show. Over DDC/CI some monitors don't accept commands, or need DDC/CI switched on in their own menu.
- Brim shows notifications but can't reply to them or press their action buttons.

## Files

```
Sources/
  App.swift                 app entry, menu bar menu, brim:// links
  NotchWindow.swift         floating panel above the menu bar, hover detection
  NotchViewModel.swift      states, look and geometry
  NotchShape.swift          the notch outline with flared top corners
  NotchView.swift           all SwiftUI views, glass surfaces, transitions
  NotificationMirror.swift  reads Notification Center's database
  LockScreen.swift          lock screen layer, lock / unlock detection
  SettingsView.swift        the Settings window
  Activities.swift          timer, calendar, reminders, camera/mic dots, downloads
  NotificationLog.swift     the Notification Log
  Mirror.swift              the camera mirror in the panel
  NowPlayingAdapter.swift   runs the Now Playing helper (browser audio)
  MediaController.swift     now playing, artwork, controls
  AlertCenter.swift         notification queue and history, battery and Bluetooth
  Logitech.swift            Logitech devices over HID++: keyboard backlight, batteries, the backlight icon
  VolumeMonitor.swift       output volume, microphone mute and their banners
  DisplayBrightness.swift   external monitor brightness (macOS's control, or DDC/CI), its shortcuts
  Teleprompter.swift        scripts library, file import, the prompter's timing, its shortcuts
  VoiceFollower.swift       Follow My Voice: on-device speech recognition and finding your place
  ScriptEditor.swift        the script editor window
  PrompterView.swift        the prompter in the island, the panel's teleprompter section
  PanelExtras.swift         the File Shelf and the Shortcuts buttons
  ShortcutCards.swift       the Shortcuts cards in Settings, their glyph picker, and centered glyphs
  Permissions.swift         the Permissions pane: each permission's status
  Diagnostics.swift         activity counters, quiet times (locked, displays off), the diagnostics report
Tools/BacklightProbe.swift  stand-alone HID++ test for the backlight (not part of the app)
Vendor/mediaremote-adapter  the helper's source (BSD license)
docs/                       README images, the GIF, the film and LAUNCH.md (GitHub settings, release notes, posts)
marketing/promo/            the Remotion project for the film and the images
Resources/AppIcon.icns     the app icon
Info.plist
build.sh
```
