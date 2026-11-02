import React from "react";
import { Composition } from "remotion";
import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";
import { BrimFilm } from "./brim/Film";
import { BrimFilm2, DURATION2 } from "./brim/Film2";
import { Hero, Social, FeatureStill, FEATURES } from "./brim/Stills";

const weights = ["400", "500", "600", "700", "800"];
Promise.all(
  weights.map((w) => loadFont({ family: "Inter", url: staticFile(`inter-latin-${w}-normal.woff2`), weight: w })),
);

const DURATION = 30 * 30;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="Promo-16x9" component={BrimFilm} durationInFrames={DURATION} fps={30} width={1920} height={1080} defaultProps={{ format: "landscape" as const }} />
      <Composition id="Promo-9x16" component={BrimFilm} durationInFrames={DURATION} fps={30} width={1080} height={1920} defaultProps={{ format: "portrait" as const }} />
      <Composition id="Promo-1x1" component={BrimFilm} durationInFrames={DURATION} fps={30} width={1080} height={1080} defaultProps={{ format: "square" as const }} />
      <Composition id="Brim60-16x9" component={BrimFilm2} durationInFrames={DURATION2 * 30} fps={30} width={1920} height={1080} defaultProps={{ format: "landscape" as const }} />
      <Composition id="Brim60-9x16" component={BrimFilm2} durationInFrames={DURATION2 * 30} fps={30} width={1080} height={1920} defaultProps={{ format: "portrait" as const }} />
      <Composition id="Brim60-1x1" component={BrimFilm2} durationInFrames={DURATION2 * 30} fps={30} width={1080} height={1080} defaultProps={{ format: "square" as const }} />
      <Composition id="Social" component={Social} durationInFrames={1} fps={30} width={1280} height={640} />
      <Composition id="Hero" component={Hero} durationInFrames={1} fps={30} width={2400} height={1200} />
      {FEATURES.map((f) => (
        <Composition key={f.id} id={`Feature-${f.id}`} component={FeatureStill} durationInFrames={1} fps={30} width={1600} height={1000} defaultProps={{ id: f.id }} />
      ))}
    </>
  );
};
