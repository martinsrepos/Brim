# Brim promo film

Two cuts, built with Remotion from the same parts as the app:

- **Brim60** (the one to use): 60 seconds on the track "Upbeat" by sub_clair, cut to its beat
  (117.45 bpm, starting at 0:35 of the track). `src/brim/Film2.tsx`.
- **Promo** (the first, 30 second cut, no music): `src/brim/Film.tsx`, beat sheet in `BEATS.md`.

Every move uses Brim's own springs (SwiftUI's response and damping), and content comes and goes
with the app's transition: a 6 pt blur, a fade and a small scale from the top.

```bash
npm i
# the music isn't in the repo (its licence doesn't allow sharing the file itself):
# put the track at public/music.mp3, then build the soundtrack
python3 soundtrack.py            # music from 0:35 + soft UI sounds -> public/soundtrack.wav
npx remotion studio              # preview
npx remotion render Brim60-16x9 out/brim-60s-16x9.mp4   # also Brim60-9x16 and Brim60-1x1
npx remotion still Hero out/hero.png                    # also Social and Feature-<name>
```

`soundtrack.py` needs the OneTake skill for its sound palette. On a Mac, delete the
`Config.setBrowserExecutable` line in `remotion.config.ts`.

Licences: Inter (SIL Open Font License) stands in for SF Pro. The UI sounds come from OneTake's
palette (PolyForm Noncommercial: fine for a free project; check it before using them in anything you
sell). Remotion is free for individuals and teams of up to three. Check the music's licence where you
downloaded it before publishing.
