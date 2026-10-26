import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { ArenaWarmup, getArenaWarmup } from "@/integrations/supabase/arenas";

const WARMUP_BUCKET = "curated-songs";

/**
 * Warm-up song of an arena (see supabase/sql/warmup_song_2026-10-26.sql).
 *
 * start_arena_battles sets warmup_started_at; from then on the warm-up is the
 * first song of the session and battle 1 lasts its duration. Until Spotify
 * (roadmap steps 5/6/18) the host's browser is the provisional playback
 * device: only the host gets the audio path, and storage only signs it while
 * the arena is active.
 *
 * Playback/"now playing" timing is display-only, derived from the backend
 * warmup_started_at -- it never gates votes or battle transitions.
 */
export function useArenaWarmup(arenaId: string | undefined, arenaState: string | undefined, isHost: boolean) {
  const [warmup, setWarmup] = useState<ArenaWarmup | null>(null);
  const [isPlayingWindow, setIsPlayingWindow] = useState(false);
  const [needsTap, setNeedsTap] = useState(false);
  const audioRef = useRef<HTMLAudioElement | null>(null);

  // Re-read on arena state changes (waiting -> active sets started_at)
  useEffect(() => {
    if (!arenaId) return;
    let cancelled = false;
    getArenaWarmup(arenaId)
      .then((row) => {
        if (!cancelled) setWarmup(row);
      })
      .catch(() => {
        if (!cancelled) setWarmup(null);
      });
    return () => {
      cancelled = true;
    };
  }, [arenaId, arenaState]);

  const startedAtMs = warmup?.started_at ? new Date(warmup.started_at).getTime() : null;
  const endsAtMs = startedAtMs !== null ? startedAtMs + warmup.duration_ms : null;

  // "Now playing" window for every viewer
  useEffect(() => {
    if (endsAtMs === null || arenaState !== "active") {
      setIsPlayingWindow(false);
      return;
    }
    const remaining = endsAtMs - Date.now();
    setIsPlayingWindow(remaining > 0);
    if (remaining <= 0) return;
    const timeout = setTimeout(() => setIsPlayingWindow(false), remaining);
    return () => clearTimeout(timeout);
  }, [endsAtMs, arenaState]);

  const stopAudio = useCallback(() => {
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.src = "";
      audioRef.current = null;
    }
    setNeedsTap(false);
  }, []);

  const playFromServerOffset = useCallback(async () => {
    const audio = audioRef.current;
    if (!audio || startedAtMs === null) return;
    const elapsedSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
    try {
      audio.currentTime = elapsedSeconds;
      await audio.play();
      setNeedsTap(false);
    } catch (err) {
      // Autoplay blocked (e.g. host reloaded the page): ask for a tap
      console.warn("[useArenaWarmup] playback needs a user gesture:", err);
      setNeedsTap(true);
    }
  }, [startedAtMs]);

  // Host playback: only while the arena is active and the warm-up is still running
  const audioPath = warmup?.audio_storage_path ?? null;
  useEffect(() => {
    if (!isHost || !audioPath || !isPlayingWindow) {
      stopAudio();
      return;
    }

    let cancelled = false;
    const run = async () => {
      const expiresIn = Math.ceil(warmup.duration_ms / 1000) + 600;
      const { data, error } = await supabase.storage.from(WARMUP_BUCKET).createSignedUrl(audioPath, expiresIn);
      if (cancelled) return;
      if (error || !data?.signedUrl) {
        console.error("[useArenaWarmup] could not sign warm-up audio:", error);
        return;
      }
      const audio = new Audio(data.signedUrl);
      audio.preload = "auto";
      audio.addEventListener("ended", stopAudio);
      audioRef.current = audio;
      await playFromServerOffset();
    };

    run();
    return () => {
      cancelled = true;
      stopAudio();
    };
  }, [isHost, audioPath, isPlayingWindow, warmup?.duration_ms, stopAudio, playFromServerOffset]);

  return {
    warmup,
    isWarmupPlaying: isPlayingWindow,
    needsTap,
    resumeWarmup: playFromServerOffset,
  };
}
