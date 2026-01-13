import TensionBar, { BattleIntensity } from "@/components/battle/TensionBar";
import BattleStateOverlay, { BattleState } from "@/components/battle/BattleStateOverlay";

interface ArenaData {
  id: string;
  name: string;
  state: string;
}

interface ParticipantData {
  id: string;
  is_host: boolean;
}

interface BattleData {
  id: string;
  state: string;
  song_a_id: string;
  song_b_id: string;
}

interface VoteData {
  song_id: string;
  status: string;
}

type DerivedBattlePhase = "NORMAL" | "FINAL_30S" | "LOCK_IN" | "FINISHED";

interface StageViewProps {
  arena: ArenaData;
  battle: BattleData | null;
  participant: ParticipantData;
  currentVote?: VoteData | null;
  timer: string;
  derivedPhase: DerivedBattlePhase;
}

const StageView = ({ arena, battle, participant, currentVote, timer, derivedPhase }: StageViewProps) => {
  // Placeholder values - will be connected to real data later
  const percentageA = 52;
  const percentageB = 48;
  const winnerSide: 'A' | 'B' | null = null;

  const getBattleState = (): BattleState => {
    if (!battle) return 'INIT';
    if (derivedPhase === 'FINISHED') return 'FINISHED';
    if (derivedPhase === 'FINAL_30S' || derivedPhase === 'LOCK_IN') return 'FINAL_30S';
    switch (battle.state) {
      case 'pending': return 'INIT';
      default: return 'NORMAL';
    }
  };

  const getTensionIntensity = (): BattleIntensity => {
    if (derivedPhase === 'FINAL_30S' || derivedPhase === 'LOCK_IN') return 'final';
    return 'normal';
  };

  return (
    <div className="min-h-dvh w-full flex flex-col bg-background overflow-hidden">
      {/* Tension Bar - Full width at top */}
      <div className="w-full pt-8 px-8">
        <TensionBar 
          percentageA={percentageA} 
          percentageB={percentageB}
          intensity={getTensionIntensity()}
        />
      </div>

      {/* Timer - Prominent center */}
      <div className="py-8">
        <div className="flex items-center justify-center">
          <span className="text-6xl lg:text-8xl font-semibold text-foreground tracking-widest tabular-nums">
            {timer}
          </span>
        </div>
      </div>

      {/* Battle Arena - Song Cards with VS */}
      <div className="flex-1 flex items-center justify-center px-8 lg:px-16">
        <div className="w-full max-w-7xl flex items-center justify-center gap-8 lg:gap-16">
          {/* Song A - Left */}
          <div className="flex-1 max-w-md animate-fade-in-up">
            <StageSongCard 
              position="A"
              songId={battle?.song_a_id ?? ''}
              songTitle="Blinding Lights"
              artistName="The Weeknd"
              currentVote={currentVote}
            />
          </div>

          {/* VS Indicator */}
          <div className="flex-shrink-0 animate-fade-in" style={{ animationDelay: '150ms' }}>
            <span className="text-4xl lg:text-6xl font-arcade font-black text-muted-foreground tracking-wider">
              VS
            </span>
          </div>

          {/* Song B - Right */}
          <div className="flex-1 max-w-md animate-fade-in-up" style={{ animationDelay: '100ms' }}>
            <StageSongCard 
              position="B"
              songId={battle?.song_b_id ?? ''}
              songTitle="Levitating"
              artistName="Dua Lipa"
              currentVote={currentVote}
            />
          </div>
        </div>
      </div>

      {/* Spacer for bottom balance */}
      <div className="h-16 lg:h-24" />

      {/* Battle State Overlay */}
      <BattleStateOverlay battleState={getBattleState()} winnerSide={winnerSide} />
    </div>
  );
};

// Stage-optimized Song Card (read-only, larger text)
interface StageSongCardProps {
  position: 'A' | 'B';
  songId: string;
  songTitle: string;
  artistName: string;
  currentVote?: VoteData | null;
}

const StageSongCard = ({ position, songId, songTitle, artistName, currentVote }: StageSongCardProps) => {
  const isA = position === 'A';
  
  // Determine selection by comparing songId against currentVote
  const isSelected = currentVote?.status === 'active' && currentVote?.song_id === songId;
  
  return (
    <div 
      className={`
        relative w-full aspect-square rounded-2xl overflow-hidden
        bg-surface border-2 transition-all duration-200
        ${isA ? 'border-song-a/30' : 'border-song-b/30'}
        ${isSelected ? (isA ? 'border-song-a ring-2 ring-song-a/50' : 'border-song-b ring-2 ring-song-b/50') : ''}
      `}
    >
      {/* Album art placeholder */}
      <div className="absolute inset-0 bg-gradient-to-br from-secondary/50 to-background/50" />
      
      {/* Song info overlay */}
      <div className="absolute inset-0 flex flex-col items-center justify-end p-6 lg:p-8">
        <div className={`
          w-full text-center
          ${isA ? 'text-song-a' : 'text-song-b'}
        `}>
          <h3 className="text-2xl lg:text-4xl font-bold truncate mb-2">
            {songTitle}
          </h3>
          <p className="text-lg lg:text-2xl text-muted-foreground truncate">
            {artistName}
          </p>
        </div>
      </div>

      {/* Side indicator glow */}
      <div className={`
        absolute inset-0 pointer-events-none
        ${isA ? 'shadow-[inset_0_0_60px_rgba(59,130,246,0.1)]' : 'shadow-[inset_0_0_60px_rgba(236,72,153,0.1)]'}
      `} />
    </div>
  );
};

export default StageView;
