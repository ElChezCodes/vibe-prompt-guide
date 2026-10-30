import { useLayoutEffect, useRef } from "react";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import { NextUpSong } from "@/integrations/supabase/proposals";

// Reordering slide (FLIP) and entrance of new songs
const MOVE_MS = 600;
const ENTER_MS = 400;
const EASE_OUT = "cubic-bezier(0.22, 1, 0.36, 1)";

const timeLabel = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

const detail = (song: NextUpSong): string => {
  if (song.available_at) return `Can play again at ${timeLabel(song.available_at)}`;
  const parts: string[] = [];
  if (song.pair_no === 1) parts.push(song.vs_system ? "Next battle · vs a song picked by the system" : "Next battle");
  if (song.is_mine) parts.push("Your song");
  return parts.join(" · ");
};

/**
 * Step 17: the next 10 songs in the order matchmaking would send them to
 * fight (style continuity with the music playing, fair turns). Read-only.
 * When the order changes, the numbers 1-10 stay as fixed places and each song
 * slides from its old place to its new one, so it shows which songs went up
 * or down and where they are now; new songs fade in.
 */
const NextUpList = ({ songs }: { songs: NextUpSong[] }) => {
  const rows = useRef(new Map<string, HTMLLIElement>());
  const lastTops = useRef(new Map<string, number>());

  // FLIP: after React moved the rows, start each song at its old offset and
  // animate it to its new place (the place number doesn't move)
  useLayoutEffect(() => {
    const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const hadRows = lastTops.current.size > 0;
    const tops = new Map<string, number>();
    rows.current.forEach((li, id) => {
      const top = li.offsetTop;
      tops.set(id, top);
      const el = li.querySelector<HTMLElement>("[data-slide]");
      if (!el || reduceMotion || typeof el.animate !== "function") return;
      const before = lastTops.current.get(id);
      if (before === undefined) {
        if (hadRows) {
          el.animate([{ opacity: 0, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }], {
            duration: ENTER_MS,
            easing: EASE_OUT,
          });
        }
        return;
      }
      const delta = before - top;
      if (delta !== 0) {
        el.animate([{ transform: `translateY(${delta}px)` }, { transform: "none" }], {
          duration: MOVE_MS,
          easing: EASE_OUT,
        });
      }
    });
    lastTops.current = tops;
  }, [songs]);

  return (
    <div>
      <p className="neon-label mb-3">Next up to fight</p>
      <ol className="relative space-y-2 pr-4">
        {songs.map((song) => {
          const label = detail(song);
          return (
            <li
              key={song.song_id}
              ref={(el) => {
                if (el) rows.current.set(song.song_id, el);
                else rows.current.delete(song.song_id);
              }}
              className="relative flex items-center gap-2"
            >
              <span
                className={`w-6 flex-shrink-0 text-center text-sm font-bold tabular-nums ${
                  song.pair_no === 1 ? "text-song-a" : "text-muted-foreground"
                }`}
              >
                {song.pos}
              </span>
              <div data-slide className="relative flex-1 min-w-0">
                <SpotifyTrackRow
                  track={{ ...song, spotify_url: `https://open.spotify.com/track/${song.spotify_track_id}` }}
                  details={label ? <p className="text-xs text-song-a truncate">{label}</p> : undefined}
                />
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
};

export default NextUpList;
