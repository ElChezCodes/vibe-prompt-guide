import React from "react";
import TensionBar, { BattleIntensity } from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import BattleStateOverlay from "@/components/battle/BattleStateOverlay";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { getMoodLabel } from "@/integrations/supabase/arenas";

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
}

const StageView = ({ arena, battle, participant, currentVote, derivedPhase }: StageViewProps) => {
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
    <div className="relative min-h-dvh w-full flex flex-col bg-background overflow-hidden">
      {/* Arena ambient lighting: blue corner left, magenta corner right */}
      <div aria-hidden className="pointer-events-none absolute inset-0 arena-ambient" />

      {/* Tension Bar - Full width at top */}
      <div className="relative w-full pt-8 px-8">
        <TensionBar percentageA={percentageA} percentageB={percentageB} intensity={getTensionIntensity()} />
      </div>

      {/* Timer - Self-contained, re-renders independently */}
      <BattleTimer battle={battle} />

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
          <div className="px-6 py-3 rounded-xl bg-black/70 text-white text-2xl font-bold tracking-widest">LOCK IN</div>
        </div>
      )}

      {derivedPhase === "SUDDEN_DEATH" && (
        <div className="absolute inset-0 z-40 flex items-center justify-center pointer-events-none">
          <div className="px-6 py-3 rounded-xl bg-gradient-to-r from-song-a/80 to-song-b/80 text-white text-2xl font-arcade font-black tracking-widest animate-pulse">
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

// Stage-optimized Song Card (read-only, larger text)
interface StageSongCardProps {
  position: "A" | "B";
  songId: string;
  songTitle: string;
  artistName: string;
  currentVote?: VoteData | null;
}

const StageSongCard = ({ position, songId, songTitle, artistName, currentVote }: StageSongCardProps) => {
  const isA = position === "A";

  // Determine selection by comparing songId against currentVote
  const isSelected = currentVote?.status === "active" && currentVote?.song_id === songId;

  return (
    <div
      className={`
        relative w-full aspect-square rounded-2xl overflow-hidden
        bg-surface border-2 transition-all duration-200
        ${isA ? "border-song-a/30" : "border-song-b/30"}
        ${isSelected ? (isA ? "border-song-a ring-2 ring-song-a/50" : "border-song-b ring-2 ring-song-b/50") : ""}
      `}
    >
      {/* Album art placeholder */}
      <div className="absolute inset-0 bg-gradient-to-br from-secondary/50 to-background/50" />

      {/* Song info overlay */}
      <div className="absolute inset-0 flex flex-col items-center justify-end p-6 lg:p-8">
        <div
          className={`
          w-full text-center
          ${isA ? "text-song-a" : "text-song-b"}
        `}
        >
          <h3 className="text-2xl lg:text-4xl font-bold truncate mb-2">{songTitle}</h3>
          <p className="text-lg lg:text-2xl text-muted-foreground truncate">{artistName}</p>
        </div>
      </div>

      {/* Side indicator glow */}
      <div
        className={`
        absolute inset-0 pointer-events-none
        ${isA ? "shadow-[inset_0_0_60px_rgba(59,130,246,0.1)]" : "shadow-[inset_0_0_60px_rgba(236,72,153,0.1)]"}
      `}
      />
    </div>
  );
};

export default React.memo(StageView);
