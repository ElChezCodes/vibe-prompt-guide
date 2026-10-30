import { useEffect, useState } from "react";

export type OverlayTone = "final" | "sudden" | "a" | "b" | "draw" | "next";

export interface OverlayMessage {
  // A new key shows the message again
  key: string;
  title: string;
  subtitle?: string;
  tone: OverlayTone;
  // Shown this long, then fades out; null = while the message is passed
  holdMs: number | null;
  // Paso_2 §7: only the victory blocks interaction (the battle surface; the
  // Battle Room's HUD above it stays usable)
  blocking?: boolean;
}

// Paso_2 §7: fade in / out ~150 ms
const FADE_MS = 150;

const TITLE_TONE: Record<OverlayTone, string> = {
  final: "text-energy-yellow",
  sudden: "text-destructive",
  a: "text-song-a text-glow-a",
  b: "text-song-b text-glow-b",
  draw: "bg-gradient-to-r from-song-a to-song-b bg-clip-text text-transparent",
  next: "text-foreground",
};

/**
 * Status messages over the battle (Paso_2 §7): Final decision, Sudden Death,
 * Winner / Draw, Preparing next battle. A banner over the timer row (its
 * parent): never over the tension bar or the artwork, never full screen.
 */
const BattleStateOverlay = ({ message }: { message: OverlayMessage | null }) => {
  const [shown, setShown] = useState<OverlayMessage | null>(null);
  const [exiting, setExiting] = useState(false);

  useEffect(() => {
    if (!message) {
      // Fade out what is showing
      setExiting(true);
      const t = setTimeout(() => setShown(null), FADE_MS);
      return () => clearTimeout(t);
    }
    setShown(message);
    setExiting(false);
    if (message.holdMs === null) return;
    const out = setTimeout(() => setExiting(true), message.holdMs);
    const hide = setTimeout(() => setShown(null), message.holdMs + FADE_MS);
    return () => {
      clearTimeout(out);
      clearTimeout(hide);
    };
    // Only a new message restarts it
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [message?.key]);

  if (!shown) return null;

  return (
    <>
      {shown.blocking && !exiting && <div className="fixed inset-0 z-10" aria-hidden />}
      <div
        className={`absolute inset-0 z-30 flex items-center justify-center px-4 pointer-events-none ${exiting ? "animate-fade-out" : "animate-fade-in"}`}
        style={{ animationDuration: `${FADE_MS}ms`, animationFillMode: "forwards" }}
        role="status"
        aria-live="polite"
      >
        {/* Opaque (neon-panel is translucent) and at least the timer's size:
            it covers the timer whole */}
        <div className="max-w-[90%] rounded-2xl bg-background">
          <div className="min-h-16 lg:min-h-24 min-w-[12rem] lg:min-w-[22rem] px-6 py-2 lg:px-10 lg:py-3 flex flex-col justify-center rounded-2xl neon-panel text-center">
            <p className={`font-arcade font-black tracking-widest text-2xl lg:text-5xl ${TITLE_TONE[shown.tone]}`}>{shown.title}</p>
            {shown.subtitle && <p className="mt-1 text-xs lg:text-lg text-text-secondary uppercase tracking-wide truncate">{shown.subtitle}</p>}
          </div>
        </div>
      </div>
    </>
  );
};

export default BattleStateOverlay;
