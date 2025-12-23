type BattleIntensity = 'normal' | 'final' | 'sudden';

interface TensionBarProps {
  percentageA?: number;
  percentageB?: number;
  intensity?: BattleIntensity;
}

const TensionBar = ({ 
  percentageA = 50, 
  percentageB = 50,
  intensity = 'normal'
}: TensionBarProps) => {
  const getOscillationClass = () => {
    switch (intensity) {
      case 'final':
        return 'animate-tension-final';
      case 'sudden':
        return 'animate-tension-sudden';
      default:
        return 'animate-tension-normal';
    }
  };

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
      <div className="w-full h-2 flex rounded-full overflow-hidden bg-secondary relative">
        {/* Song A side */}
        <div 
          className="h-full bg-gradient-to-r from-song-a/80 to-song-a transition-all duration-300 ease-out"
          style={{ width: `${percentageA}%` }}
        />
        
        {/* Center divider with micro-oscillation */}
        <div 
          className={`absolute top-0 h-full w-0.5 bg-foreground/30 ${getOscillationClass()}`}
          style={{ left: `${percentageA}%`, transform: 'translateX(-50%)' }}
        />
        
        {/* Song B side */}
        <div 
          className="h-full bg-gradient-to-l from-song-b/80 to-song-b transition-all duration-300 ease-out"
          style={{ width: `${percentageB}%` }}
        />
      </div>
    </div>
  );
};

export default TensionBar;

export type { BattleIntensity };
