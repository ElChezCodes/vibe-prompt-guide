import { useLayoutEffect, useRef } from "react";
import { ThumbsUp } from "lucide-react";
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
  if (song.pair_no === 1) parts.push("Next battle");
  else if (song.pair_no) parts.push(`Battle ${song.pair_no}`);
  if (song.is_system) parts.push(song.pair_no === 1 ? "Picked by Music Fighter" : "Music Fighter's pick, may change");
  if (song.is_mine) parts.push("Your pick");
  return parts.join(" · ");
};

/**
 * Step 17: the next 10 songs in the order matchmaking would send them to
 * fight (style continuity with the music playing, fair turns). Read-only.
 * Step 20: also the system songs that fill the next 5 battles, marked.
 * When the order changes, the numbers 1-10 stay as fixed places and each song
 * slides from its old place to its new one, so it shows which songs went up
 * or down and where they are now; new songs fade in.
 * 2026-11-06: votes. onToggleVote only where the viewer can vote (not the
 * Stage View); the list shows the backend's count, it decides nothing.
 */
const NextUpList = ({
  songs,
  logoLink = false,
  onToggleVote,
  votingSongId = null,
}: {
  songs: NextUpSong[];
  logoLink?: boolean;
  onToggleVote?: (song: NextUpSong) => void;
  votingSongId?: string | null;
}) => {
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
      <div className="mb-3 flex items-baseline justify-between gap-2">
        <p className="neon-label">Next up to fight</p>
        {onToggleVote && songs.length > 0 && (
          <p className="text-xs text-muted-foreground">
            {songs[0].votes_left} {songs[0].votes_left === 1 ? "vote" : "votes"} left
          </p>
        )}
      </div>
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
                  details={
                    label ? (
                      <p className={`text-xs truncate ${song.is_system ? "text-muted-foreground" : "text-song-a"}`}>{label}</p>
                    ) : undefined
                  }
                  logoLink={logoLink}
                  // Above the Spotify link: beside it there is no room for the title
                  stackAction
                  action={<VoteControl song={song} onToggleVote={onToggleVote} busy={votingSongId === song.song_id} />}
                />
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
};

// The count, and the vote button unless it is their own proposal (it already
// carries their one vote) or a song they can't vote
const VoteControl = ({
  song,
  onToggleVote,
  busy,
}: {
  song: NextUpSong;
  onToggleVote?: (song: NextUpSong) => void;
  busy: boolean;
}) => {
  const count = <span className="tabular-nums">{song.votes}</span>;
  if (!onToggleVote || !song.votable) {
    if (song.votes === 0) return null;
    return (
      <span className="flex-shrink-0 inline-flex items-center gap-1 px-1 text-xs font-semibold text-muted-foreground">
        <ThumbsUp className="h-3.5 w-3.5" />
        {count}
      </span>
    );
  }
  const noneLeft = !song.my_vote && song.votes_left <= 0;
  return (
    <button
      type="button"
      onClick={() => onToggleVote(song)}
      disabled={busy || noneLeft}
      aria-pressed={song.my_vote}
      aria-label={song.my_vote ? `Remove your vote for ${song.title}` : `Vote for ${song.title}`}
      className={`flex-shrink-0 inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-semibold transition-colors disabled:opacity-40 ${
        song.my_vote ? "bg-song-a text-song-a-foreground" : "hud-chip text-foreground"
      }`}
    >
      <ThumbsUp className="h-3.5 w-3.5" />
      {count}
    </button>
  );
};

export default NextUpList;
