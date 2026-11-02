import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { Audio } from "@remotion/media";
import { Glyph, Pointer, Ring } from "./Glyph";
import { Key, inOut, linear, mix, ramp, snap, spring, track, window as win } from "./lib";

// One pill becomes everything (BEATS.md). Every value is a function of t.

export const FONT = "Inter, -apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif";
const SEC = "rgba(235,235,245,0.6)";
const TER = "rgba(235,235,245,0.32)";
const FILL = "rgba(255,255,255,0.1)";
const ORANGE = "#FF9F0A";
const GREEN = "#30D158";
const GROUND = "linear-gradient(135deg, #22305C 0%, #3A2C63 55%, #5A2F55 100%)";

// ---------- the island's shape, in points ----------
const W: Key[] = [
  [0, 12], [0.45, 12], [1.25, 200, spring], [3.0, 200], [3.6, 280, spring], [5.8, 280], [6.6, 208, snap],
  [7.9, 208], [8.25, 396, spring], [9.85, 396], [10.25, 280, snap], [10.75, 280], [11.45, 576, spring],
  [13.3, 576], [14.0, 520, spring], [16.5, 520], [17.1, 200, spring], [19.4, 200], [20.1, 330, spring],
  [22.3, 330], [23.0, 240, inOut],
];
const H: Key[] = [
  [0, 12], [0.45, 12], [1.25, 54, spring], [7.9, 54], [8.25, 72, spring], [9.85, 72], [10.25, 54, snap],
  [10.75, 54], [11.45, 178, spring], [13.3, 178], [14.0, 260, spring], [16.5, 260], [17.1, 54, spring],
  [22.3, 54], [23.0, 84.6, inOut],
];
const RMAX: Key[] = [
  [0, 999], [7.9, 999], [8.0, 26, linear], [9.9, 26], [10.0, 999, linear], [10.8, 999], [10.9, 32, linear],
  [13.3, 32], [14.0, 30], [16.5, 30], [17.0, 999, linear],
];
// The camera: points to pixels at 1920 wide.
const CAM: Key[] = [
  [0, 2.6], [3.0, 2.6], [3.6, 2.4, spring], [5.8, 2.4], [6.6, 2.25], [7.9, 2.25], [8.25, 2.0, snap], [9.85, 2.0],
  [10.25, 2.3, snap], [10.75, 2.3], [11.45, 1.5, spring], [13.2, 1.58, linear], [14.0, 1.6, inOut], [16.5, 1.6],
  [17.1, 2.3, inOut], [22.3, 2.3], [23.5, 0.96, inOut], [25.0, 0.96], [25.8, 0.72, inOut],
];

type Format = "landscape" | "portrait" | "square";

export const BrimFilm: React.FC<{ format: Format; sound?: boolean; words?: boolean; cyFrac?: number; camMul?: number; atTime?: number; hand?: boolean }> = ({ format, sound = true, words = true, cyFrac, camMul = 1, atTime, hand = true }) => {
  const frame = useCurrentFrame();
  const { fps, width: VW, height: VH } = useVideoConfig();
  const t = atTime ?? frame / fps;

  const base = format === "landscape" ? VW / 1920 : format === "portrait" ? 0.93 : 0.82;
  const c = track(t, CAM) * base * camMul;
  const w = track(t, W);
  const h = track(t, H);
  const notchP = ramp(t, 19.4, 20.1, inOut) * (1 - ramp(t, 22.3, 22.9, inOut));
  const r = Math.min(h / 2, track(t, RMAX));
  const rTop = r * (1 - notchP);

  // where the island sits on screen
  const cyBase = VH * (cyFrac ?? (format === "landscape" ? 0.42 : 0.4));
  const iconCy = VH * (format === "landscape" ? 0.47 : 0.42);
  const lock = ramp(t, 25.0, 25.8, inOut);
  const lockupX = format === "landscape" ? VW / 2 - 300 : VW / 2;
  const lockupY = format === "landscape" ? VH * 0.47 : VH * (format === "portrait" ? 0.4 : 0.36);
  let cx = mix(VW / 2, lockupX, lock);
  const lockLift = win(t, 16.5, 19.6, 0.6, 0.5) * VH * (format === "landscape" ? 0.13 : 0.08);
  let cy = mix(cyBase - lockLift, (h * c) / 2, notchP);
  cy = mix(cy, iconCy, ramp(t, 22.3, 23.5, inOut));
  cy = mix(cy, lockupY, lock);

  // a dot first, then the pill
  const pop = t < 0.45 ? spring(Math.min(1, Math.max(0, (t - 0.12) / 0.33))) : 1;
  // the circle that splits off and melts back
  const sp = ramp(t, 5.8, 6.6, spring) * (1 - ramp(t, 7.9, 8.15, inOut));
  const anchor = ramp(t, 5.79, 5.8, linear) * (1 - ramp(t, 7.9, 8.25, inOut));
  const pillX = anchor * (-140 + w / 2);
  const circleX = -140 + w - 27 + 66 * sp;
  // a squash on every hit of the burst
  const hit = [8.25, 8.8, 9.35].reduce((a, h0) => a + (t >= h0 ? Math.exp(-(t - h0) * 14) * 0.07 : 0), 0);

  const toScreen = (x: number, y: number) => [cx + x * c, cy + y * c];

  // layers
  const clockO = win(t, 1.0, 3.15, 0.35, 0.15);
  const liveO = Math.max(win(t, 3.3, 7.98, 0.3, 0.12), win(t, 10.15, 10.95, 0.15, 0.15), win(t, 19.9, 22.6, 0.3, 0.25));
  const timerO = win(t, 6.05, 7.95, 0.25, 0.12);
  const panelO = win(t, 11.15, 13.45, 0.3, 0.15);
  const prompterO = win(t, 13.75, 16.62, 0.3, 0.12);
  const lockO = win(t, 16.9, 19.45, 0.25, 0.2);
  const lockScreen = win(t, 16.55, 19.55, 0.45, 0.35);
  const iconO = ramp(t, 22.95, 23.15, linear);
  const iris = ramp(t, 23.1, 23.8, spring);

  const [px, py] = pointerAt(t, c, cx, cy, VW, VH);
  const press = Math.exp(-Math.max(0, t - 13.2) * 9) * (t >= 13.2 ? 1 : 0);

  const fs = format === "landscape" ? 76 : format === "portrait" ? 74 : 62;
  const textY = VH * (format === "landscape" ? 0.77 : format === "portrait" ? 0.66 : 0.78);

  const iconPx = (240 / 624) * 1024 * c; // the icon's svg box on screen
  const insetTop = mix(402 / 1024, 100 / 1024, iris) * 100;
  const insetSide = mix(200 / 1024, 100 / 1024, iris) * 100;
  const insetR = mix(110, 185, iris) / 1024 * iconPx;

  return (
    <AbsoluteFill style={{ background: GROUND, fontFamily: FONT, overflow: "hidden" }}>
      {sound ? <Audio src={staticFile("sfx.wav")} /> : null}
      {/* the lock screen behind the island */}
      <AbsoluteFill style={{ background: "rgba(5,6,14,0.45)", opacity: lockScreen }} />
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          top: cy + (54 * c) / 2 + 26 * base,
          textAlign: "center",
          opacity: lockScreen,
          translate: `0px ${(1 - ramp(t, 16.55, 17.2, snap)) * 30}px`,
        }}
      >
        <div style={{ fontSize: 34 * base * (format === "landscape" ? 1 : 1.1), fontWeight: 600, color: "rgba(255,255,255,0.85)" }}>Mon 26 Oct</div>
        <div
          style={{
            fontSize: 210 * base * (format === "landscape" ? 1 : 1.1),
            fontWeight: 700,
            lineHeight: 0.95,
            letterSpacing: "-0.02em",
            color: "rgba(225,232,255,0.8)",
            textShadow: "0 2px 0 rgba(255,255,255,0.18), 0 10px 40px rgba(0,0,0,0.3)",
          }}
        >
          20:51
        </div>
      </div>

      {/* the circle that splits off */}
      {sp > 0.01 ? (
        <>
          <div
            style={{
              position: "absolute",
              left: toScreen(pillX + w / 2 - 2, 0)[0],
              top: cy - (h * c * mix(0.62, 0.16, sp)) / 2,
              width: Math.max(0, (circleX - 27 - (pillX + w / 2) + 4) * c),
              height: h * c * mix(0.62, 0.16, sp),
              background: "#000",
              opacity: sp < 0.85 ? 1 : 1 - (sp - 0.85) / 0.15,
            }}
          />
          <div
            style={{
              position: "absolute",
              left: toScreen(circleX - 27, 0)[0],
              top: cy - 27 * c,
              width: 54 * c,
              height: 54 * c,
              borderRadius: "50%",
              background: "#000",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              boxShadow: "0 20px 50px rgba(0,0,0,0.35)",
            }}
          >
            <div style={{ opacity: timerO, scale: `${c}` }}>
              <Ring size={48} progress={0.62 - (t - 6) * 0.004} color={ORANGE}>
                <span style={{ fontSize: 13.5, fontWeight: 700, color: ORANGE, fontVariantNumeric: "tabular-nums" }}>
                  {t < 7 ? "9:56" : "9:55"}
                </span>
              </Ring>
            </div>
          </div>
        </>
      ) : null}

      {/* the island */}
      <div
        style={{
          position: "absolute",
          left: toScreen(pillX - w / 2, 0)[0],
          top: cy - (h * c) / 2,
          width: w * c,
          height: h * c,
          borderRadius: `${rTop * c}px ${rTop * c}px ${r * c}px ${r * c}px`,
          background: "#000",
          scale: `${pop * (1 + hit)} ${pop * (1 - hit * 0.6)}`,
          boxShadow: `0 ${24 * base}px ${60 * base}px rgba(0,0,0,${0.35 * (1 - notchP)})`,
          overflow: "hidden",
          opacity: 1 - iconO,
        }}
      >
        <div style={{ position: "absolute", left: 0, top: 0, width: w, height: h, scale: `${c}`, transformOrigin: "0 0" }}>
          <Clock o={clockO} w={w} />
          <Live o={liveO} w={w} t={t} notch={notchP} />
          <Banners t={t} />
          <Panel o={panelO} t={t} />
          <Prompter o={prompterO} t={t} />
          <LockGlyph o={lockO} t={t} w={w} h={h} />
        </div>
      </div>
      {/* notch flares where the island meets the top edge */}
      {notchP > 0.02 ? (
        <>
          <Flare x={toScreen(-w / 2, 0)[0]} size={10 * c} o={notchP} side="left" top={cy - (h * c) / 2} />
          <Flare x={toScreen(w / 2, 0)[0]} size={10 * c} o={notchP} side="right" top={cy - (h * c) / 2} />
        </>
      ) : null}

      {/* the icon opens out of the pill */}
      {iconO > 0 ? (
        <div
          style={{
            position: "absolute",
            left: cx - iconPx / 2,
            top: cy - iconPx / 2,
            width: iconPx,
            height: iconPx,
            opacity: iconO,
            clipPath: `inset(${insetTop}% ${insetSide}% ${insetTop}% ${insetSide}% round ${insetR}px)`,
          }}
        >
          <Img src={staticFile("AppIcon.svg")} style={{ width: "100%", height: "100%" }} />
        </div>
      ) : null}

      {/* the hand: the cause of the hover and the click */}
      {hand && t > 9.9 && t < 14.8 ? (
        <div style={{ position: "absolute", left: px, top: py, zIndex: 5 }}>
          <Pointer size={30 * base * (format === "landscape" ? 1.1 : 1.3)} press={press} />
        </div>
      ) : null}

      {/* words */}
      {words ? <Words t={t} y={textY} size={fs} /> : null}
      <EndCard t={t} format={format} base={base} cx={cx} cy={cy} iconPx={iconPx} VW={VW} VH={VH} />
    </AbsoluteFill>
  );
};

// ---------- the hand ----------
const pointerAt = (t: number, c: number, cx: number, cy: number, VW: number, VH: number): [number, number] => {
  const start: [number, number] = [VW * 0.86, VH * 1.05];
  const hover: [number, number] = [cx + 70 * c, cy + 10 * c];
  const button: [number, number] = [cx + 154 * c, cy - 57 * c];
  const out: [number, number] = [VW * 0.95, VH * 1.1];
  const a = ramp(t, 9.95, 10.7, snap);
  const b = ramp(t, 12.55, 13.1, inOut);
  const d = ramp(t, 14.0, 14.7, inOut);
  let x = mix(start[0], hover[0], a);
  let y = mix(start[1], hover[1], a);
  x = mix(x, button[0], b);
  y = mix(y, button[1], b);
  x = mix(x, out[0], d);
  y = mix(y, out[1], d);
  return [x, y];
};

// ---------- island content (drawn in points) ----------
const Clock: React.FC<{ o: number; w: number }> = ({ o, w }) =>
  o <= 0 ? null : (
    <div style={{ position: "absolute", left: 0, top: 0, width: w, height: 54, opacity: o, display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 26px", boxSizing: "border-box" }}>
      <span style={{ fontSize: 23, fontWeight: 700, color: "rgba(235,235,245,0.72)", fontVariantNumeric: "tabular-nums" }}>20:16</span>
      <span style={{ display: "flex", alignItems: "center", gap: 5 }}>
        <span style={{ fontSize: 17, fontWeight: 700, color: "#F5F5F7" }}>11°</span>
        <Glyph name="cloudmoon" size={19} sw={1.8} />
      </span>
    </div>
  );

const Art: React.FC<{ size: number; radius: number }> = ({ size, radius }) => (
  <div style={{ position: "relative", width: size, height: size, borderRadius: radius, overflow: "hidden", flex: "none", background: "linear-gradient(135deg, #FF7A59, #8A3FD1)" }}>
    <div style={{ position: "absolute", width: size * 0.42, height: size * 0.42, left: size * 0.46, top: size * 0.16, borderRadius: "50%", background: "rgba(255,236,210,0.75)" }} />
    <div style={{ position: "absolute", width: size * 1.3, height: size * 0.7, left: -size * 0.15, top: size * 0.62, borderRadius: "50%", background: "rgba(20,10,40,0.45)" }} />
  </div>
);

const Bars: React.FC<{ t: number; size?: number }> = ({ t, size = 25 }) => {
  const rest = [0.36, 0.72, 1.0, 0.56, 0.84, 0.44];
  return (
    <span style={{ display: "flex", gap: 1.9, alignItems: "center", height: size, width: size, justifyContent: "center", flex: "none" }}>
      {rest.map((x, i) => {
        const k = 0.55 + 0.45 * Math.abs(Math.sin(t * (5.5 + i * 0.9) + i * 1.7));
        return <span key={i} style={{ width: 2.6, height: size * 0.8 * x * k, borderRadius: 1.3, background: "#FFF" }} />;
      })}
    </span>
  );
};

const Live: React.FC<{ o: number; w: number; t: number; notch: number }> = ({ o, w, t, notch }) => {
  if (o <= 0) return null;
  const grow = ramp(t, 3.25, 3.75, spring);
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: w, height: 54, opacity: o, display: "flex", alignItems: "center", gap: 8, padding: `0 ${15 + notch * 6}px 0 ${11 + notch * 8}px`, boxSizing: "border-box" }}>
      <div style={{ scale: `${t > 4 ? 1 : grow}` }}>
        <Art size={32} radius={9} />
      </div>
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
        <span style={{ fontSize: 14, fontWeight: 600, color: "#F5F5F7", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>Neon Tide (Late Mix)</span>
        <span style={{ fontSize: 11, color: SEC, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>Marla Vey, Kites &amp; Co</span>
      </div>
      <Bars t={t} />
    </div>
  );
};

const IconCircle: React.FC<{ name: string; color?: string }> = ({ name, color = "#FFF" }) => (
  <span style={{ width: 38, height: 38, borderRadius: "50%", background: "rgba(255,255,255,0.12)", display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
    <Glyph name={name} size={19} color={color} />
  </span>
);

const BannerRow: React.FC<{ lead: React.ReactNode; title: string; sub: string; subColor?: string; right?: React.ReactNode }> = ({ lead, title, sub, subColor, right }) => (
  <div style={{ position: "absolute", left: 0, top: 0, width: 396, height: 72, display: "flex", alignItems: "center", gap: 12, padding: "0 17px", boxSizing: "border-box" }}>
    {lead}
    <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 1 }}>
      <span style={{ fontSize: 13, fontWeight: 600, color: "#F5F5F7", whiteSpace: "nowrap" }}>{title}</span>
      <span style={{ fontSize: 12, fontWeight: 500, color: subColor ?? "rgba(245,245,247,0.82)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{sub}</span>
    </div>
    {right}
  </div>
);

const Banners: React.FC<{ t: number }> = ({ t }) => {
  if (t < 8.2 || t > 9.95) return null;
  const fadeOut = 1 - ramp(t, 9.8, 9.92, linear);
  const chat = (
    <span style={{ width: 38, height: 38, borderRadius: 9, background: "linear-gradient(180deg, #5BE584, #1DB954)", display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
      <Glyph name="chat" size={22} sw={2.2} />
    </span>
  );
  const now = <span style={{ alignSelf: "flex-start", marginTop: 18, fontSize: 11, color: TER }}>now</span>;
  const vol = ramp(t, 8.85, 9.25, snap);
  const level = (
    <span style={{ display: "block", width: 96, height: 6, borderRadius: 3, background: "rgba(255,255,255,0.18)", overflow: "hidden", flex: "none" }}>
      <span style={{ display: "block", width: 96 * mix(0.12, 0.62, vol), height: 6, borderRadius: 3, background: "#FFF" }} />
    </span>
  );
  const small = (p: number, glyph: string, label: string) => (
    <span style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 2 }}>
      <Ring size={30} progress={p} color={GREEN} width={3}>
        <Glyph name={glyph} size={13} color={glyph === "bolt" ? GREEN : "#FFF"} sw={2} />
      </Ring>
      <span style={{ fontSize: 9.5, fontWeight: 600, color: SEC }}>{label}</span>
    </span>
  );
  return (
    <div style={{ opacity: fadeOut * ramp(t, 8.2, 8.3, linear) }}>
      {t < 8.8 ? <BannerRow lead={chat} title="Giulia" sub="Are we still on for dinner tonight?" subColor={SEC} right={now} /> : null}
      {t >= 8.8 && t < 9.35 ? <BannerRow lead={<IconCircle name="speakerwave" />} title="Volume" sub="Mac mini Speakers" right={level} /> : null}
      {t >= 9.35 ? (
        <BannerRow
          lead={<IconCircle name="airpods" />}
          title="AirPods Pro"
          sub="Nearby"
          right={<span style={{ display: "flex", gap: 8, marginTop: 4 }}>{small(0.8, "bolt", "80%")}{small(0.9, "case", "90%")}</span>}
        />
      ) : null}
    </div>
  );
};

const HBtn: React.FC<{ name: string; active?: boolean; size?: number; gs?: number }> = ({ name, active, size = 26, gs = 13 }) => (
  <span style={{ width: size, height: size, borderRadius: "50%", background: active ? "rgba(255,255,255,0.26)" : FILL, display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
    <Glyph name={name} size={gs} color="rgba(235,235,245,0.85)" />
  </span>
);

const Panel: React.FC<{ o: number; t: number }> = ({ o, t }) => {
  if (o <= 0) return null;
  const clicked = t >= 13.2;
  const sc = (c1: string, c2: string, g: string) => (
    <span style={{ width: 26, height: 26, borderRadius: "50%", background: `linear-gradient(180deg, ${c1}, ${c2})`, display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
      <Glyph name={g} size={13} sw={2.1} />
    </span>
  );
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: 576, height: 178, padding: 19, boxSizing: "border-box", opacity: o, display: "flex", flexDirection: "column" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 6, height: 26 }}>
        <span style={{ width: 16, height: 16, borderRadius: 4, background: "linear-gradient(180deg, #FF6A88, #E0245E)" }} />
        <span style={{ fontSize: 11, fontWeight: 500, color: SEC }}>Music</span>
        <span style={{ display: "flex", gap: 6, marginLeft: 6 }}>
          {sc("#D29E3B", "#A45724", "sunmax")}
          {sc("#7188EC", "#4954D1", "timer")}
          {sc("#CE7CA9", "#A04160", "star")}
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ display: "flex", gap: 8 }}>
          <HBtn name="personsq" />
          <HBtn name="alignleft" active={clicked} />
          <HBtn name="sunmax" />
          <HBtn name="cupsaucer" gs={14} />
          <HBtn name="timer" />
        </span>
      </div>
      <div style={{ display: "flex", gap: 16, flex: 1, marginTop: 8 }}>
        <div style={{ flex: 1, paddingTop: 6, display: "flex", gap: 14 }}>
          <Art size={84} radius={12} />
          <div style={{ width: 200, display: "flex", flexDirection: "column" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ flex: 1, fontSize: 13.5, fontWeight: 700, color: "#F5F5F7", whiteSpace: "nowrap" }}>Neon Tide (Late Mix)</span>
              <Glyph name="star" size={14} color={SEC} sw={1.6} />
            </div>
            <span style={{ fontSize: 12, color: SEC, marginBottom: 10 }}>Marla Vey, Kites &amp; Co</span>
            <span style={{ display: "block", width: 200, height: 4, borderRadius: 2, background: "rgba(255,255,255,0.18)", overflow: "hidden" }}>
              <span style={{ display: "block", width: 200 * (0.26 + (t - 11) * 0.01), height: 4, background: "#FFF" }} />
            </span>
            <span style={{ display: "flex", justifyContent: "space-between", fontSize: 9, fontWeight: 500, color: TER, marginTop: 4 }}>
              <span>0:34</span>
              <span>-1:39</span>
            </span>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: 156, marginLeft: 22, marginTop: 9 }}>
              <Glyph name="shuffle" size={13} color={SEC} sw={1.8} />
              <Glyph name="back" size={19} />
              <Glyph name="pause" size={22} />
              <Glyph name="fwd" size={19} />
              <Glyph name="repeat" size={13} color={SEC} sw={1.8} />
            </div>
          </div>
        </div>
        <div style={{ width: 1, background: "rgba(255,255,255,0.09)" }} />
        <div style={{ width: 207, display: "flex", flexDirection: "column", gap: 6 }}>
          <div style={{ display: "flex", gap: 9, alignItems: "center", padding: "7px 9px", borderRadius: 10, background: "rgba(255,255,255,0.08)" }}>
            <span style={{ width: 26, height: 26, borderRadius: 6, background: "linear-gradient(180deg, #5BE584, #1DB954)", display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
              <Glyph name="chat" size={15} sw={2.2} />
            </span>
            <div style={{ flex: 1, display: "flex", flexDirection: "column" }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span style={{ fontSize: 12, fontWeight: 700, color: "#F5F5F7" }}>Giulia</span>
                <span style={{ fontSize: 10, color: TER }}>20:10</span>
              </div>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span style={{ fontSize: 11, color: SEC }}>Hahaha</span>
                <span style={{ fontSize: 10, color: TER }}>5 more</span>
              </div>
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "0 8px", height: 30, borderRadius: 10, background: "rgba(255,255,255,0.08)" }}>
            <Glyph name="timer" size={14} color={ORANGE} sw={2} />
            <span style={{ flex: 1, fontSize: 12, fontWeight: 700, color: "#F5F5F7" }}>Timer</span>
            <span style={{ fontSize: 13, fontWeight: 700, color: ORANGE, fontVariantNumeric: "tabular-nums" }}>9:51</span>
          </div>
        </div>
      </div>
    </div>
  );
};

const SCRIPT = [
  "Hi everyone, and thanks for joining.",
  "",
  "Today I want to show you a small app",
  "I've been building for the Mac. It's called",
  "Brim, and it lives at the top of your screen.",
  "",
  "Most of us glance up there a hundred",
  "times a day.",
];

const Prompter: React.FC<{ o: number; t: number }> = ({ o, t }) => {
  if (o <= 0) return null;
  const FS = 22;
  const LH = FS * 1.64;
  const reading = 260 / 3;
  // glides two lines while you read
  const scroll = track(t, [[14.2, 0], [15.0, 2, inOut], [15.9, 3, inOut], [16.5, 4, inOut]]);
  const fade = "linear-gradient(180deg, transparent 0%, transparent 9%, #000 24%, #000 72%, transparent 97%)";
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: 520, height: 260, opacity: o }}>
      <div style={{ position: "absolute", inset: 0, WebkitMaskImage: fade, maskImage: fade }}>
        {SCRIPT.map((ln, i) =>
          ln ? (
            <div key={i} style={{ position: "absolute", left: 26, top: reading - LH * 0.55 + (i - scroll) * LH, fontSize: FS, fontWeight: 700, color: "#FFF", whiteSpace: "nowrap", lineHeight: `${LH}px`, letterSpacing: "-0.01em" }}>
              {ln}
            </div>
          ) : null,
        )}
      </div>
      <div style={{ position: "absolute", left: 9, top: reading - 8 }}>
        <Glyph name="play" size={12} color={ORANGE} />
      </div>
      <div style={{ position: "absolute", left: 18, right: 18, top: 12, display: "flex", alignItems: "center" }}>
        <span style={{ height: 24, padding: "0 8px", display: "flex", alignItems: "center", gap: 2 }}>
          {[0.6, 1, 0.8, 0.5].map((x, i) => (
            <span key={i} style={{ width: 2.5, height: 3 + 5 * x * (0.5 + 0.5 * Math.abs(Math.sin(t * 9 + i))), borderRadius: 1.25, background: ORANGE }} />
          ))}
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ height: 24, padding: "0 9px", borderRadius: 12, background: "rgba(255,255,255,0.08)", fontSize: 13, fontWeight: 700, color: "rgba(255,255,255,0.85)", display: "flex", alignItems: "center", fontVariantNumeric: "tabular-nums" }}>
          {t < 15 ? "1:06" : t < 16 ? "1:05" : "1:04"}
        </span>
      </div>
      <div style={{ position: "absolute", left: "50%", top: 6, width: 5, height: 5, marginLeft: -2.5, borderRadius: "50%", background: ORANGE }} />
      <div style={{ position: "absolute", left: 32, top: 249, width: 456, height: 4, borderRadius: 2, background: "rgba(255,255,255,0.15)" }}>
        <div style={{ width: 4 + 456 * Math.max(0, (t - 14) * 0.04), height: 4, borderRadius: 2, background: "rgba(255,255,255,0.75)" }} />
      </div>
    </div>
  );
};

const LockGlyph: React.FC<{ o: number; t: number; w: number; h: number }> = ({ o, t, w, h }) => {
  if (o <= 0) return null;
  const open = ramp(t, 18.9, 19.25, spring);
  return (
    <div style={{ position: "absolute", left: 0, top: 0, width: w, height: h, opacity: o, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <svg width={22} height={22} viewBox="0 0 24 24" fill="none" stroke="#FFF" strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round">
        <rect x={6.5} y={11} width={11} height={9.5} rx={1.5} fill="#FFF" />
        <path d="M8.8 11V8.2a3.2 3.2 0 0 1 6.4 0V11" style={{ transformOrigin: "15.2px 11px", rotate: `${open * 38}deg`, translate: `0px ${-open * 1.2}px` }} />
      </svg>
    </div>
  );
};

const Flare: React.FC<{ x: number; size: number; o: number; side: "left" | "right"; top: number }> = ({ x, size, o, side, top }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 10 10"
    style={{ position: "absolute", left: side === "left" ? x - size + 0.5 : x - 0.5, top, opacity: o }}
  >
    <path d={side === "left" ? "M0 0 L10 0 L10 10 Q10 0 0 0 Z" : "M10 0 L0 0 L0 10 Q0 0 10 0 Z"} fill="#000" />
  </svg>
);

// ---------- words ----------
type Line = { text: string; a: number; b: number; hard?: boolean };
const LINES: Line[] = [
  { text: "The top of your screen.", a: 1.5, b: 2.95 },
  { text: "Now playing.", a: 3.9, b: 5.75 },
  { text: "Timers that step aside.", a: 6.7, b: 7.85 },
  { text: "Notifications.", a: 8.25, b: 8.8, hard: true },
  { text: "Volume.", a: 8.8, b: 9.35, hard: true },
  { text: "AirPods.", a: 9.35, b: 9.9, hard: true },
  { text: "Everything, one hover away.", a: 11.6, b: 13.15 },
  { text: "Your script, right under the camera.", a: 14.3, b: 16.4 },
  { text: "Even when it's locked.", a: 17.3, b: 18.85 },
  { text: "In the notch, or floating.", a: 20.3, b: 22.2 },
];

const Words: React.FC<{ t: number; y: number; size: number }> = ({ t, y, size }) => {
  const line = LINES.find((l) => t >= l.a - 0.05 && t <= l.b + 0.35);
  if (!line) return null;
  const words = line.text.split(" ");
  const out = line.hard ? (t > line.b ? 1 : 0) : ramp(t, line.b, line.b + 0.3, inOut);
  return (
    <div
      style={{
        position: "absolute",
        left: "7%",
        right: "7%",
        top: y,
        display: "flex",
        flexWrap: "wrap",
        justifyContent: "center",
        gap: `0 ${size * 0.26}px`,
        fontSize: size,
        fontWeight: 700,
        letterSpacing: "-0.025em",
        lineHeight: 1.08,
        color: "#FFF",
        opacity: 1 - out,
        translate: `0px ${-out * size * 0.25}px`,
      }}
    >
      {words.map((wd, i) => {
        const p = line.hard ? (t >= line.a ? 1 : 0) : ramp(t, line.a + i * 0.085, line.a + i * 0.085 + 0.42, snap);
        return (
          <span key={i} style={{ opacity: p, translate: `0px ${(1 - p) * size * 0.45}px`, display: "inline-block" }}>
            {wd}
          </span>
        );
      })}
    </div>
  );
};

const EndCard: React.FC<{ t: number; format: Format; base: number; cx: number; cy: number; iconPx: number; VW: number; VH: number }> = ({
  t,
  format,
  base,
  cx,
  cy,
  iconPx,
  VW,
}) => {
  if (t < 25.0) return null;
  const word = ramp(t, 25.2, 25.9, snap);
  const tag = ramp(t, 25.7, 26.4, snap);
  const iconVisible = iconPx * (824 / 1024);
  const landscape = format === "landscape";
  const markSize = landscape ? 170 * base : format === "portrait" ? 150 : 120;
  const left = landscape ? cx + iconVisible / 2 + 56 * base : 0;
  const top = landscape ? cy - markSize * 0.62 : cy + iconVisible / 2 + 40 * base;
  return (
    <div
      style={{
        position: "absolute",
        left,
        width: landscape ? undefined : VW,
        top,
        display: "flex",
        flexDirection: "column",
        alignItems: landscape ? "flex-start" : "center",
      }}
    >
      <span style={{ fontSize: markSize, fontWeight: 800, letterSpacing: "-0.045em", color: "#FFF", lineHeight: 1, opacity: word, translate: `0px ${(1 - word) * 40}px` }}>Brim</span>
      <span style={{ fontSize: markSize * 0.27, fontWeight: 600, color: "rgba(235,235,245,0.7)", marginTop: markSize * 0.12, opacity: tag, translate: `0px ${(1 - tag) * 24}px` }}>
        Free for macOS.
      </span>
    </div>
  );
};
