interface TensionBarProps {
  percentageA?: number;
  percentageB?: number;
}

const TensionBar = ({ percentageA = 50, percentageB = 50 }: TensionBarProps) => {
  return (
    <div className="w-full h-12 flex relative">
      {/* Song A side */}
      <div 
        className="h-full bg-secondary flex items-center justify-end pr-4"
        style={{ width: `${percentageA}%` }}
      >
        <span className="text-sm font-medium text-muted-foreground">
          {percentageA}%
        </span>
      </div>
      
      {/* Center divider */}
      <div className="absolute left-1/2 top-0 bottom-0 w-px bg-border -translate-x-1/2 z-10" />
      
      {/* Song B side */}
      <div 
        className="h-full bg-secondary flex items-center justify-start pl-4"
        style={{ width: `${percentageB}%` }}
      >
        <span className="text-sm font-medium text-muted-foreground">
          {percentageB}%
        </span>
      </div>
    </div>
  );
};

export default TensionBar;
