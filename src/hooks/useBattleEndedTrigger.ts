import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

/**
 * useBattleEndedTrigger
 *
 * A neutral signal emitter that wakes up the backend when battle time is exhausted.
 * This hook does NOT decide if a battle is "completed" — it only signals
 * the backend to check if it can finalize the battle.
 *
 * Backend-authoritative: The Edge Function decides the actual outcome.
 */
export function useBattleEndedTrigger(battleId: string | null, remainingTime: number): void {
  const triggeredRef = useRef<string | null>(null);

  // ─────────────────────────────────────────────
  // Reset trigger when battle changes or time is restored
  // ─────────────────────────────────────────────
  useEffect(() => {
    if (remainingTime > 0) {
      triggeredRef.current = null;
    }
  }, [remainingTime]);

  // ─────────────────────────────────────────────
  // Signal backend when time is exhausted
  // ─────────────────────────────────────────────
  useEffect(() => {
    // Only signal when time has run out
    if (remainingTime > 0 || !battleId) {
      return;
    }

    // Idempotency: don't signal twice for the same battle
    if (triggeredRef.current === battleId) {
      return;
    }

    triggeredRef.current = battleId;

    // Allow retry after a short window (in case backend was temporarily unavailable)
    setTimeout(() => {
      triggeredRef.current = null;
    }, 2000);

    // 🔍 Observability (neutral signal, not a state assertion)
    console.log("[battle-ended signal]", {
      battleId,
      remainingTime,
      now: Date.now(),
    });

    const signalBattleEnded = async () => {
      try {
        const { data: sessionData } = await supabase.auth.getSession();
        const accessToken = sessionData?.session?.access_token;

        const response = await fetch(
          `${
            import.meta.env.VITE_SUPABASE_URL ?? "https://uuxzjroikbzwaszpgiks.supabase.co"
          }/functions/v1/battle-ended`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...(accessToken && {
                Authorization: `Bearer ${accessToken}`,
              }),
            },
            body: JSON.stringify({ battle_id: battleId }),
          },
        );

        // 200 = processed, 409 = already handled — both are success
        if (response.status === 200 || response.status === 409) {
          return;
        }

        console.warn("[useBattleEndedTrigger] Unexpected response status:", response.status);
      } catch (error) {
        console.warn("[useBattleEndedTrigger] Request failed:", error);
      }
    };

    // 🔒 DESACTIVADO TEMPORALMENTE PARA AUDITORÍA
    // signalBattleEnded();
  }, [battleId, remainingTime]);
}
