import TensionBar from "@/components/battle/TensionBar";
import BattleTimer from "@/components/battle/BattleTimer";
import SongCard from "@/components/battle/SongCard";
import ActionStrip from "@/components/battle/ActionStrip";

const BattleRoomScreen = () => {
  return (
    <div className="min-h-dvh w-full flex flex-col bg-background">
      {/* Tension Bar - fixed at top */}
      <div className="sticky top-0 z-20 bg-background">
        <TensionBar percentageA={50} percentageB={50} />
      </div>

      {/* Timer */}
      <BattleTimer time="01:23" />

      {/* Battle Cards container - flexible middle section */}
      <div className="flex-1 flex items-center justify-center px-2">
        <div className="w-full max-w-md flex gap-2">
          {/* Song A - Left */}
          <SongCard 
            position="left" 
            songTitle="Song A Title" 
            artistName="Artist A" 
          />
          
          {/* Center divider */}
          <div className="w-px bg-border self-stretch my-4" />
          
          {/* Song B - Right */}
          <SongCard 
            position="right" 
            songTitle="Song B Title" 
            artistName="Artist B" 
          />
        </div>
      </div>

      {/* Action Strip - bottom */}
      <ActionStrip />
    </div>
  );
};

export default BattleRoomScreen;
