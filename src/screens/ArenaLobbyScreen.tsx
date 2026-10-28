import { useEffect, useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { QRCodeSVG } from "qrcode.react";
import { Button } from "@/components/ui/button";
import { Swords, Loader2, Music, Monitor, Link2, Plug } from "lucide-react";
import {
  ArenaWarmup,
  formatDuration,
  getArenaWarmup,
  getMoodLabel,
  startArenaBattles,
} from "@/integrations/supabase/arenas";
import { ensureParticipant } from "@/integrations/supabase/participants";
import { supabase } from "@/integrations/supabase/client";
import { useArenaFromRoute } from "@/hooks/useArenaFromRoute";
import { useRefreshCurrentArena } from "@/hooks/useCurrentArena";
import EndArenaButton from "@/components/arena/EndArenaButton";
import ScreenMessage from "@/components/nav/ScreenMessage";
import { arenaPath, joinUrl, stageUrl } from "@/lib/arenaRoutes";
import { useArenaPresence } from "@/hooks/useArenaPresence";
import { useArenaQueueSummary } from "@/hooks/useArenaQueueSummary";
import {
  getMyStreamingConnection,
  PAUSE_REASON_LABELS,
  resumeSpotifyArena,
  SpotifyHostError,
  StreamingConnectionSummary,
} from "@/integrations/supabase/spotify";
import { useArenaPlayback } from "@/hooks/useArenaPlayback";

// What the host can do about each Start refusal (codes from spotify-host)
const START_ERRORS: Record<string, string> = {
  spotify_not_connected: "Connect your Spotify Premium account first",
  spotify_not_premium: "Spotify Premium is required to play the arena's playlist",
  no_device: "Open Spotify on the device that will play (phone, speaker, TV...) and pick it in Spotify settings",
  warmup_not_spotify: "This arena was created before Spotify; create a new arena",
  spotify_revoked: "Spotify access was removed; connect again",
};

// Host's arena panel: code/QR, Stage View, music connection, start/enter
// battles, End Arena. Non-hosts are sent to the Battle Room.
const ArenaLobbyScreen = () => {
  const navigate = useNavigate();
  const { code, arena, setArena, isHost, status } = useArenaFromRoute();
  const refreshCurrentArena = useRefreshCurrentArena();
  const [isLoading, setIsLoading] = useState(false);
  const [warmup, setWarmup] = useState<ArenaWarmup | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [linkCopied, setLinkCopied] = useState(false);
  // Host-level Spotify connection (stored summary; live devices on Connect)
  const [spotify, setSpotify] = useState<StreamingConnectionSummary | null>(null);

  const arenaId = arena?.id;
  const isOpen = arena?.state === "waiting" || arena?.state === "active";
  // Backend-computed presence counts (display only)
  const presence = useArenaPresence(arenaId, isHost && isOpen);
  // Songs proposed so far (step 12b); backup music covers the rest
  const queueSummary = useArenaQueueSummary(arenaId, isHost && isOpen);
  // Spotify playback / arena pause (decided server-side)
  const playback = useArenaPlayback(arenaId, isHost && arena?.state === "active");

  useEffect(() => {
    if (!arenaId || !isHost) return;
    getArenaWarmup(arenaId)
      .then(setWarmup)
      .catch(() => setWarmup(null));
  }, [arenaId, isHost]);

  useEffect(() => {
    if (!isHost) return;
    getMyStreamingConnection()
      .then(setSpotify)
      .catch(() => setSpotify(null));
  }, [isHost]);

  // The host is in the arena from the lobby on, so it becomes their current
  // arena ("Back to your arena", Arena tab) before battles start
  useEffect(() => {
    if (!arenaId || !isHost || !isOpen) return;
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session?.user) return;
      ensureParticipant(arenaId, session.user.id, true)
        .then(() => refreshCurrentArena())
        .catch(() => {});
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [arenaId, isHost, isOpen]);

  // Join resolves against arenas.arena_code, so display exactly that
  const arenaCode = arena?.arena_code
    ? arena.arena_code.replace(/(.{3})(.{3})/, '$1 $2')
    : '';
  const moodLabel = getMoodLabel(arena?.mood);
  const isClosed = !isOpen;

  const handleEnterBattle = async () => {
    if (!arenaId || !arena || isClosed || isLoading) return;

    setIsLoading(true);
    setErrorMessage("");

    try {
      // Backend: private playlist + warm-up on the host's device, then
      // waiting -> active and battle 1 (or the open battle when re-entering)
      await startArenaBattles(arenaId);
      navigate(arenaPath(code, "battle"));
    } catch (err) {
      console.error('Error starting battles:', err);
      setErrorMessage(
        err instanceof SpotifyHostError
          ? START_ERRORS[err.code] ?? err.message
          : "Failed to start battles",
      );
    } finally {
      setIsLoading(false);
    }
  };

  const handleCopyStageLink = async () => {
    try {
      await navigator.clipboard.writeText(stageUrl(code));
      setLinkCopied(true);
    } catch {
      setLinkCopied(false);
    }
  };

  if (status === "loading") return <ScreenMessage message="Loading..." showHomeButton={false} />;
  if (status === "not_found") return <ScreenMessage message="Arena not found" isError />;
  if (status === "error") return <ScreenMessage message="Failed to load arena" isError />;
  if (!isHost) return <Navigate to={arenaPath(code, "battle")} replace />;

  return (
    <div className="min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-md flex flex-col items-center gap-8">
        {/* Header */}
        <div className="text-center animate-fade-in-up">
          <h1 className="neon-heading text-2xl md:text-3xl mb-3 break-words">
            {arena.name || "Arena Created"}
          </h1>
          {moodLabel && (
            <p className="inline-block mb-2 px-3 py-1 rounded-full border border-song-b/50 bg-song-b/10 text-sm text-foreground">
              {moodLabel}
            </p>
          )}
          <p className="text-text-secondary">
            {isClosed ? "This arena has ended" : "Share the code with your guests"}
          </p>
        </div>

        {/* Warm-up: silent in the lobby, starts with the first battle */}
        {warmup && (
          <div
            className="w-full flex items-center gap-3 neon-panel rounded-xl px-4 py-3 animate-fade-in-up"
            style={{ animationDelay: "25ms" }}
          >
            <Music className="w-5 h-5 flex-shrink-0 text-primary icon-glow-primary" />
            <div className="flex-1 min-w-0">
              <p className="text-xs text-muted-foreground">Warm-up song · starts with the first battle</p>
              <p className="text-sm font-medium text-foreground truncate">
                {warmup.title} · {warmup.artist}
              </p>
            </div>
            <span className="flex-shrink-0 text-xs text-muted-foreground tabular-nums">
              {formatDuration(warmup.duration_ms)}
            </span>
          </div>
        )}

        {/* Arena Code Block */}
        <div
          className="w-full neon-panel rounded-2xl p-6 text-center animate-fade-in-up"
          style={{ animationDelay: "50ms" }}
        >
          <p className="neon-label mb-3">Arena Code</p>
          <p className="text-4xl md:text-5xl font-bold text-foreground tracking-[0.3em] font-mono text-glow-a">
            {arenaCode}
          </p>
        </div>

        {/* Who's here: ACTIVO / PASIVO / INACTIVO counts from the backend */}
        {!isClosed && presence && (
          <p className="text-sm text-muted-foreground tabular-nums">
            {presence.active_count} active · {presence.passive_count} passive · {presence.inactive_count} inactive
          </p>
        )}
        {!isClosed && queueSummary && (
          <p className="text-sm text-muted-foreground tabular-nums">
            {queueSummary.human_queued} {queueSummary.human_queued === 1 ? "song" : "songs"} proposed
            {queueSummary.human_queued < 2 && " · backup music fills the rest"}
          </p>
        )}

        {/* QR Code Block: opens /join/:code */}
        {!isClosed && (
          <div
            className="neon-panel rounded-2xl p-6 text-center animate-fade-in-up"
            style={{ animationDelay: "100ms" }}
          >
            <p className="neon-label mb-4">Scan to join</p>
            {/* QR stays black on white with a quiet zone so phones read it */}
            <div className="mx-auto bg-white rounded-xl p-4">
              <QRCodeSVG value={joinUrl(arena.arena_code)} size={176} marginSize={1} />
            </div>
          </div>
        )}

        {/* Venue screen + music connection */}
        {!isClosed && (
          <div className="w-full grid grid-cols-1 gap-3 animate-fade-in-up" style={{ animationDelay: "150ms" }}>
            <Button variant="neon" className="h-11 justify-start" onClick={() => window.open(stageUrl(code), "_blank", "noopener")}>
              <Monitor className="w-4 h-4 mr-2" />
              Open Stage View
            </Button>
            <Button variant="neon" className="h-11 justify-start" onClick={handleCopyStageLink}>
              <Link2 className="w-4 h-4 mr-2" />
              {linkCopied ? "Stage link copied" : "Copy Stage View link"}
            </Button>
            <Button variant="neon" className="h-11 justify-start" onClick={() => navigate(arenaPath(code, "connect"))}>
              <Plug className="w-4 h-4 mr-2" />
              {spotify
                ? `Spotify · ${spotify.display_name}${
                    spotify.premium_status === "not_premium"
                      ? " · not Premium"
                      : spotify.preferred_device_name
                        ? ` · ${spotify.preferred_device_name}`
                        : " · pick a device"
                  }`
                : "Connect Spotify"}
            </Button>
          </div>
        )}

        {/* Spotify playback of the running arena */}
        {arena.state === "active" && playback && (
          <div className="w-full neon-panel rounded-xl px-4 py-3 text-sm">
            {playback.paused_at ? (
              <>
                <p className="font-bold text-foreground">Arena paused</p>
                <p className="text-muted-foreground">
                  {PAUSE_REASON_LABELS[playback.pause_reason] ?? "Spotify isn't playing"}. It resumes by itself when
                  the music is back.
                </p>
                <Button
                  variant="neon"
                  size="sm"
                  className="mt-2"
                  onClick={() =>
                    resumeSpotifyArena(arena.id).catch((err) =>
                      setErrorMessage(
                        err instanceof SpotifyHostError ? START_ERRORS[err.code] ?? err.message : String(err),
                      ),
                    )
                  }
                >
                  Resume on Spotify
                </Button>
              </>
            ) : (
              <p className="text-muted-foreground">
                Spotify{playback.device_name ? ` · ${playback.device_name}` : ""}
                {playback.is_playing ? " · playing" : ""}
              </p>
            )}
            {playback.playlist_url && (
              <a
                href={playback.playlist_url}
                target="_blank"
                rel="noopener noreferrer"
                className="mt-1 inline-block text-xs font-bold uppercase text-[#1DB954]"
              >
                Open playlist in Spotify
              </a>
            )}
          </div>
        )}

        {/* Primary Action - Enter Battle */}
        {errorMessage && (
          <p className="text-sm text-destructive">{errorMessage}</p>
        )}

        {isClosed ? (
          <Button variant="neon" onClick={() => navigate("/")} className="w-full h-12">
            Back to start
          </Button>
        ) : (
          <>
            <Button
              onClick={handleEnterBattle}
              disabled={isLoading}
              className="w-full h-12 text-lg font-bold animate-fade-in-up"
              style={{ animationDelay: "200ms" }}
            >
              {isLoading ? (
                <Loader2 className="w-5 h-5 mr-2 animate-spin" />
              ) : (
                <Swords className="w-5 h-5 mr-2" />
              )}
              {isLoading ? "Creating Battle..." : arena.state === "waiting" ? "Start Battles" : "Enter Battle"}
            </Button>

            <EndArenaButton
              arenaId={arena.id}
              onEnded={() => setArena((prev) => (prev ? { ...prev, state: "finished" } : prev))}
            >
              <Button variant="ghost" className="w-full border border-destructive/40 text-destructive/90 hover:bg-destructive/10 hover:text-destructive">
                End Arena
              </Button>
            </EndArenaButton>
          </>
        )}
      </div>
    </div>
  );
};

export default ArenaLobbyScreen;
