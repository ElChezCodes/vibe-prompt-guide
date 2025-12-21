interface BattleTimerProps {
  time?: string;
}

const BattleTimer = ({ time = "01:23" }: BattleTimerProps) => {
  return (
    <div className="flex items-center justify-center py-6">
      <span className="text-3xl font-semibold text-foreground tracking-widest tabular-nums">
        {time}
      </span>
    </div>
  );
};

export default BattleTimer;
