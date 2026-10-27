import TensionBar, { BattleIntensity } from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import BattleStateOverlay, { BattleState } from "@/components/battle/BattleStateOverlay";
import ScreenMessage from "@/components/nav/ScreenMessage";
import { useArenaFromRoute } from "@/hooks/useArenaFromRoute";

// Venue display, opened from a shared link (/a/:code/stage). Read-only, no
// buttons. The arena comes from the URL; battle data is still placeholder
// until roadmap step 19.
const StageViewScreen = () => {
  const { arena, status } = useArenaFromRoute();

  // Placeholder battle state - will be connected to real data later
  // Using type assertion since this will be replaced with real state
  const battleState = 'NORMAL' as BattleState;
  const percentageA = 52;
  const percentageB = 48;
  const winnerSide: 'A' | 'B' | null = null;

  const getTensionIntensity = (): BattleIntensity => {
    switch (battleState) {
      case 'FINAL_30S': return 'final';
      case 'SUDDEN_DEATH': return 'sudden';
      default: return 'normal';
    }
  };

  if (status === "loading") return <ScreenMessage message="Loading..." showHomeButton={false} />;
  if (status !== "ready") return <ScreenMessage message="Arena not found" isError showHomeButton={false} />;

  return (
    <div className="min-h-dvh w-full flex flex-col bg-background overflow-hidden">
      {/* Arena + how to join */}
      <div className="w-full pt-6 px-8 flex items-center justify-between text-muted-foreground">
        <span className="text-xl lg:text-2xl font-semibold text-foreground">{arena.name}</span>
        <span className="text-lg lg:text-2xl">
          {arena.state === "finished"
            ? "Arena finished"
            : <>Join with code <span className="font-mono font-bold text-foreground tracking-widest">{arena.arena_code}</span></>}
        </span>
      </div>

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
            01:23
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
              songTitle="Blinding Lights"
              artistName="The Weeknd"
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
              songTitle="Levitating"
              artistName="Dua Lipa"
            />
          </div>
        </div>
      </div>

      {/* Spacer for bottom balance */}
      <div className="h-16 lg:h-24" />

      {/* Battle State Overlay */}
      <BattleStateOverlay battleState={battleState} winnerSide={winnerSide} />
    </div>
  );
};

// Stage-optimized Song Card (read-only, larger text)
interface StageSongCardProps {
  position: 'A' | 'B';
  songTitle: string;
  artistName: string;
}

const StageSongCard = ({ position, songTitle, artistName }: StageSongCardProps) => {
  const isA = position === 'A';
  
  return (
    <div 
      className={`
        relative w-full aspect-square rounded-2xl overflow-hidden
        bg-surface border-2
        ${isA ? 'border-song-a/30' : 'border-song-b/30'}
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

export default StageViewScreen;
