import React from "react";
import { Music } from "lucide-react";
import TensionBar, { BattleIntensity } from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import BattleStateOverlay from "@/components/battle/BattleStateOverlay";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { getMoodLabel } from "@/integrations/supabase/arenas";
import { SpotifyIcon } from "@/components/streaming/SpotifyTrackRow";

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
}

interface StageViewProps {
  arena: ArenaData;
  battle: ArenaBattleView | null;
  participant: ParticipantData;
  currentVote?: VoteData | null;
  derivedPhase: "NORMAL" | "FINAL_30S" | "LOCK_IN" | "SUDDEN_DEATH" | "FINISHED";
  pausedAt?: string | null;
}

const StageView = ({ arena, battle, participant, currentVote, derivedPhase, pausedAt = null }: StageViewProps) => {
  console.log("[StageView Render]", {
    battle_id: battle?.battle_id,
    state: battle?.state,
    derivedPhase,
    timestamp: Date.now(),
  });
  const votesA = battle?.votes_a ?? 0;
  const votesB = battle?.votes_b ?? 0;
  const totalVotes = votesA + votesB;

  const percentageA =
    totalVotes > 0 ? Math.round((votesA / totalVotes) * 100) : 50;

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
              tag={moodLabel}
              isWinner={derivedPhase === "FINISHED" && winnerSide === "A"}
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
              tag={moodLabel}
              isWinner={derivedPhase === "FINISHED" && winnerSide === "B"}
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

// With Spotify artwork the square is the artwork alone (Spotify: artwork
// uncropped and never covered), so title/artist move here, next to the
// Spotify logo and the "Open Spotify" link back (Developer Policy II.4).
// Curated-library songs (placeholder ids, no artwork) keep the text inside
// the card and get no link.
const StageCardFooter = ({ source, trackId, songTitle, artistName, showInfo, isSelected, isA }: {
  source?: string;
  trackId?: string;
  songTitle: string;
  artistName: string;
  showInfo: boolean;
  isSelected: boolean;
  isA: boolean;
}) => (
  <div className={`${STAGE_CARD_FOOTER_CLASS} pt-2 flex flex-col items-center justify-start min-w-0 text-center`}>
    {showInfo && (
      <>
        <p className="w-full text-sm lg:text-2xl font-semibold text-foreground truncate">{songTitle || "—"}</p>
        <p className="w-full text-xs lg:text-lg text-text-secondary truncate">{artistName}</p>
      </>
    )}
    <div className="mt-0.5 flex items-center gap-2">
      {source === "spotify" && trackId && (
        <a
          href={`https://open.spotify.com/track/${trackId}`}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-1 text-[10px] lg:text-xs font-bold uppercase tracking-wide text-[#1DB954]"
        >
          <SpotifyIcon className="h-3.5 w-3.5" />
          Open Spotify
        </a>
      )}
      {showInfo && isSelected && (
        <span className={`text-[10px] lg:text-xs font-bold uppercase ${isA ? "text-song-a" : "text-song-b"}`}>Your vote</span>
      )}
    </div>
  </div>
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
  tag?: string | null;
  isWinner?: boolean;
}

const StageSongCard = ({ position, songId, songTitle, artistName, artworkUrl, source, trackId, currentVote, tag, isWinner }: StageSongCardProps) => {
  const isA = position === "A";

  // Determine selection by comparing songId against currentVote
  const isSelected = currentVote?.status === "active" && currentVote?.song_id === songId;
  const lit = isSelected || isWinner;

  return (
    <>
      <div
        className={`
          relative w-full aspect-square rounded-2xl overflow-hidden
          bg-secondary border-2 transition-all duration-300 ease-out
          ${isA ? "border-song-a/40" : "border-song-b/40"}
          ${lit ? (isA ? "border-song-a glow-a scale-[1.02]" : "border-song-b glow-b scale-[1.02]") : ""}
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
                  Your vote
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
        isA={isA}
      />
    </>
  );
};

export default React.memo(StageView);
