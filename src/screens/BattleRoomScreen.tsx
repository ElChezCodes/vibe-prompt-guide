import { useState } from "react";
import TensionBar from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import SongCard from "@/components/battle/SongCard";
import ActionStrip from "@/components/battle/ActionStrip";
import BattleStateOverlay, { type BattleState } from "@/components/battle/BattleStateOverlay";

type VoteSelection = 'A' | 'B' | null;

const BattleRoomScreen = () => {
  const [currentVote, setCurrentVote] = useState<VoteSelection>(null);
  
  // Placeholder: will be controlled by backend state
  const battleState: BattleState = 'NORMAL';
  
  // Voting enabled only in NORMAL, FINAL_30S, and SUDDEN_DEATH states
  const isVotingEnabled = ['NORMAL', 'FINAL_30S', 'SUDDEN_DEATH'].includes(battleState);

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
        <TensionBar percentageA={50} percentageB={50} />
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
            onVote={handleVoteB}
          />
        </div>
      </div>

      {/* Action Strip - bottom */}
      <ActionStrip />
      
      {/* Battle State Overlay */}
      <BattleStateOverlay battleState={battleState} />
    </div>
  );
};

export default BattleRoomScreen;
