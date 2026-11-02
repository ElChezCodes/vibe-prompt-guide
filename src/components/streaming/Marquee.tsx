import { ReactNode, useLayoutEffect, useRef } from "react";

// Speed of the scroll and the rests at each end
const PX_PER_SECOND = 35;
const REST_MS = 1500;

/**
 * One line of text that scrolls back and forth when it doesn't fit (NowPlaying,
 * user request 2026-11-01: titles/artists were cut off). Static and truncated
 * when it fits, or with reduced motion. Display only.
 */
const Marquee = ({ children, className = "" }: { children: ReactNode; className?: string }) => {
  const boxRef = useRef<HTMLSpanElement>(null);
  const textRef = useRef<HTMLSpanElement>(null);

  useLayoutEffect(() => {
    const box = boxRef.current;
    const text = textRef.current;
    if (!box || !text || typeof text.animate !== "function") return;
    let anim: Animation | null = null;

    const start = () => {
      anim?.cancel();
      anim = null;
      const overflow = text.scrollWidth - box.clientWidth;
      const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
      box.dataset.overflowing = overflow > 2 && !reduceMotion ? "true" : "false";
      if (overflow <= 2 || reduceMotion) return;
      const moveMs = (overflow / PX_PER_SECOND) * 1000;
      const total = 2 * REST_MS + 2 * moveMs;
      const at = (ms: number) => ms / total;
      anim = text.animate(
        [
          { transform: "translateX(0)", offset: 0 },
          { transform: "translateX(0)", offset: at(REST_MS) },
          { transform: `translateX(${-overflow}px)`, offset: at(REST_MS + moveMs) },
          { transform: `translateX(${-overflow}px)`, offset: at(2 * REST_MS + moveMs) },
          { transform: "translateX(0)", offset: 1 },
        ],
        { duration: total, iterations: Infinity, easing: "linear" },
      );
    };

    start();
    const observer = typeof ResizeObserver !== "undefined" ? new ResizeObserver(start) : null;
    observer?.observe(box);
    observer?.observe(text);
    return () => {
      observer?.disconnect();
      anim?.cancel();
    };
  }, [children]);

  return (
    <span ref={boxRef} className={`block min-w-0 overflow-hidden whitespace-nowrap ${className}`}>
      <span ref={textRef} className="inline-block whitespace-nowrap will-change-transform">
        {children}
      </span>
    </span>
  );
};

export default Marquee;
