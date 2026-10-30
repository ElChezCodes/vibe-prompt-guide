import React from "react";
import { Heart, Music } from "lucide-react";
import TensionBar, { BattleIntensity } from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import BattleStateOverlay from "@/components/battle/BattleStateOverlay";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";
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
  derivedPhase: "NORMAL" | "FINAL_30S" | "LOCK_IN" | "SUDDEN_DEATH" | "FINISHED";
  pausedAt?: string | null;
  // Battle Room only: the viewer's likes (step 8 signal) and the toggle
  likedSongIds?: Set<string>;
  onToggleLike?: (songId: string) => void;
  // Shared Stage View (/a/:code/stage): who proposed each song + a QR for
  // "Open Spotify" (nobody can click a TV)
  shared?: boolean;
  credits?: { a: StageSongCredit | null; b: StageSongCredit | null } | null;
}

const StageView = ({
  arena,
  battle,
  participant,
  currentVote,
  passiveVoteSongId = null,
  derivedPhase,
  pausedAt = null,
  likedSongIds,
  onToggleLike,
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

  const percentageA =
    totalPoints > 0 ? Math.round((pointsA / totalPoints) * 100) : 50;

  const percentageB = 100 - percentageA;

  const winnerSide =
    battle?.winner_song_id === battle?.song_a_id
      ? "A"
      : battle?.winner_song_id === battle?.song_b_id
        ? "B"
        : null;

  const getTensionIntensity = (): BattleIntensity => {
    if (derivedPhase === "FINAL_30S" || derivedPhase === "LOCK_IN" || derivedPhase === "SUDDEN_DEATH") {
      return "final";
    }
    return "normal";
  };

  const moodLabel = getMoodLabel(arena.mood);

  return (
    <div className="relative min-h-dvh w-full flex flex-col space-bg overflow-hidden">
      {/* Arena ambient lighting: blue corner left, magenta corner right */}
      <div aria-hidden className="pointer-events-none absolute inset-0 arena-ambient" />

      {/* Tension Bar - Full width at top */}
      <div className="relative w-full pt-8 px-8">
        <TensionBar percentageA={percentageA} percentageB={percentageB} intensity={getTensionIntensity()} />
        {passiveA + passiveB > 0 && <VoteBreakdown votesA={votesA} votesB={votesB} passiveA={passiveA} passiveB={passiveB} />}
      </div>

      {/* Timer - Self-contained, re-renders independently */}
      <BattleTimer battle={battle} pausedAt={pausedAt} />

      {/* Battle Arena - Song Cards with VS */}
      <div className="relative flex-1 flex items-center justify-center px-8 lg:px-16">
        <div className="w-full max-w-7xl flex items-center justify-center gap-8 lg:gap-16">
          {/* Song A - Left */}
          <div className="flex-1 max-w-md animate-fade-in-up">
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
              isWinner={derivedPhase === "FINISHED" && winnerSide === "A"}
              isLiked={!!battle?.song_a_id && !!likedSongIds?.has(battle.song_a_id)}
              onToggleLike={onToggleLike && battle?.song_a_id ? () => onToggleLike(battle.song_a_id) : undefined}
              shared={shared}
              credit={credits?.a}
            />
          </div>

          {/* VS Emblem */}
          <div className="flex-shrink-0 animate-fade-in" style={{ animationDelay: "150ms" }}>
            <div className="vs-emblem w-16 h-16 lg:w-24 lg:h-24 rounded-full flex items-center justify-center">
              <span className="text-2xl lg:text-4xl font-arcade font-black tracking-wider vs-text">VS</span>
            </div>
          </div>

          {/* Song B - Right */}
          <div className="flex-1 max-w-md animate-fade-in-up" style={{ animationDelay: "100ms" }}>
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
              isWinner={derivedPhase === "FINISHED" && winnerSide === "B"}
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

      {derivedPhase === "LOCK_IN" && (
        <div className="absolute inset-0 z-40 flex items-center justify-center pointer-events-none">
          <div className="px-6 py-3 rounded-xl neon-panel text-energy-yellow text-2xl font-arcade font-black tracking-widest">LOCK IN</div>
        </div>
      )}

      {derivedPhase === "SUDDEN_DEATH" && (
        <div className="absolute inset-0 z-40 flex items-center justify-center pointer-events-none">
          <div className="px-6 py-3 rounded-xl bg-gradient-to-r from-song-a/80 to-song-b/80 text-foreground text-2xl font-arcade font-black tracking-widest animate-pulse">
            SUDDEN DEATH
          </div>
        </div>
      )}

      {/* Battle State Overlay */}
      <BattleStateOverlay
        battleState={
          derivedPhase === "FINISHED"
            ? "FINISHED"
            : derivedPhase === "SUDDEN_DEATH"
              ? "FINAL_30S"
              : derivedPhase === "FINAL_30S" || derivedPhase === "LOCK_IN"
                ? "FINAL_30S"
                : "NORMAL"
        }
        winnerSide={winnerSide}
      />
    </div>
  );
};

// Fixed-height footer under each card. The Battle Room's vote hit areas are
// the card's square plus a gap of this same height (STAGE_CARD_FOOTER_CLASS,
// pointer-events off), so the "Open Spotify" link stays clickable.
export const STAGE_CARD_FOOTER_CLASS = "h-16 lg:h-24";

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
    <div className="mt-0.5 flex items-center gap-2">
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
          className="flex items-center gap-1 text-[10px] lg:text-xs font-bold uppercase tracking-wide text-[#1DB954]"
          aria-label={shared ? "Open Spotify" : undefined}
        >
          <SpotifyIcon className={shared ? "h-5 w-5 lg:h-6 lg:w-6" : "h-3.5 w-3.5"} />
          {!shared && "Open Spotify"}
        </a>
      )}
      {showInfo && isSelected && (
        <span className={`text-[10px] lg:text-xs font-bold uppercase ${isA ? "text-song-a" : "text-song-b"}`}>{isPreassigned ? "Your pre-assigned vote" : "Your vote"}</span>
      )}
      {showInfo && isPassive && (
        <span className={`text-[10px] lg:text-xs font-semibold uppercase opacity-80 ${isA ? "text-song-a" : "text-song-b"}`}>Your passive vote</span>
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
  isLiked?: boolean;
  onToggleLike?: () => void;
  shared?: boolean;
  credit?: StageSongCredit | null;
}

const StageSongCard = ({ position, songId, songTitle, artistName, artworkUrl, source, trackId, currentVote, passiveVoteSongId, tag, isWinner, isLiked, onToggleLike, shared, credit }: StageSongCardProps) => {
  const isA = position === "A";

  // Determine selection by comparing songId against currentVote (a passive
  // vote row, after lock-in, shows like the passive preview: softer)
  const isSelected = currentVote?.status === "active" && currentVote?.vote_type !== "passive" && currentVote?.song_id === songId;
  const isPassive = !isSelected && !isWinner && !!songId && passiveVoteSongId === songId;
  // Step 14: cast for them because they backed this song, until they touch it
  const isPreassigned = isSelected && !!currentVote?.preassigned;
  const lit = isSelected || isWinner;

  return (
    <>
      <div
        className={`
          relative w-full aspect-square rounded-2xl overflow-hidden
          bg-secondary border-2 transition-all duration-300 ease-out
          ${isA ? "border-song-a/40" : "border-song-b/40"}
          ${lit ? (isA ? "border-song-a glow-a scale-[1.02]" : "border-song-b glow-b scale-[1.02]") : ""}
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
