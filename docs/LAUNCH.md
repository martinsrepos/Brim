# Launch kit

Everything for putting Brim on GitHub and telling people about it. Images and films are in this folder.

## GitHub settings

**About (description):** A Dynamic Island for your Mac: notifications, music, timers and a teleprompter in one pill at the top of your screen.

**Website:** leave empty for now, or the Releases page.

**Release:** run `./build.sh dmg`, then on GitHub go to Releases › Draft a new release, tag it `v1.0`, paste the release notes below and attach `build/Brim-1.0.dmg`.

**Topics:** `macos` `swift` `swiftui` `dynamic-island` `notch` `menu-bar-app` `notifications` `teleprompter` `liquid-glass` `macos-app`

**Social preview:** Settings > General > Social preview > Edit > upload `social-preview.png` (1280 x 640).

**The film in the README:** GitHub only plays videos uploaded through its editor. Open README.md on github.com, click Edit, drag `brim-film-16x9.mp4` into the text where the "Watch the one minute film" link is, and replace that link with the URL GitHub gives you. It then plays inline. The GIF above it plays everywhere already.

**Sponsor button:** add `.github/FUNDING.yml` with your Buy Me a Coffee, Ko-fi or GitHub Sponsors name, for example:

```yaml
github: [your-username]
ko_fi: your-name
```

## First release notes (v1.0)

Brim turns the top of your Mac's screen into a Dynamic Island.

- Notifications from every app, in a banner that drops out of the pill
- What's playing, with artwork and controls, from any app, browsers included
- Timers, stopwatches and Focus rounds, in their own circle beside your music
- Volume, brightness, keyboard backlight, microphone and AirPods banners
- A teleprompter right under the camera that follows your voice, on your Mac only
- A File Shelf, a camera mirror, Keep Awake and up to three of your Shortcuts in the panel
- The lock screen, the notch style or a floating pill, from solid black to clear glass

Requires macOS 14 or later; Liquid Glass needs macOS 26. Brim asks for each permission only when a feature first needs it.

**Installing:** open the DMG and drag Brim to Applications. The first time, macOS will say it can't check Brim for malware (it isn't notarized yet): open System Settings › Privacy & Security, scroll down and click **Open Anyway** next to Brim. After that it opens normally.

## Posts

**X / Threads / Bluesky (with the square or vertical film)**

I made a Dynamic Island for the Mac. Notifications, music, timers, a teleprompter that sits right under the camera, all in one pill at the top of the screen. It's free and on GitHub: [link]

**LinkedIn (with the 16:9 film)**

For the last few months I've been building Brim, a small Mac app that turns the top of the screen into a Dynamic Island.

It started because I kept looking up there for the time, for what was playing, for the message I was waiting for. Now that space shows my notifications, my music and my timers, and when I record a video it becomes a teleprompter right under the camera that scrolls as I talk.

It's free on GitHub, and I'd love feedback from anyone who tries it: [link]

**Reddit, r/macapps**

Title: I built a free Dynamic Island for the Mac, with a teleprompter that follows your voice

Body: Brim lives in the notch on a MacBook or floats as a pill on any display. It shows notifications from every app, what's playing (browsers too), timers in their own circle, system banners for volume and AirPods, and a panel on hover with a file shelf and your own Shortcuts. The teleprompter sits under the camera and scrolls as you speak, using on-device speech recognition only. No account, no analytics. Feedback very welcome: [link]

## Brand notes

- Name: Brim. Tagline: "The top of your screen, put to work."
- Ground: the gradient #22305C to #3A2C63 to #5A2F55. The island is always pure black.
- Type: SF Pro on the Mac (Inter in the images and films, which can't ship SF Pro).
- App icons, album art, names and songs in all materials are stand-ins. Real app icons, especially Apple's, stay out of marketing; see Apple's and Meta's brand guidelines before adding any.
