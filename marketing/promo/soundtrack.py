"""Brim 60 s soundtrack: "Upbeat" from 0:35 (on a downbeat, so the film's bars land on the track's),
with a few soft UI sounds from OneTake's palette sitting under it."""
import sys, subprocess, wave
import numpy as np
sys.path.insert(0, "/root/.claude/skills/onetake/scripts")
from sfx_palette import Score, air, glass, wood, SR

BEAT = 60 / 117.45
BAR = 4 * BEAT
OFFSET = 0.255 + 68 * BEAT     # bar 17 of the track
DUR = 60.0

raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{OFFSET:.4f}", "-t", str(DUR), "-i", "public/music.mp3",
                      "-ac", "2", "-ar", str(SR), "-f", "s16le", "-"], capture_output=True).stdout
music = np.frombuffer(raw, dtype=np.int16).reshape(-1, 2).astype(np.float64) / 32768
n = int(DUR * SR)
music = np.pad(music, ((0, max(0, n - len(music))), (0, 0)))[:n]
t = np.arange(n) / SR
env = np.clip(t / 0.08, 0, 1) * np.clip((DUR - t) / 3.5, 0, 1) ** 1.5
music *= env[:, None]

bar = lambda k: k * BAR
beat = lambda k: k * BEAT
s = Score(dur=DUR)
P = s.place
soft_air = lambda d=0.55: air(d, 260, 2000, 1.1, 0.45)
for t0 in (0.5, bar(2), bar(3.5), bar(5), bar(6) - 0.2, bar(8) - 0.2, bar(10) + beat(2), bar(15) + beat(1), bar(17), bar(18) + 0.25, bar(19), bar(23)):
    P(soft_air(), t=t0, gain=0.5, send=0.5)
for k in range(6):
    P(glass(1568, 0.35, 0.3), t=bar(6) + beat(k), gain=0.12, send=0.5)
for t0 in (bar(13) + beat(1), bar(14), bar(15)):
    P(wood(320, 0.07), t=t0, gain=0.5, send=0.15)
P(glass(659, 1.6, 0.4), t=bar(23) + 0.7, gain=0.25, send=0.6)
P(glass(988, 1.4, 0.3), t=bar(23) + 0.72, gain=0.16, send=0.6)
sfx = s.mix(peak_db=-8.0)[:n]
sfx = np.pad(sfx, ((0, max(0, n - len(sfx))), (0, 0)))[:n]

mixed = music * 0.82 + sfx * 0.22
peak = np.abs(mixed).max()
mixed *= 10 ** (-3.5 / 20) / peak
out = (np.clip(mixed, -1, 1) * 32767).astype(np.int16)
with wave.open("public/soundtrack.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(out.tobytes())
print("ok", round(20 * np.log10(np.abs(mixed).max()), 2), "dBFS")
