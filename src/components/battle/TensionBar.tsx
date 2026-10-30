import { useEffect, useRef } from "react";

type BattleIntensity = "normal" | "final" | "sudden";

interface TensionBarProps {
  // Song A's share of the points decided by the backend (0-100)
  percentageA?: number;
  intensity?: BattleIntensity;
}

// Paso_2 §5.4: micro-oscillation ±1–2 px normal, ±3–4 px in the final
// decision, reduced in Sudden Death (§5.5)
const AMPLITUDE_PX: Record<BattleIntensity, number> = { normal: 1.5, final: 3.5, sudden: 0.8 };
// §5.6: never jumps, always smooth interpolation towards the backend value
const SMOOTHING_S = 0.45;
const MAX_SPEED_PCT_S = 35;
const LABEL_GAP_PX = 6;
const EDGE_PX = 4;

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/**
 * Paso_2 §5: one bar, divider starting at 50/50 (StageView is keyed per
 * battle), integer percentages inside the bar pinned to the divider. Display
 * only: it eases towards `percentageA` and wobbles, driven by
 * requestAnimationFrame on the DOM (no React render per frame).
 */
const TensionBar = ({ percentageA = 50, intensity = "normal" }: TensionBarProps) => {
  const barRef = useRef<HTMLDivElement>(null);
  const fillRef = useRef<HTMLDivElement>(null);
  const dividerRef = useRef<HTMLDivElement>(null);
  const labelARef = useRef<HTMLSpanElement>(null);
  const labelBRef = useRef<HTMLSpanElement>(null);
  const targetRef = useRef(percentageA);
  targetRef.current = clamp(percentageA, 0, 100);
  const intensityRef = useRef(intensity);
  intensityRef.current = intensity;

  useEffect(() => {
    const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    let shown = 50;
    let shownLabel = -1;
    let widthA = 0;
    let widthB = 0;
    let last = performance.now();
    let raf = 0;

    const tick = (t: number) => {
      raf = requestAnimationFrame(tick);
      const bar = barRef.current;
      const fill = fillRef.current;
      const divider = dividerRef.current;
      const labelA = labelARef.current;
      const labelB = labelBRef.current;
      if (!bar || !fill || !divider || !labelA || !labelB) return;

      const dt = Math.min(0.1, (t - last) / 1000);
      last = t;
      const target = targetRef.current;
      const maxStep = MAX_SPEED_PCT_S * dt;
      shown += clamp((target - shown) * (1 - Math.exp(-dt / SMOOTHING_S)), -maxStep, maxStep);
      if (Math.abs(target - shown) < 0.01) shown = target;

      const pctA = Math.round(shown);
      if (pctA !== shownLabel) {
        shownLabel = pctA;
        labelA.textContent = `${pctA}%`;
        labelB.textContent = `${100 - pctA}%`;
        widthA = labelA.offsetWidth;
        widthB = labelB.offsetWidth;
      }

      const w = bar.clientWidth;
      const s = t / 1000;
      const amp = reduceMotion ? 0 : AMPLITUDE_PX[intensityRef.current];
      const wobble = amp * (0.6 * Math.sin(s * 2 * Math.PI * 0.9) + 0.4 * Math.sin(s * 2 * Math.PI * 2.3 + 1));
      const x = clamp((shown / 100) * w + wobble, 0, w);

      fill.style.width = `${x}px`;
      divider.style.left = `${x - 2}px`;
      // Pinned to the divider, kept inside the bar and apart near the edges
      const leftA = clamp(x - LABEL_GAP_PX - widthA, EDGE_PX, w - EDGE_PX - widthB - 2 * LABEL_GAP_PX - widthA);
      const leftB = clamp(x + LABEL_GAP_PX, EDGE_PX + widthA + 2 * LABEL_GAP_PX, w - EDGE_PX - widthB);
      labelA.style.left = `${leftA}px`;
      labelB.style.left = `${leftB}px`;
      labelA.style.opacity = "1";
      labelB.style.opacity = "1";
    };

    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  const sudden = intensity === "sudden";

  return (
    <div className="w-full px-4 pt-4">
      <div
        ref={barRef}
        className={`relative w-full h-7 lg:h-10 rounded-full overflow-hidden border bg-gradient-to-l from-song-b to-song-b/60 transition-[filter,box-shadow] duration-500 ${
          sudden
            ? "border-foreground/60 saturate-150 brightness-110 shadow-[0_0_24px_-4px_hsl(var(--song-a)/0.7),0_0_24px_-4px_hsl(var(--song-b)/0.7)]"
            : "border-border"
        }`}
        role="img"
        aria-label={`Song A ${Math.round(percentageA)}%, song B ${100 - Math.round(percentageA)}%`}
      >
        <div ref={fillRef} className="absolute inset-y-0 left-0 bg-gradient-to-r from-song-a/60 to-song-a" style={{ width: "50%" }} />
        <div ref={dividerRef} className="absolute -top-1 -bottom-1 w-1 rounded-full bg-foreground glow-energy" style={{ left: "calc(50% - 2px)" }} />
        <span
          ref={labelARef}
          aria-hidden
          className="absolute font-arcade text-xs lg:text-lg font-black text-foreground tabular-nums leading-none [text-shadow:0_1px_3px_hsl(var(--background)/0.9)]"
          style={{ top: "50%", marginTop: "-0.5em", opacity: 0 }}
        >
          50%
        </span>
        <span
          ref={labelBRef}
          aria-hidden
          className="absolute font-arcade text-xs lg:text-lg font-black text-foreground tabular-nums leading-none [text-shadow:0_1px_3px_hsl(var(--background)/0.9)]"
          style={{ top: "50%", marginTop: "-0.5em", opacity: 0 }}
        >
          50%
        </span>
      </div>
    </div>
  );
};

export default TensionBar;

export type { BattleIntensity };
