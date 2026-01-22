import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

type BattlePhase = "pending" | "active" | "closing" | "completed";

export function useBattleEndedTrigger(battleId: string | null, derivedPhase: BattlePhase): void {
  const triggeredRef = useRef<string | null>(null);

  // ─────────────────────────────────────────────
  // Reset trigger when leaving completed phase
  // ─────────────────────────────────────────────
  useEffect(() => {
    if (derivedPhase !== "completed") {
      triggeredRef.current = null;
    }
  }, [derivedPhase]);

  // ─────────────────────────────────────────────
  // Trigger battle-ended when completed
  // ─────────────────────────────────────────────
  useEffect(() => {
    if (derivedPhase !== "completed" || !battleId) {
      return;
    }

    if (triggeredRef.current === battleId) {
      return;
    }

    triggeredRef.current = battleId;

    console.debug("[useBattleEndedTrigger] Triggering battle-ended", battleId);

    const triggerBattleEnded = async () => {
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

        if (response.status === 200 || response.status === 409) {
          return;
        }

        console.warn("[useBattleEndedTrigger] Unexpected response status:", response.status);
      } catch (error) {
        console.warn("[useBattleEndedTrigger] Request failed:", error);
      }
    };

    triggerBattleEnded();
  }, [battleId, derivedPhase]);
}
