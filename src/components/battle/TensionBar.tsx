interface TensionBarProps {
  percentageA?: number;
  percentageB?: number;
}

const TensionBar = ({ percentageA = 50, percentageB = 50 }: TensionBarProps) => {
  return (
    <div className="w-full px-4 pt-4">
      {/* Percentage labels */}
      <div className="flex justify-between mb-2 px-2">
        <span className="text-sm font-semibold text-song-a text-glow-a">
          {percentageA}%
        </span>
        <span className="text-sm font-semibold text-song-b text-glow-b">
          {percentageB}%
        </span>
      </div>
      
      {/* Bar container */}
      <div className="w-full h-2 flex rounded-full overflow-hidden bg-secondary">
        {/* Song A side */}
        <div 
          className="h-full bg-gradient-to-r from-song-a/80 to-song-a transition-all duration-300"
          style={{ width: `${percentageA}%` }}
        />
        
        {/* Song B side */}
        <div 
          className="h-full bg-gradient-to-l from-song-b/80 to-song-b transition-all duration-300"
          style={{ width: `${percentageB}%` }}
        />
      </div>
    </div>
  );
};

export default TensionBar;
