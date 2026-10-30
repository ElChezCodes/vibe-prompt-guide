import React, { useEffect, useRef, useState } from "react";
import { Heart, Music } from "lucide-react";
import TensionBar, { BattleIntensity } from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import BattleStateOverlay, { OverlayMessage } from "@/components/battle/BattleStateOverlay";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { DerivedBattlePhase, getResultSide } from "@/lib/derivedBattlePhase";
import { getMoodLabel } from "@/integrations/supabase/arenas";
import { QRCodeSVG } from "qrcode.react";
import { SpotifyIcon } from "@/components/streaming/SpotifyTrackRow";
import { StageSongCredit } from "@/integrations/supabase/stageView";

interface ArenaData {
  id: string;
  name: string;
  state: string;
  mood?: string | null;
}

interface ParticipantData {
  id: string;
  is_host: boolean;
}

interface VoteData {
  song_id: string;
  status: string;
  vote_type?: string;
  preassigned?: boolean;
}

interface StageViewProps {
  arena: ArenaData;
  battle: ArenaBattleView | null;
  // Battle Room only (the shared Stage View has no viewer)
  participant?: ParticipantData;
  currentVote?: VoteData | null;
  // The viewer's passive vote (shown softer than an active vote)
  passiveVoteSongId?: string | null;
  derivedPhase: DerivedBattlePhase;
  pausedAt?: string | null;
  // Battle Room only: tapping a card votes; passed only while the backend
  // state allows voting
  onVote?: (side: "A" | "B") => void;
  // Battle Room only: the viewer's likes (step 8 signal) and the toggle
  likedSongIds?: Set<string>;
  onToggleLike?: (songId: string) => void;
  // A finished battle held on screen until the next one shows (useBattleDisplay)
  preparingNext?: boolean;
  // Shared Stage View (/a/:code/stage): who proposed each song + a QR for
  // "Open Spotify" (nobody can click a TV)
  shared?: boolean;
  credits?: { a: StageSongCredit | null; b: StageSongCredit | null } | null;
}

// Paso_2 §6.2 resolution sequence (display only, from the backend result)
const LOSER_EXIT_MS = 350;
const WINNER_MOVE_MS = 450;
const WINNER_SCALE = 1.35;
const RESULT_GLOW_MS = 1800;
const WINNER_FADE_MS = 450;
// Paso_2 §7 messages
const PHASE_MESSAGE_MS = 1600;
const RESULT_MESSAGE_MS = 2500;

const prefersReducedMotion = () => !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

const StageView = ({
  arena,
  battle,
  participant,
  currentVote,
  passiveVoteSongId = null,
  derivedPhase,
  pausedAt = null,
  onVote,
  likedSongIds,
  onToggleLike,
  preparingNext = false,
  shared = false,
  credits = null,
}: StageViewProps) => {
  const votesA = battle?.votes_a ?? 0;
  const votesB = battle?.votes_b ?? 0;
  // Passive points (step 9), already 0 in Sudden Death; the bar shows the
  // same points the backend adds up at lock-in
  const passiveA = battle?.passive_a ?? 0;
  const passiveB = battle?.passive_b ?? 0;
  const pointsA = votesA + passiveA;
  const pointsB = votesB + passiveB;
  const totalPoints = pointsA + pointsB;

  const percentageA = totalPoints > 0 ? (pointsA / totalPoints) * 100 : 50;

  const resultSide = getResultSide(battle);
  const isResolved = (derivedPhase === "RESULT" || derivedPhase === "FINISHED") && !!resultSide;
  const winnerSide = resultSide === "A" || resultSide === "B" ? resultSide : null;

  const getTensionIntensity = (): BattleIntensity => {
    if (derivedPhase === "SUDDEN_DEATH") return "sudden";
    if (derivedPhase === "FINAL_30S") return "final";
    return "normal";
  };

  const moodLabel = getMoodLabel(arena.mood);

  // --- Resolution sequence (Paso_2 §6.2): loser out by its side, winner to
  // the centre, scaled, temporary glow; at the end the winner fades out. A
  // draw keeps both cards, both glowing. Shown without motion when the view
  // opens on an already decided battle.
  const containerRef = useRef<HTMLDivElement>(null);
  const wrapARef = useRef<HTMLDivElement>(null);
  const wrapBRef = useRef<HTMLDivElement>(null);
  const vsRef = useRef<HTMLDivElement>(null);
  const openedPhaseRef = useRef(derivedPhase);
  const [glowSides, setGlowSides] = useState<"A" | "B" | "draw" | null>(null);

  useEffect(() => {
    if (!isResolved) return;
    const instant = openedPhaseRef.current === "RESULT" || openedPhaseRef.current === "FINISHED" || prefersReducedMotion();
    const wraps = { A: wrapARef.current, B: wrapBRef.current };
    const anims: Animation[] = [];

    const pose = (duration: number) => {
      if (!winnerSide) return;
      const winner = wraps[winnerSide];
      const loser = wraps[winnerSide === "A" ? "B" : "A"];
      const box = containerRef.current?.getBoundingClientRect();
      const area = containerRef.current?.parentElement?.getBoundingClientRect();
      if (!winner || !loser || !box || !area) return;
      // Measured untransformed (a resize cancels the pose first)
      const rect = winner.getBoundingClientRect();
      const dx = box.left + box.width / 2 - (rect.left + rect.width / 2);
      // Never full screen nor over the timer/bar (§6.3): stays inside the
      // cards' area
      const cy = rect.top + rect.height / 2;
      const scale = Math.max(
        1,
        Math.min(
          WINNER_SCALE,
          (box.width * 0.9) / Math.max(1, rect.width),
          (2 * Math.min(cy - area.top, area.bottom - cy)) / Math.max(1, rect.height),
        ),
      );
      anims.push(
        loser.animate([{ transform: "translateX(0)" }, { transform: `translateX(${winnerSide === "A" ? 110 : -110}vw)` }], {
          duration: duration ? LOSER_EXIT_MS : 0,
          easing: "cubic-bezier(0.55, 0, 1, 0.45)",
          fill: "forwards",
        }),
      );
      if (vsRef.current) anims.push(vsRef.current.animate([{ opacity: 1 }, { opacity: 0 }], { duration: duration ? 200 : 0, fill: "forwards" }));
      anims.push(
        winner.animate([{ transform: "translateX(0) scale(1)" }, { transform: `translateX(${dx}px) scale(${scale})` }], {
          duration,
          delay: duration ? 120 : 0,
          easing: "cubic-bezier(0.33, 1, 0.68, 1)",
          fill: "forwards",
        }),
      );
    };

    pose(instant ? 0 : WINNER_MOVE_MS);
    let glowTimer: ReturnType<typeof setTimeout> | undefined;
    if (!instant) {
      setGlowSides(resultSide);
      glowTimer = setTimeout(() => setGlowSides(null), RESULT_GLOW_MS);
    }
    const onResize = () => {
      anims.splice(0).forEach((a) => a.cancel());
      pose(0);
    };
    window.addEventListener("resize", onResize);
    return () => {
      window.removeEventListener("resize", onResize);
      if (glowTimer) clearTimeout(glowTimer);
    };
  }, [isResolved, resultSide, winnerSide]);

  // Battle over: the winner (both after a draw, both if cancelled) fades out
  useEffect(() => {
    if (derivedPhase !== "FINISHED") return;
    const instant = openedPhaseRef.current === "FINISHED";
    const targets = winnerSide ? [winnerSide === "A" ? wrapARef.current : wrapBRef.current] : [wrapARef.current, wrapBRef.current, vsRef.current];
    setGlowSides(null);
    targets.forEach((el) => el?.animate([{ opacity: 1 }, { opacity: 0 }], { duration: instant ? 0 : WINNER_FADE_MS, fill: "forwards" }));
  }, [derivedPhase, winnerSide]);

  // --- Paso_2 §7 status messages
  const winnerTitle = winnerSide === "A" ? battle?.song_a_title : winnerSide === "B" ? battle?.song_b_title : null;
  let message: OverlayMessage | null = null;
  if (preparingNext) {
    message = { key: "next", title: "PREPARING NEXT BATTLE", tone: "next", holdMs: null };
  } else if (derivedPhase === "FINAL_30S") {
    message = { key: "final", title: "FINAL DECISION", tone: "final", holdMs: PHASE_MESSAGE_MS };
  } else if (derivedPhase === "LOCK_IN" && battle?.resolution_type === "normal") {
    // Votes closed at lock-in; the result is revealed just before the end
    message = { key: "lockin", title: "VOTES LOCKED", subtitle: "Result at the end", tone: "final", holdMs: PHASE_MESSAGE_MS };
  } else if (derivedPhase === "SUDDEN_DEATH") {
    message = { key: "sudden", title: "SUDDEN DEATH", subtitle: "One final vote each", tone: "sudden", holdMs: PHASE_MESSAGE_MS };
  } else if (derivedPhase === "RESULT" && resultSide === "draw") {
    message = { key: "draw", title: "DRAW", subtitle: "Both songs play next", tone: "draw", holdMs: RESULT_MESSAGE_MS, blocking: true };
  } else if (derivedPhase === "RESULT" && winnerSide) {
    message = { key: "winner", title: "WINNER", subtitle: winnerTitle || undefined, tone: winnerSide === "A" ? "a" : "b", holdMs: RESULT_MESSAGE_MS, blocking: true };
  }

  // Voting needs the backend state; a decided battle never takes votes
  const voteHandler = (side: "A" | "B") => (onVote && !isResolved ? () => onVote(side) : undefined);

  return (
    <div className="relative min-h-dvh w-full flex flex-col space-bg overflow-hidden">
      {/* Arena ambient lighting: blue corner left, magenta corner right */}
      <div aria-hidden className="pointer-events-none absolute inset-0 arena-ambient" />

      {/* Tension Bar - Full width at top, above the cards (never covered) */}
      <div className="relative z-20 w-full pt-8 px-8">
        <TensionBar percentageA={percentageA} intensity={getTensionIntensity()} />
        {passiveA + passiveB > 0 && <VoteBreakdown votesA={votesA} votesB={votesB} passiveA={passiveA} passiveB={passiveB} />}
      </div>

      {/* Timer - Self-contained, re-renders independently. The status
          messages show over it: never over the bar or the artwork */}
      <div className="relative z-20">
        <BattleTimer battle={battle} pausedAt={pausedAt} highlight={derivedPhase === "FINAL_30S" || derivedPhase === "SUDDEN_DEATH"} />
        <BattleStateOverlay message={message} />
      </div>

      {/* Battle Arena - Song Cards with VS */}
      <div className="relative flex-1 flex items-center justify-center px-4 sm:px-8 lg:px-16">
        <div ref={containerRef} className="w-full max-w-7xl flex items-center justify-center gap-3 sm:gap-8 lg:gap-16">
          {/* Song A - Left */}
          <div ref={wrapARef} className="flex-1 min-w-0 max-w-md animate-fade-in-up">
            <StageSongCard
              position="A"
              songId={battle?.song_a_id ?? ""}
              songTitle={battle?.song_a_title ?? ""}
              artistName={battle?.song_a_artist ?? ""}
              artworkUrl={battle?.song_a_artwork_url}
              source={battle?.song_a_source}
              trackId={battle?.song_a_spotify_track_id}
              currentVote={currentVote}
              passiveVoteSongId={passiveVoteSongId}
              tag={moodLabel}
              isWinner={isResolved && (resultSide === "A" || resultSide === "draw")}
              glowing={glowSides === "A" || glowSides === "draw"}
              onVote={voteHandler("A")}
              isLiked={!!battle?.song_a_id && !!likedSongIds?.has(battle.song_a_id)}
              onToggleLike={onToggleLike && battle?.song_a_id ? () => onToggleLike(battle.song_a_id) : undefined}
              shared={shared}
              credit={credits?.a}
            />
          </div>

          {/* VS Emblem */}
          <div ref={vsRef} className="flex-shrink-0 animate-fade-in" style={{ animationDelay: "150ms" }}>
            <div className="vs-emblem w-12 h-12 sm:w-16 sm:h-16 lg:w-24 lg:h-24 rounded-full flex items-center justify-center">
              <span className="text-lg sm:text-2xl lg:text-4xl font-arcade font-black tracking-wider vs-text">VS</span>
            </div>
          </div>

          {/* Song B - Right */}
          <div ref={wrapBRef} className="flex-1 min-w-0 max-w-md animate-fade-in-up" style={{ animationDelay: "100ms" }}>
            <StageSongCard
              position="B"
              songId={battle?.song_b_id ?? ""}
              songTitle={battle?.song_b_title ?? ""}
              artistName={battle?.song_b_artist ?? ""}
              artworkUrl={battle?.song_b_artwork_url}
              source={battle?.song_b_source}
              trackId={battle?.song_b_spotify_track_id}
              currentVote={currentVote}
              passiveVoteSongId={passiveVoteSongId}
              tag={moodLabel}
              isWinner={isResolved && (resultSide === "B" || resultSide === "draw")}
              glowing={glowSides === "B" || glowSides === "draw"}
              onVote={voteHandler("B")}
              isLiked={!!battle?.song_b_id && !!likedSongIds?.has(battle.song_b_id)}
              onToggleLike={onToggleLike && battle?.song_b_id ? () => onToggleLike(battle.song_b_id) : undefined}
              shared={shared}
              credit={credits?.b}
            />
          </div>
        </div>
      </div>

      {/* Bottom balance spacer, carries arena name + mood */}
      <div className="h-16 lg:h-24 flex items-center justify-center">
        <p className="text-sm lg:text-base text-muted-foreground">
          {arena.name}
          {getMoodLabel(arena.mood) && <span> · {getMoodLabel(arena.mood)}</span>}
        </p>
      </div>

    </div>
  );
};

// Footer under each card (the square above it is the vote button), so "Open
// Spotify" and the like stay their own taps; a minimum height keeps both
// cards' squares level
const STAGE_CARD_FOOTER_CLASS = "min-h-16 lg:min-h-24";

const formatPoints = (n: number) => (Math.round(n * 100) / 100).toString();

// Explicit votes + passive points per side, shown once passive points exist
// (the 30-s ramp before lock-in, then the passive votes cast at lock-in)
const VoteBreakdown = ({ votesA, votesB, passiveA, passiveB }: {
  votesA: number;
  votesB: number;
  passiveA: number;
  passiveB: number;
}) => (
  <div className="mt-1 flex justify-between text-[10px] lg:text-xs text-text-secondary">
    <span className="text-song-a">
      {votesA} {votesA === 1 ? "vote" : "votes"} + {formatPoints(passiveA)} passive
    </span>
    <span className="text-song-b">
      {votesB} {votesB === 1 ? "vote" : "votes"} + {formatPoints(passiveB)} passive
    </span>
  </div>
);

// With Spotify artwork the square is the artwork alone (Spotify: artwork
// uncropped and never covered), so title/artist move here, next to the
// Spotify logo and the "Open Spotify" link back (Developer Policy II.4).
// Curated-library songs (placeholder ids, no artwork) keep the text inside
// the card and get no link.
const StageCardFooter = ({ source, trackId, songTitle, artistName, showInfo, isSelected, isPreassigned, isPassive, isA, isLiked, onToggleLike, shared, credit }: {
  source?: string;
  trackId?: string;
  songTitle: string;
  artistName: string;
  showInfo: boolean;
  isSelected: boolean;
  isPreassigned?: boolean;
  isPassive?: boolean;
  isA: boolean;
  isLiked?: boolean;
  onToggleLike?: () => void;
  shared?: boolean;
  credit?: StageSongCredit | null;
}) => (
  <div className={`${shared ? "" : STAGE_CARD_FOOTER_CLASS} pt-2 flex flex-col items-center justify-start min-w-0 text-center`}>
    {showInfo && (
      <>
        <p className="w-full text-sm lg:text-2xl font-semibold text-foreground truncate">{songTitle || "—"}</p>
        <p className="w-full text-xs lg:text-lg text-text-secondary truncate">{artistName}</p>
      </>
    )}
    {shared && showInfo && credit !== undefined && <SongCreditLine credit={credit} isA={isA} />}
    <div className="mt-0.5 flex flex-wrap items-center justify-center gap-x-2 gap-y-0.5">
      {shared && source === "spotify" && trackId && (
        // Black on white with a quiet zone so phones read it
        <div className="bg-white rounded p-1" aria-hidden>
          <QRCodeSVG value={`https://open.spotify.com/track/${trackId}`} size={56} marginSize={1} />
        </div>
      )}
      {source === "spotify" && trackId && (
        <a
          href={`https://open.spotify.com/track/${trackId}`}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-1 whitespace-nowrap text-[10px] lg:text-xs font-bold uppercase tracking-wide text-[#1DB954]"
          aria-label={shared ? "Open Spotify" : undefined}
        >
          <SpotifyIcon className={shared ? "h-5 w-5 lg:h-6 lg:w-6" : "h-3.5 w-3.5"} />
          {!shared && "Open Spotify"}
        </a>
      )}
      {showInfo && isSelected && (
        <span className={`whitespace-nowrap text-[10px] lg:text-xs font-bold uppercase ${isA ? "text-song-a" : "text-song-b"}`}>{isPreassigned ? "Your pre-assigned vote" : "Your vote"}</span>
      )}
      {showInfo && isPassive && (
        <span className={`whitespace-nowrap text-[10px] lg:text-xs font-semibold uppercase opacity-80 ${isA ? "text-song-a" : "text-song-b"}`}>Your passive vote</span>
      )}
      {onToggleLike && (
        <button
          type="button"
          onClick={onToggleLike}
          aria-pressed={!!isLiked}
          aria-label={isLiked ? "Unlike song" : "Like song"}
          className="flex items-center gap-1 text-[10px] lg:text-xs font-bold uppercase tracking-wide text-text-secondary"
        >
          <Heart className={`h-3.5 w-3.5 ${isLiked ? (isA ? "fill-song-a text-song-a" : "fill-song-b text-song-b") : ""}`} />
          {isLiked ? "Liked" : "Like"}
        </button>
      )}
    </div>
  </div>
);

// Shared Stage View: MF nickname + arena PI of the proposer (step 16), never
// a Spotify name; system songs (and lent Liked Songs) stay anonymous
const SongCreditLine = ({ credit, isA }: { credit: StageSongCredit | null; isA: boolean }) => (
  <p className="w-full text-xs lg:text-base text-text-secondary truncate">
    {credit?.proposer ? (
      <>
        Proposed by <span className={`font-semibold ${isA ? "text-song-a" : "text-song-b"}`}>{credit.proposer}</span>
        <span> · {credit.pi} PI</span>
      </>
    ) : (
      "Picked by Music Fighter"
    )}
    {credit?.backers > 0 && <span> · +{credit.backers} backed it</span>}
  </p>
);

// Stage-optimized Song Card (read-only, larger text)
interface StageSongCardProps {
  position: "A" | "B";
  songId: string;
  songTitle: string;
  artistName: string;
  artworkUrl?: string | null;
  source?: string;
  trackId?: string;
  currentVote?: VoteData | null;
  passiveVoteSongId?: string | null;
  tag?: string | null;
  isWinner?: boolean;
  // Temporary result glow (Paso_2 §6.2)
  glowing?: boolean;
  onVote?: () => void;
  isLiked?: boolean;
  onToggleLike?: () => void;
  shared?: boolean;
  credit?: StageSongCredit | null;
}

const StageSongCard = ({ position, songId, songTitle, artistName, artworkUrl, source, trackId, currentVote, passiveVoteSongId, tag, isWinner, glowing, onVote, isLiked, onToggleLike, shared, credit }: StageSongCardProps) => {
  const isA = position === "A";

  // Determine selection by comparing songId against currentVote (a passive
  // vote row, after lock-in, shows like the passive preview: softer)
  const isSelected = currentVote?.status === "active" && currentVote?.vote_type !== "passive" && currentVote?.song_id === songId;
  const isPassive = !isSelected && !isWinner && !!songId && passiveVoteSongId === songId;
  // Step 14: cast for them because they backed this song, until they touch it
  const isPreassigned = isSelected && !!currentVote?.preassigned;
  const lit = isSelected || isWinner;

  // Paso_2 §6.1: brief glow when the vote lands on this card
  const squareRef = useRef<HTMLDivElement>(null);
  const wasSelectedRef = useRef(isSelected);
  useEffect(() => {
    if (isSelected && !wasSelectedRef.current && !prefersReducedMotion()) {
      squareRef.current?.animate(
        [{ filter: "brightness(1.6)", transform: "scale(1.05)" }, { filter: "brightness(1)", transform: "scale(1.02)" }],
        { duration: 320, easing: "cubic-bezier(0.33, 1, 0.68, 1)" },
      );
    }
    wasSelectedRef.current = isSelected;
  }, [isSelected]);

  return (
    <>
      <div
        ref={squareRef}
        onClick={onVote}
        onKeyDown={onVote ? (e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), onVote()) : undefined}
        role={onVote ? "button" : undefined}
        tabIndex={onVote ? 0 : undefined}
        aria-label={onVote ? `Vote for ${songTitle || (isA ? "song A" : "song B")}` : undefined}
        className={`
          relative w-full aspect-square rounded-2xl overflow-hidden
          bg-secondary border-2 transition-all duration-300 ease-out
          ${onVote ? "cursor-pointer active:scale-[0.98] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-foreground" : ""}
          ${isA ? "border-song-a/40" : "border-song-b/40"}
          ${lit ? (isA ? "border-song-a scale-[1.02]" : "border-song-b scale-[1.02]") : ""}
          ${(isSelected && !isWinner) || glowing ? (isA ? "glow-a" : "glow-b") : ""}
          ${isPassive ? (isA ? "border-song-a/70 glow-a-soft" : "border-song-b/70 glow-b-soft") : ""}
        `}
      >
        {artworkUrl ? (
          // Spotify artwork: the whole square, object-contain, nothing on top
          <img src={artworkUrl} alt="" className="absolute inset-0 w-full h-full object-contain bg-black" />
        ) : (
          <>
            {/* Artwork placeholder: side-tinted gradient + music glyph */}
            <div
              className={`absolute inset-0 bg-gradient-to-b ${isA ? "from-song-a/25" : "from-song-b/25"} via-secondary to-background`}
            />
            <div className="absolute inset-0 flex items-center justify-center pb-16">
              <Music className={`w-16 h-16 lg:w-24 lg:h-24 opacity-40 ${isA ? "text-song-a" : "text-song-b"}`} />
            </div>

            {/* Top pill: mood / genre */}
            <div className="absolute top-3 inset-x-3 flex items-center justify-between">
              <span
                className={`px-2.5 py-1 rounded-full text-[10px] lg:text-xs font-semibold uppercase tracking-wider border bg-background/70 backdrop-blur ${
                  isA ? "text-song-a border-song-a/40" : "text-song-b border-song-b/40"
                }`}
              >
                {tag || (isA ? "Blue corner" : "Pink corner")}
              </span>
              {isSelected && (
                <span
                  className={`px-2 py-1 rounded-full text-[10px] lg:text-xs font-bold uppercase tracking-wider ${
                    isA ? "bg-song-a text-song-a-foreground" : "bg-song-b text-song-b-foreground"
                  }`}
                >
                  {isPreassigned ? "Your pre-assigned vote" : "Your vote"}
                </span>
              )}
              {isPassive && (
                <span
                  className={`px-2 py-1 rounded-full text-[10px] lg:text-xs font-semibold uppercase tracking-wider border bg-background/70 ${
                    isA ? "text-song-a border-song-a/60" : "text-song-b border-song-b/60"
                  }`}
                >
                  Your passive vote
                </span>
              )}
            </div>

            {/* Song info */}
            <div className="absolute inset-x-0 bottom-0 p-4 lg:p-8 bg-gradient-to-t from-background via-background/80 to-transparent">
              <h3 className="text-xl lg:text-4xl font-semibold text-foreground truncate">{songTitle || "—"}</h3>
              <p className="text-sm lg:text-2xl text-text-secondary truncate mt-1">{artistName}</p>
              <div className={`mt-3 h-1 w-12 rounded-full ${isA ? "bg-song-a" : "bg-song-b"}`} />
            </div>
          </>
        )}
      </div>
      <StageCardFooter
        source={source}
        trackId={trackId}
        songTitle={songTitle}
        artistName={artistName}
        showInfo={!!artworkUrl}
        isSelected={isSelected}
        isPreassigned={isPreassigned}
        isPassive={isPassive}
        isA={isA}
        isLiked={isLiked}
        onToggleLike={onToggleLike}
        shared={shared}
        credit={credit}
      />
    </>
  );
};

export default React.memo(StageView);
