import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

interface BattleForLockinTrigger {
  id: string;
  state: "pending" | "active" | "closing" | "completed";
  started_at: string | null;
  duration_ms: number;
  lockin_at?: string | null;
}

/**
 * useBattleLockinTrigger
 *
 * Backend-authoritative wake-up signal for battle lock-in.
 *
 * PRINCIPLES:
 * - Frontend NEVER decides lock-in.
 * - Frontend MAY hint multiple times.
 * - Backend is 100% authoritative and idempotent.
 *
 * SIGNAL CONDITIONS (observable, not exact-time based):
 * - battle.state === "active"
 * - battle.started_at exists
 * - battle.lockin_at is still null
 * - Local clock believes we are INSIDE the last 15s window
 *
 * SAFETY:
 * - Throttled (re-signal every 4s)
 * - Safe with multiple clients
 * - Safe to retry
 */
export function useBattleLockinTrigger(battle: BattleForLockinTrigger | null): void {
  const lastSignalRef = useRef<{ battleId: string; timestamp: number } | null>(null);

  useEffect(() => {
    // ─────────────────────────────────────────────
    // HARD STOPS
    // ─────────────────────────────────────────────
    if (!battle) return;
    if (battle.state !== "active") return;
    if (battle.lockin_at) return;
    if (!battle.started_at) return;

    const now = Date.now();

    // ─────────────────────────────────────────────
    // LOCAL CLOCK ESTIMATE (HINT ONLY)
    // ─────────────────────────────────────────────
    const LOCKIN_WINDOW_MS = 15_000;

    const startedAtMs = new Date(battle.started_at).getTime();
    const endAtMs = startedAtMs + battle.duration_ms;
    const lockinThresholdMs = endAtMs - LOCKIN_WINDOW_MS;

    // Still too early → do nothing
    if (now < lockinThresholdMs) return;

    // ─────────────────────────────────────────────
    // THROTTLE (allow periodic retries)
    // ─────────────────────────────────────────────
    const THROTTLE_MS = 4_000;

    if (
      lastSignalRef.current &&
      lastSignalRef.current.battleId === battle.id &&
      now - lastSignalRef.current.timestamp < THROTTLE_MS
    ) {
      return;
    }

    lastSignalRef.current = { battleId: battle.id, timestamp: now };

    // ─────────────────────────────────────────────
    // OBSERVABILITY
    // ─────────────────────────────────────────────
    console.log("[useBattleLockinTrigger] signal", {
      battleId: battle.id,
      now,
      started_at: battle.started_at,
      duration_ms: battle.duration_ms,
      note: "neutral wake-up hint; backend decides",
    });

    // ─────────────────────────────────────────────
    // SIGNAL BACKEND
    // ─────────────────────────────────────────────
    const signal = async () => {
      try {
        const { data } = await supabase.auth.getSession();
        const accessToken = data?.session?.access_token;

        const response = await fetch(
          `${
            import.meta.env.VITE_SUPABASE_URL ?? "https://uuxzjroikbzwaszpgiks.supabase.co"
          }/functions/v1/battle-lockin`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...(accessToken && {
                Authorization: `Bearer ${accessToken}`,
              }),
            },
            body: JSON.stringify({ battle_id: battle.id }),
          },
        );

        // 200 = locked
        // 409 = not ready OR already handled
        if (response.status === 200 || response.status === 409) {
          return;
        }

        console.warn("[useBattleLockinTrigger] unexpected status", response.status);
      } catch (err) {
        console.warn("[useBattleLockinTrigger] request failed", err);
      }
    };

    signal();
  }, [battle?.id, battle?.state, battle?.started_at, battle?.duration_ms, battle?.lockin_at]);
}
