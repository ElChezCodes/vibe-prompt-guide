interface BattleTimerProps {
  time?: string;
}

const BattleTimer = ({ time = "01:23" }: BattleTimerProps) => {
  return (
    <div className="flex items-center justify-center py-4">
      <span className="text-2xl font-mono text-foreground tracking-wider">
        {time}
      </span>
    </div>
  );
};

export default BattleTimer;
