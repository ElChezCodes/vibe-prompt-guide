import React, { useState, useEffect } from "react";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";

interface BattleTimerProps {
  battle: ArenaBattleView | null;
}

const getRemainingSecondsFromBattle = (battle: {
  started_at: string | null;
  duration_ms: number;
}) => {
  if (!battle.started_at) return 0;
  const startedAt = new Date(battle.started_at).getTime();
  const now = Date.now();
  const elapsedMs = now - startedAt;
  const remainingMs = battle.duration_ms - elapsedMs;
  return Math.max(0, Math.ceil(remainingMs / 1000));
};

const formatTime = (seconds: number): string => {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
};

const BattleTimer = ({ battle }: BattleTimerProps) => {
  const [remainingTime, setRemainingTime] = useState<number>(0);

  useEffect(() => {
    if (!battle || !battle.started_at) {
      setRemainingTime(0);
      return;
    }

    let cancelled = false;

    const updateRemaining = () => {
      if (cancelled) return;
      const startedAt = new Date(battle.started_at!).getTime();
      const clientNow = Date.now();
      const elapsedMs = clientNow - startedAt;
      const remainingMs = battle.duration_ms - elapsedMs;
      const remaining_seconds = Math.max(0, Math.ceil(remainingMs / 1000));
      console.log("[BattleTimer Debug]", {
        battle_id: battle.battle_id,
        state: battle.state,
        started_at: battle.started_at,
        duration_ms: battle.duration_ms,
        remaining_seconds,
        elapsed_ms: elapsedMs,
        remaining_ms: remainingMs,
        client_now: clientNow,
      });
      setRemainingTime(remaining_seconds);
    };

    updateRemaining();
    const interval = setInterval(updateRemaining, 1000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [battle?.battle_id, battle?.started_at, battle?.duration_ms]);

  return (
    <div className="py-8">
      <div className="flex items-center justify-center">
        <span className="text-6xl lg:text-8xl font-semibold text-foreground tracking-widest tabular-nums">
          {formatTime(remainingTime)}
        </span>
      </div>
    </div>
  );
};

export default React.memo(BattleTimer);
