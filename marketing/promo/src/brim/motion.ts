import { Easing } from "remotion";

// Brim's own motion: SwiftUI springs (response, dampingFraction) driven by
// elapsed time, interruptible like the app (a new target starts from wherever
// the value is), and its content transition (blur 6 -> 0, fade, scale 0.92
// from the top, spring 0.4 / 0.9 after 0.07 s; out: blur, scale 0.96, 0.12 s).

export type Curve = (dt: number) => number;

/** SwiftUI's spring(response:dampingFraction:) as progress over elapsed seconds. */
export const sp =
  (response = 0.45, damping = 0.88): Curve =>
  (dt) => {
    if (dt <= 0) return 0;
    const w = (2 * Math.PI) / response;
    if (damping >= 1) return 1 - Math.exp(-w * dt) * (1 + w * dt);
    const wd = w * Math.sqrt(1 - damping * damping);
    const e = Math.exp(-damping * w * dt);
    return 1 - e * (Math.cos(wd * dt) + ((damping * w) / wd) * Math.sin(wd * dt));
  };

/** A timed curve (for fades and the camera). */
export const ez =
  (duration: number, e: (x: number) => number = Easing.bezier(0.42, 0, 0.58, 1)): Curve =>
  (dt) =>
    dt <= 0 ? 0 : dt >= duration ? 1 : e(dt / duration);

export const easeOut = (d: number) => ez(d, Easing.bezier(0.16, 1, 0.3, 1));
export const smooth = (d: number) => ez(d, Easing.bezier(0.45, 0, 0.2, 1));

/** Keys: [start time, target, curve]. Each move starts from the current value. */
export type AKey = [number, number, Curve?];

export const anim = (t: number, keys: AKey[]): number => {
  const at = (time: number, upto: number): number => {
    let v = keys[0][1];
    for (let i = 1; i <= upto; i++) {
      const [t0, target, curve] = keys[i];
      if (time < t0) break;
      const from = at(t0, i - 1);
      v = from + (target - from) * (curve ?? sp())(time - t0);
    }
    return v;
  };
  return at(t, keys.length - 1);
};

/** Brim's content transition: 0..1 in, then out at `out`. */
export const content = (t: number, inAt: number, out = Infinity, fast = false) => {
  const pIn = Math.min(1, Math.max(0, fast ? sp(0.22, 0.95)(t - inAt) : sp(0.4, 0.9)(t - inAt - 0.07)));
  const pOut = t < out ? 0 : Math.min(1, (t - out) / (fast ? 0.07 : 0.12));
  const p = pIn * (1 - pOut);
  const scale = t < out ? 0.92 + 0.08 * pIn : 1 - 0.04 * pOut;
  return {
    visible: t >= inAt && pOut < 1,
    style: {
      opacity: Math.max(0, Math.min(1, p)),
      filter: `blur(${(1 - Math.min(1, p)) * 6}px)`,
      scale: `${scale}`,
      transformOrigin: "50% 0%",
    } as React.CSSProperties,
  };
};

export const clamp01 = (x: number) => Math.max(0, Math.min(1, x));
export const mix = (a: number, b: number, p: number) => a + (b - a) * p;
export const ramp = (t: number, a: number, b: number) => clamp01((t - a) / (b - a));
