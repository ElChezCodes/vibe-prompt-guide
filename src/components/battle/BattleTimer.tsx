import React, { useState, useEffect } from "react";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";

interface BattleTimerProps {
  battle: ArenaBattleView | null;
  // Arena paused (Spotify): the backend clock is frozen, so is the display.
  // On resume the backend shifts started_at by the paused time.
  pausedAt?: string | null;
  // The final decision / Sudden Death (votes still open), from the derived phase
  highlight?: boolean;
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

const BattleTimer = ({ battle, pausedAt = null, highlight = false }: BattleTimerProps) => {
  const [remainingTime, setRemainingTime] = useState<number>(0);
  // Only these fields drive the clock (the battle object is rebuilt on every
  // vote poll, so depending on it would restart the interval every 2 s)
  const hasBattle = !!battle;
  const battleStartedAt = battle?.started_at ?? null;
  const battleDurationMs = battle?.duration_ms ?? 0;

  useEffect(() => {
    if (!hasBattle || !battleStartedAt) {
      // Pending (not started yet): its whole length
      setRemainingTime(hasBattle ? Math.ceil(battleDurationMs / 1000) : 0);
      return;
    }

    let cancelled = false;

    const updateRemaining = () => {
      if (cancelled) return;
      const startedAt = new Date(battleStartedAt).getTime();
      const clientNow = pausedAt ? new Date(pausedAt).getTime() : Date.now();
      const elapsedMs = clientNow - startedAt;
      const remainingMs = battleDurationMs - elapsedMs;
      setRemainingTime(Math.max(0, Math.ceil(remainingMs / 1000)));
    };

    updateRemaining();
    if (pausedAt) return;
    const interval = setInterval(updateRemaining, 1000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [battle?.battle_id, hasBattle, battleStartedAt, battleDurationMs, pausedAt]);

  const isFinal = highlight && remainingTime > 0;

  return (
    <div className="relative py-8">
      <div className="flex items-center justify-center">
        <span
          // Just the numbers, no frame (user, 2026-11-01: a cleaner screen)
          className={`h-16 lg:h-24 flex items-center font-arcade text-4xl lg:text-7xl font-black tracking-widest tabular-nums transition-colors duration-300 ${
            isFinal ? "text-energy-yellow animate-pulse" : "text-foreground"
          }`}
        >
          {formatTime(remainingTime)}
        </span>
      </div>
    </div>
  );
};

export default React.memo(BattleTimer);
