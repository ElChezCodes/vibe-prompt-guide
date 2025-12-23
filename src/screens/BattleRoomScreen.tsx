import { useState } from "react";
import TensionBar, { type BattleIntensity } from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import SongCard, { type CardAnimationState } from "@/components/battle/SongCard";
import ActionStrip from "@/components/battle/ActionStrip";
import BattleStateOverlay, { type BattleState } from "@/components/battle/BattleStateOverlay";

type VoteSelection = 'A' | 'B' | null;

const BattleRoomScreen = () => {
  const [currentVote, setCurrentVote] = useState<VoteSelection>(null);
  
  // Placeholder: will be controlled by backend state
  const battleState = 'NORMAL' as BattleState;
  const winnerSide: 'A' | 'B' | null = null; // Placeholder for winner
  
  // Voting enabled only in NORMAL, FINAL_30S, and SUDDEN_DEATH states
  const isVotingEnabled = ['NORMAL', 'FINAL_30S', 'SUDDEN_DEATH'].includes(battleState);

  // Map battle state to tension intensity
  const getTensionIntensity = (): BattleIntensity => {
    switch (battleState) {
      case 'FINAL_30S':
        return 'final';
      case 'SUDDEN_DEATH':
        return 'sudden';
      default:
        return 'normal';
    }
  };

  // Map battle state to card animation state
  const getCardAnimationState = (side: 'A' | 'B'): CardAnimationState => {
    if (battleState === 'FINISHED' && winnerSide) {
      return side === winnerSide ? 'winner' : 'loser';
    }
    return 'idle';
  };

  const handleVoteA = () => {
    if (isVotingEnabled) {
      setCurrentVote('A');
      // TODO: Send vote intent to backend
    }
  };

  const handleVoteB = () => {
    if (isVotingEnabled) {
      setCurrentVote('B');
      // TODO: Send vote intent to backend
    }
  };

  return (
    <div className="min-h-dvh w-full flex flex-col bg-background">
      {/* Tension Bar - fixed at top */}
      <div className="sticky top-0 z-20 bg-background">
        <TensionBar 
          percentageA={50} 
          percentageB={50} 
          intensity={getTensionIntensity()}
        />
      </div>

      {/* Timer */}
      <BattleTimer time="01:23" />

      {/* Battle Cards container - flexible middle section */}
      <div className="flex-1 flex items-center justify-center px-4">
        <div className="w-full max-w-md flex items-center gap-3">
          {/* Song A - Left */}
          <SongCard 
            position="left" 
            songTitle="Burning Lights" 
            artistName="Skybound"
            isSelected={currentVote === 'A'}
            isDisabled={!isVotingEnabled}
            animationState={getCardAnimationState('A')}
            onVote={handleVoteA}
          />
          
          {/* VS divider */}
          <div className="flex-shrink-0 flex items-center justify-center">
            <span className="text-2xl font-arcade font-bold text-muted-foreground/60">
              VS
            </span>
          </div>
          
          {/* Song B - Right */}
          <SongCard 
            position="right" 
            songTitle="Starlight Groove" 
            artistName="Neon Pulse"
            isSelected={currentVote === 'B'}
            isDisabled={!isVotingEnabled}
            animationState={getCardAnimationState('B')}
            onVote={handleVoteB}
          />
        </div>
      </div>

      {/* Action Strip - bottom */}
      <ActionStrip />
      
      {/* Battle State Overlay */}
      <BattleStateOverlay battleState={battleState} winnerSide={winnerSide} />
    </div>
  );
};

export default BattleRoomScreen;
