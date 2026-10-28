import { useState } from "react";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import { ArenaPlayback, ControlMode, setArenaControlMode } from "@/integrations/supabase/spotify";

interface Props {
  arenaId: string;
  playback: ArenaPlayback | null;
  isHost: boolean;
}

/**
 * What the host's Spotify is playing for the arena (step 18): the warm-up or a
 * winner, the next one, and for the host the "you changed the music" prompt /
 * manual-control state. Display only: the backend decides what plays. Minimal
 * markup; visual design is done in Lovable.
 */
const NowPlaying = ({ arenaId, playback, isHost }: Props) => {
  const [error, setError] = useState("");
  if (!playback || playback.paused_at) return null;

  const setMode = (mode: ControlMode) => {
    setError("");
    setArenaControlMode(arenaId, mode).catch((err) => setError(err instanceof Error ? err.message : String(err)));
  };

  return (
    <div className="flex flex-col gap-2">
      {playback.now_playing_title && playback.now_playing_spotify_track_id ? (
        <SpotifyTrackRow
          track={{
            title: playback.now_playing_title,
            artist: playback.now_playing_artist ?? "",
            artwork_url: playback.now_playing_artwork_url,
            spotify_url: `https://open.spotify.com/track/${playback.now_playing_spotify_track_id}`,
          }}
          details={
            <p className="text-[10px] uppercase tracking-wide text-muted-foreground">
              {playback.now_playing_kind === "warmup" ? "Now playing · warm-up" : "Now playing · winner"}
              {playback.next_title ? ` · next: ${playback.next_title}` : ""}
            </p>
          }
        />
      ) : playback.player_context === "other" ? (
        <p className="text-xs text-muted-foreground">Spotify is playing its own picks until the next winner.</p>
      ) : null}

      {isHost && playback.manual_change_at && playback.control_mode !== "manual" && (
        <div className="neon-panel rounded-xl px-3 py-2 text-xs">
          <p className="text-foreground">
            The music changed in Spotify, so Music Fighter put the arena's song back. Do you want to control the
            music yourself? Music Fighter will follow your skips.
          </p>
          <div className="mt-2 flex gap-2">
            <button onClick={() => setMode("manual")} className="px-3 py-1 rounded-full bg-primary text-primary-foreground font-bold">
              I'll control it
            </button>
            <button onClick={() => setMode("auto")} className="px-3 py-1 rounded-full hud-chip">
              Keep automatic
            </button>
          </div>
        </div>
      )}

      {isHost && playback.control_mode === "manual" && (
        <p className="text-xs text-muted-foreground">
          You control the music: skips move the battle on.{" "}
          <button onClick={() => setMode("auto")} className="underline font-bold">
            Back to automatic
          </button>
        </p>
      )}

      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
};

export default NowPlaying;
