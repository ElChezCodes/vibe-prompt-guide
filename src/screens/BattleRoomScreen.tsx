import { useState, useEffect, useRef, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { getParticipantVote, applyVoteIntent, Vote } from "@/integrations/supabase/votes";
import { useBattleOrchestrator } from "@/hooks/useBattleOrchestrator";
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

const MOCK_BATTLE_DURATION = 45;

const formatTime = (seconds: number): string => {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
};

type DerivedBattlePhase = "NORMAL" | "FINAL_30S" | "LOCK_IN" | "FINISHED";

const getDerivedBattlePhase = (remainingTime: number): DerivedBattlePhase => {
  if (remainingTime <= 0) return "FINISHED";
  if (remainingTime <= 15) return "LOCK_IN";
  if (remainingTime <= 30) return "FINAL_30S";
  return "NORMAL";
};

const BattleRoomScreen = () => {
  const location = useLocation();
  const [screenState, setScreenState] = useState<ScreenState>("loading");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [arena, setArena] = useState<ArenaData | null>(null);
  const [participant, setParticipant] = useState<ParticipantData | null>(null);
  const [voteRecord, setVoteRecord] = useState<Vote | null>(null);
  const [remainingTime, setRemainingTime] = useState<number>(MOCK_BATTLE_DURATION);
  const isVotingRef = useRef(false);
  const prevBattleIdRef = useRef<string | null>(null);
  const timerIntervalRef = useRef<NodeJS.Timeout | null>(null);

  const { battle, initBattleLoop, stopBattleLoop } = useBattleOrchestrator();

  // Timer countdown effect
  useEffect(() => {
    // Clear any existing interval
    if (timerIntervalRef.current) {
      clearInterval(timerIntervalRef.current);
      timerIntervalRef.current = null;
    }

    // Start countdown when battle is active
    if (battle?.state === "active") {
      setRemainingTime(MOCK_BATTLE_DURATION);

      timerIntervalRef.current = setInterval(() => {
        setRemainingTime((prev) => {
          if (prev <= 1) {
            if (timerIntervalRef.current) {
              clearInterval(timerIntervalRef.current);
              timerIntervalRef.current = null;
            }
            return 0;
          }
          return prev - 1;
        });
      }, 1000);
    }

    return () => {
      if (timerIntervalRef.current) {
        clearInterval(timerIntervalRef.current);
        timerIntervalRef.current = null;
      }
    };
  }, [battle?.state, battle?.id]);

  const handleVote = useCallback(
    async (side: "A" | "B") => {
      if (!battle || battle.state !== "active" || !participant || !arena) {
        console.log("[Vote] Blocked - battle not active or missing data");
        return;
      }

      if (isVotingRef.current) {
        console.log("[Vote] Blocked - vote in progress");
        return;
      }

      // Get identity anchor from session
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session?.user) {
        console.log("[Vote] Blocked - no session");
        return;
      }

      isVotingRef.current = true;
      const songId = side === "A" ? battle.song_a_id : battle.song_b_id;

      console.log(`[Vote] Processing vote for Song ${side} (${songId})`);

      const { vote, action } = await applyVoteIntent(
        battle.id,
        participant.id,
        songId,
        voteRecord,
        arena.id,
        session.user.id,
      );

      if (action === "locked") {
        console.log("[Vote] Battle is locked - voting not allowed");
        isVotingRef.current = false;
        return;
      }

      console.log(`[Vote] Action: ${action}`, vote);

      if (vote) {
        setVoteRecord(vote);
      }

      isVotingRef.current = false;
    },
    [battle, participant, voteRecord],
  );

  const arenaId = location.state?.arenaId as string | undefined;
  const roleIntent = location.state?.role_intent as "host" | "participant" | undefined;

  // Reset vote state when battle changes
  useEffect(() => {
    if (battle?.id !== prevBattleIdRef.current) {
      if (prevBattleIdRef.current !== null) {
        // Battle changed, reset vote state
        setVoteRecord(null);
      }
      prevBattleIdRef.current = battle?.id ?? null;
    }
  }, [battle?.id]);

  useEffect(() => {
    const loadBattleRoom = async () => {
      try {
        if (!arenaId) {
          setErrorMessage("No arena ID provided");
          setScreenState("error");
          return;
        }

        // Get current auth session for identity
        const {
          data: { session },
        } = await supabase.auth.getSession();
        if (!session?.user) {
          setErrorMessage("No authenticated session");
          setScreenState("error");
          return;
        }

        const identityAnchorId = session.user.id;

        // Fetch arena data
        const { data: arenaData, error: arenaError } = await supabase
          .from("arenas")
          .select("id, name, state")
          .eq("id", arenaId)
          .single();

        if (arenaError || !arenaData) {
          console.error("Failed to fetch arena:", arenaError);
          setErrorMessage("Arena not found");
          setScreenState("error");
          return;
        }

        // Register participant based on role_intent (idempotent)
        const isHost = roleIntent === "host";
        const participantData = await ensureParticipant(arenaId, identityAnchorId, isHost);

        setArena(arenaData);
        setParticipant(participantData);
        setScreenState("ready");

        // Initialize battle loop via orchestrator
        const currentBattle = await initBattleLoop(arenaId);

        // Load existing vote if battle is active
        if (currentBattle?.state === "active") {
          const existingVote = await getParticipantVote(currentBattle.id, participantData.id);
          if (existingVote) {
            setVoteRecord(existingVote);
          }
        }
      } catch (err) {
        console.error("Battle room load error:", err);
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

  const isVotingEnabled = battle?.state === "active";

  const derivedPhase = getDerivedBattlePhase(remainingTime);

  return (
    <div className="relative min-h-dvh w-full">
      {/* Presentational layer */}
      <StageView
        arena={arena!}
        battle={battle}
        participant={participant!}
        currentVote={voteRecord}
        timer={formatTime(remainingTime)}
        derivedPhase={derivedPhase}
      />

      {/* Invisible interaction layer - positioned above StageView */}
      {isVotingEnabled && (
        <div className="absolute inset-0 z-50 pointer-events-none">
          {/* Match the layout of StageView's battle arena section */}
          <div className="min-h-dvh w-full flex flex-col">
            {/* Spacer for tension bar + timer */}
            <div className="pt-8 px-8">
              <div className="h-3" />
            </div>
            <div className="py-8">
              <div className="h-16 lg:h-24" />
            </div>

            {/* Clickable song areas */}
            <div className="flex-1 flex items-center justify-center px-8 lg:px-16">
              <div className="w-full max-w-7xl flex items-center justify-center gap-8 lg:gap-16">
                {/* Song A hit area */}
                <div
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote("A")}
                  role="button"
                  aria-label="Vote for Song A"
                />

                {/* VS spacer */}
                <div className="flex-shrink-0 w-16 lg:w-24" />

                {/* Song B hit area */}
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
    </div>
  );
};

export default BattleRoomScreen;
