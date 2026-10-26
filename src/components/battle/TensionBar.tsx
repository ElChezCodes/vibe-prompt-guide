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
      <div className="flex justify-between items-end mb-2 px-1">
        <span className="font-arcade text-lg lg:text-2xl font-black text-song-a text-glow-a tabular-nums">
          {percentageA}%
        </span>
        <span className="font-arcade text-lg lg:text-2xl font-black text-song-b text-glow-b tabular-nums">
          {percentageB}%
        </span>
      </div>

      {/* Bar container */}
      <div className="w-full h-3 flex rounded-full overflow-hidden bg-secondary border border-border relative">
        <div
          className="h-full bg-gradient-to-r from-song-a/60 to-song-a transition-all duration-500 ease-out"
          style={{ width: `${percentageA}%` }}
        />
        <div
          className={`absolute -top-1 -bottom-1 w-1 rounded-full bg-foreground glow-energy ${getOscillationClass()}`}
          style={{ left: `${percentageA}%`, marginLeft: '-2px' }}
        />
        <div
          className="h-full bg-gradient-to-l from-song-b/60 to-song-b transition-all duration-500 ease-out"
          style={{ width: `${percentageB}%` }}
        />
      </div>
    </div>
  );
};

export default TensionBar;

export type { BattleIntensity };
