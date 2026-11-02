import { ReactNode, useLayoutEffect, useRef, useState } from "react";

// Speed of the scroll, the gap before the text comes in again, and the rest
// once a loop has come back to the start
const PX_PER_SECOND = 35;
const GAP_PX = 48;
const REST_MS = 1500;

/**
 * One line of text that scrolls when it doesn't fit (NowPlaying, user requests
 * 2026-11-01). Like Spotify: the text moves along, a gap, the same text comes
 * in behind it, and when it is back where it started it rests a moment and
 * loops (one direction, never back and forth). Static and truncated when it
 * fits, or with reduced motion. Display only.
 */
const Marquee = ({ children, className = "" }: { children: ReactNode; className?: string }) => {
  const boxRef = useRef<HTMLSpanElement>(null);
  const trackRef = useRef<HTMLSpanElement>(null);
  const textRef = useRef<HTMLSpanElement>(null);
  const [scrolling, setScrolling] = useState(false);

  // Does one copy fit? (measured on the first copy only)
  useLayoutEffect(() => {
    const box = boxRef.current;
    const text = textRef.current;
    if (!box || !text) return;
    const measure = () => {
      const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
      setScrolling(!reduceMotion && typeof text.animate === "function" && text.scrollWidth - box.clientWidth > 2);
    };
    measure();
    const observer = typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : null;
    observer?.observe(box);
    observer?.observe(text);
    return () => observer?.disconnect();
  }, [children]);

  // The loop: rest, then move by one copy + gap (the second copy lands where
  // the first one started, so the jump back is invisible)
  useLayoutEffect(() => {
    const track = trackRef.current;
    const text = textRef.current;
    if (!scrolling || !track || !text) return;
    const distance = text.scrollWidth + GAP_PX;
    const moveMs = (distance / PX_PER_SECOND) * 1000;
    const total = REST_MS + moveMs;
    const anim = track.animate(
      [
        { transform: "translateX(0)", offset: 0 },
        { transform: "translateX(0)", offset: REST_MS / total },
        { transform: `translateX(${-distance}px)`, offset: 1 },
      ],
      { duration: total, iterations: Infinity, easing: "linear" },
    );
    return () => anim.cancel();
  }, [scrolling, children]);

  return (
    <span ref={boxRef} className={`block min-w-0 overflow-hidden whitespace-nowrap ${scrolling ? "" : "text-ellipsis"} ${className}`}>
      <span ref={trackRef} className="inline-flex whitespace-nowrap will-change-transform">
        <span ref={textRef} className="whitespace-nowrap">
          {children}
        </span>
        {scrolling && (
          <span aria-hidden className="whitespace-nowrap" style={{ paddingLeft: GAP_PX }}>
            {children}
          </span>
        )}
      </span>
    </span>
  );
};

export default Marquee;
