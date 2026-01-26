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

type DerivedBattlePhase = "NORMAL" | "LOCK_IN" | "SUDDEN_DEATH" | "FINISHED";

/**
 * Derives the UI battle phase from BACKEND STATE only.
 * remainingTime is DISPLAY-ONLY.
 */
const getDerivedBattlePhase = (
  battle: {
    state: string;
    sudden_death_active?: boolean;
  } | null,
  _remainingTime: number,
): DerivedBattlePhase => {
  if (!battle) return "NORMAL";

  if (battle.state === "completed") {
    return "FINISHED";
  }

  if (battle.state === "closing") {
    if (battle.sudden_death_active) {
      return "SUDDEN_DEATH";
    }
    return "LOCK_IN";
  }

  if (battle.state === "active") {
    return "NORMAL";
  }

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

  // Backend-authoritative trigger (no time-based logic)
  useBattleEndedTrigger(battle?.id ?? null, remainingTime);

  const handleVote = useCallback(
    async (side: "A" | "B") => {
      if (!battle || battle.state !== "active" || !participant || !arena) {
        return;
      }

      if (isVotingRef.current) return;

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) return;

      isVotingRef.current = true;

      const songId = side === "A" ? battle.song_a_id : battle.song_b_id;

      const { vote, action } = await applyVoteIntent(
        battle.id,
        participant.id,
        songId,
        voteRecord,
        arena.id,
        session.user.id,
      );

      if (vote) {
        setVoteRecord(vote);
      }

      isVotingRef.current = false;
    },
    [battle, participant, voteRecord, arena],
  );

  const arenaId = location.state?.arenaId as string | undefined;
  const roleIntent = location.state?.role_intent as "host" | "participant" | undefined;

  const { hasJustResolved, lastWinnerSide, isDraw, acknowledgeResult } = useArenaFlow(arenaId ?? "", closureState);

  // Reset on battle change
  useEffect(() => {
    if (battle?.id !== prevBattleIdRef.current) {
      setVoteRecord(null);
      resetClosure();
      prevBattleIdRef.current = battle?.id ?? null;
      if (battle?.id) {
        syncFromBattle(battle.id);
      }
    }
  }, [battle?.id, syncFromBattle, resetClosure]);

  // Consume resolution (UI only)
  useEffect(() => {
    if (!hasJustResolved) return;
    acknowledgeResult();
  }, [hasJustResolved, acknowledgeResult]);

  // Remaining time is DISPLAY-ONLY
  useEffect(() => {
    if (!battle || battle.state !== "active") {
      setRemainingTime(0);
      return;
    }

    let cancelled = false;

    const updateRemaining = () => {
      if (cancelled) return;
      const seconds = getRemainingSecondsFromBattle(battle);
      setRemainingTime(seconds);
    };

    updateRemaining();
    const interval = setInterval(updateRemaining, 1000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [battle?.id, battle?.started_at, battle?.duration_ms, battle?.state]);

  useEffect(() => {
    const loadBattleRoom = async () => {
      try {
        if (!arenaId) {
          setErrorMessage("No arena ID provided");
          setScreenState("error");
          return;
        }

        const {
          data: { session },
        } = await supabase.auth.getSession();

        if (!session?.user) {
          setErrorMessage("No authenticated session");
          setScreenState("error");
          return;
        }

        const identityAnchorId = session.user.id;

        const { data: arenaData, error: arenaError } = await supabase
          .from("arenas")
          .select("id, name, state")
          .eq("id", arenaId)
          .single();

        if (arenaError || !arenaData) {
          setErrorMessage("Arena not found");
          setScreenState("error");
          return;
        }

        const isHost = roleIntent === "host";
        const participantData = await ensureParticipant(arenaId, identityAnchorId, isHost);

        setArena(arenaData);
        setParticipant(participantData);
        setScreenState("ready");

        const currentBattle = await initBattleLoop(arenaId);

        if (currentBattle?.state === "active") {
          const existingVote = await getParticipantVote(currentBattle.id, participantData.id);
          if (existingVote) {
            setVoteRecord(existingVote);
          }
        }
      } catch (err) {
        setErrorMessage("Failed to load battle room");
        setScreenState("error");
      }
    };

    loadBattleRoom();

    return () => {
      stopBattleLoop();
    };
  }, [arenaId, roleIntent, initBattleLoop, stopBattleLoop]);

  if (screenState === "loading") {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-muted-foreground">Loading...</p>
      </div>
    );
  }

  if (screenState === "error") {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-destructive">{errorMessage}</p>
      </div>
    );
  }

  const derivedPhase = getDerivedBattlePhase(battle, remainingTime);

  const isVotingEnabled = battle?.state === "active" && (derivedPhase === "NORMAL" || derivedPhase === "SUDDEN_DEATH");

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
          <div className="min-h-dvh w-full flex flex-col">
            <div className="pt-8 px-8">
              <div className="h-3" />
            </div>
            <div className="py-8">
              <div className="h-16 lg:h-24" />
            </div>

            <div className="flex-1 flex items-center justify-center px-8 lg:px-16">
              <div className="w-full max-w-7xl flex items-center justify-center gap-8 lg:gap-16">
                <div
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote("A")}
                  role="button"
                  aria-label="Vote for Song A"
                />

                <div className="flex-shrink-0 w-16 lg:w-24" />

                <div
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote("B")}
                  role="button"
                  aria-label="Vote for Song B"
                />
              </div>
            </div>

            <div className="h-16 lg:h-24" />
          </div>
        </div>
      )}

      {derivedPhase === "SUDDEN_DEATH" && hasSuddenDeathVote && (
        <div className="absolute bottom-8 left-1/2 -translate-x-1/2 z-50 pointer-events-none">
          <div className="px-4 py-2 rounded-lg bg-primary/20 border border-primary/40 text-primary text-sm font-medium">
            Vote submitted
          </div>
        </div>
      )}
    </div>
  );
};

export default BattleRoomScreen;
