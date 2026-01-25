import { useState, useEffect, useRef, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { getParticipantVote, applyVoteIntent, Vote } from "@/integrations/supabase/votes";
import { useBattleOrchestrator } from "@/hooks/useBattleOrchestrator";
import { useBattleClosureOrchestrator } from "@/hooks/useBattleClosureOrchestrator";
import { useBattleEndedTrigger } from "@/hooks/useBattleEndedTrigger";
import { useArenaFlow } from "@/hooks/useArenaFlow";
import { ensureParticipant } from "@/integrations/supabase/participants";
import StageView from "@/components/battle/StageView";

type ScreenState = "loading" | "error" | "ready";

interface ArenaData {
  id: string;
  name: string;
  state: string;
}

interface ParticipantData {
  id: string;
  is_host: boolean;
}

const formatTime = (seconds: number): string => {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
};

type DerivedBattlePhase = "NORMAL" | "FINAL_30S" | "LOCK_IN" | "SUDDEN_DEATH" | "FINISHED";

const getDerivedBattlePhase = (
  battle: {
    state: string;
    sudden_death_active?: boolean;
    lockin_at?: string | null;
    winner_song_id?: string | null;
  } | null,
  remainingTime: number,
): DerivedBattlePhase => {
  if (!battle) return "NORMAL";

  if (battle.state === "completed" || battle.state === "closing") {
    return "FINISHED";
  }

  if (battle.state !== "active") {
    return "NORMAL";
  }

  if (battle.sudden_death_active === true) {
    return "SUDDEN_DEATH";
  }

  if (battle.lockin_at !== null && battle.lockin_at !== undefined) {
    return "LOCK_IN";
  }

  if (remainingTime <= 0) return "FINISHED";
  if (remainingTime <= 15) return "LOCK_IN";
  if (remainingTime <= 30) return "FINAL_30S";

  return "NORMAL";
};

const getRemainingSecondsFromBattle = (battle: { started_at: string; duration_ms: number }) => {
  const startedAt = new Date(battle.started_at).getTime();
  const now = Date.now();
  const elapsedMs = now - startedAt;
  const remainingMs = battle.duration_ms - elapsedMs;

  return Math.max(0, Math.ceil(remainingMs / 1000));
};

const BattleRoomScreen = () => {
  const location = useLocation();
  const [screenState, setScreenState] = useState<ScreenState>("loading");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [arena, setArena] = useState<ArenaData | null>(null);
  const [participant, setParticipant] = useState<ParticipantData | null>(null);
  const [voteRecord, setVoteRecord] = useState<Vote | null>(null);
  const [remainingTime, setRemainingTime] = useState<number>(0);
  const isVotingRef = useRef(false);
  const prevBattleIdRef = useRef<string | null>(null);

  const { battle, initBattleLoop, stopBattleLoop } = useBattleOrchestrator();
  const { state: closureState, syncFromBattle, reset: resetClosure } = useBattleClosureOrchestrator();

  const arenaId = location.state?.arenaId as string | undefined;
  const roleIntent = location.state?.role_intent as "host" | "participant" | undefined;

  const { hasJustResolved, lastWinnerSide, isDraw, acknowledgeResult } = useArenaFlow(arenaId ?? "", closureState);

  const handleVote = useCallback(
    async (side: "A" | "B") => {
      if (!battle || battle.state !== "active" || !participant || !arena) return;
      if (isVotingRef.current) return;

      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session?.user) return;

      isVotingRef.current = true;

      const songId = side === "A" ? battle.song_a_id : battle.song_b_id;

      const { vote } = await applyVoteIntent(battle.id, participant.id, songId, voteRecord, arena.id, session.user.id);

      if (vote) setVoteRecord(vote);
      isVotingRef.current = false;
    },
    [battle, participant, voteRecord, arena],
  );

  // 🔁 Reset per battle
  useEffect(() => {
    if (battle?.id !== prevBattleIdRef.current) {
      setRemainingTime(0);

      if (prevBattleIdRef.current) {
        setVoteRecord(null);
        resetClosure();
      }

      prevBattleIdRef.current = battle?.id ?? null;

      if (battle?.id) {
        syncFromBattle(battle.id);
      }
    }
  }, [battle?.id, syncFromBattle, resetClosure]);

  useEffect(() => {
    if (!hasJustResolved) return;
    acknowledgeResult();
  }, [hasJustResolved, acknowledgeResult]);

  useEffect(() => {
    if (!battle || battle.state !== "active") {
      setRemainingTime(0);
      return;
    }

    const interval = setInterval(() => {
      setRemainingTime(getRemainingSecondsFromBattle(battle));
    }, 1000);

    return () => clearInterval(interval);
  }, [battle?.id, battle?.started_at, battle?.duration_ms, battle?.state]);

  useEffect(() => {
    const load = async () => {
      if (!arenaId) return setScreenState("error");

      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session?.user) return setScreenState("error");

      const { data: arenaData } = await supabase.from("arenas").select("id, name, state").eq("id", arenaId).single();

      if (!arenaData) return setScreenState("error");

      const participantData = await ensureParticipant(arenaId, session.user.id, roleIntent === "host");

      setArena(arenaData);
      setParticipant(participantData);
      setScreenState("ready");

      const currentBattle = await initBattleLoop(arenaId);

      if (currentBattle?.state === "active") {
        const existingVote = await getParticipantVote(currentBattle.id, participantData.id);
        if (existingVote) setVoteRecord(existingVote);
      }
    };

    load();
    return () => stopBattleLoop();
  }, [arenaId, roleIntent, initBattleLoop, stopBattleLoop]);

  if (screenState !== "ready") return null;

  const derivedPhase = getDerivedBattlePhase(battle, remainingTime);

  // ✅ CAMBIO CLAVE: señal SIEMPRE estable
  useBattleEndedTrigger(battle?.id ?? null, "active");

  const isVotingEnabled =
    battle?.state === "active" &&
    (derivedPhase === "NORMAL" || derivedPhase === "FINAL_30S" || derivedPhase === "SUDDEN_DEATH");

  const hasSuddenDeathVote = voteRecord?.vote_type === "sudden_death";
  const isSuddenDeathVotingEnabled = derivedPhase === "SUDDEN_DEATH" && !hasSuddenDeathVote;

  return (
    <div className="relative min-h-dvh w-full">
      <StageView
        arena={arena!}
        battle={battle}
        participant={participant!}
        currentVote={voteRecord}
        timer={formatTime(remainingTime)}
        derivedPhase={derivedPhase}
      />

      {isVotingEnabled && (derivedPhase !== "SUDDEN_DEATH" || isSuddenDeathVotingEnabled) && (
        <div className="absolute inset-0 z-50 pointer-events-none">
          <div className="flex h-full">
            <div className="flex-1 pointer-events-auto" onClick={() => handleVote("A")} />
            <div className="flex-1 pointer-events-auto" onClick={() => handleVote("B")} />
          </div>
        </div>
      )}
    </div>
  );
};

export default BattleRoomScreen;
