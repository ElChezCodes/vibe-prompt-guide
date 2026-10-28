import { useEffect, useState } from "react";
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
 *
 * The host's answer shows at once (user request 2026-10-28: clicks that seemed
 * to do nothing for up to one poll were clicked again and landed on the other
 * option): buttons are disabled while it saves, and "Back to automatic" asks
 * for confirmation.
 */
const NowPlaying = ({ arenaId, playback, isHost }: Props) => {
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  // The mode the host just chose, until a poll of get_arena_playback shows it
  const [chosenMode, setChosenMode] = useState<ControlMode | null>(null);
  // The put-back the host already answered (a newer one asks again)
  const [answeredChangeAt, setAnsweredChangeAt] = useState<string | null>(null);
  const [confirmAuto, setConfirmAuto] = useState(false);

  const serverMode = playback?.control_mode ?? null;
  useEffect(() => {
    if (chosenMode && serverMode === chosenMode) setChosenMode(null);
  }, [serverMode, chosenMode]);

  const mode = chosenMode ?? serverMode;
  useEffect(() => {
    if (mode !== "manual") setConfirmAuto(false);
  }, [mode]);

  if (!playback || playback.paused_at) return null;

  const setMode = (next: ControlMode) => {
    if (saving) return;
    setError("");
    setSaving(true);
    setChosenMode(next);
    setAnsweredChangeAt(playback.manual_change_at);
    setConfirmAuto(false);
    setArenaControlMode(arenaId, next)
      .catch((err) => {
        setChosenMode(null);
        setAnsweredChangeAt(null);
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => setSaving(false));
  };

  const showPrompt =
    isHost && !!playback.manual_change_at && mode !== "manual" && playback.manual_change_at !== answeredChangeAt;

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

      {playback.unplayable_title && (
        <p className="text-xs text-muted-foreground">
          "{playback.unplayable_title}" isn't available in the host's country: skipped.
        </p>
      )}

      {showPrompt && (
        <div className="neon-panel rounded-xl px-3 py-2 text-xs">
          <p className="text-foreground">
            The music changed in Spotify, so Music Fighter put the arena's song back. Do you want to control the
            music yourself? Music Fighter will follow your skips.
          </p>
          <div className="mt-2 flex gap-2">
            <button
              onClick={() => setMode("manual")}
              disabled={saving}
              className="px-3 py-1 rounded-full bg-primary text-primary-foreground font-bold disabled:opacity-50"
            >
              I'll control it
            </button>
            <button onClick={() => setMode("auto")} disabled={saving} className="px-3 py-1 rounded-full hud-chip disabled:opacity-50">
              Keep automatic
            </button>
          </div>
        </div>
      )}

      {isHost && mode === "manual" && !confirmAuto && (
        <p className="text-xs text-muted-foreground">
          {saving ? "Saving… " : "You control the music: skips move the battle on. "}
          <button onClick={() => setConfirmAuto(true)} disabled={saving} className="underline font-bold disabled:opacity-50">
            Back to automatic
          </button>
        </p>
      )}

      {/* Cancel comes first, where the link was: a second click can't confirm by accident */}
      {isHost && mode === "manual" && confirmAuto && (
        <div className="neon-panel rounded-xl px-3 py-2 text-xs">
          <p className="text-foreground">
            Back to automatic? Music Fighter will put the arena's song back whenever the music changes in Spotify.
          </p>
          <div className="mt-2 flex gap-2">
            <button onClick={() => setConfirmAuto(false)} disabled={saving} className="px-3 py-1 rounded-full hud-chip disabled:opacity-50">
              Keep my control
            </button>
            <button
              onClick={() => setMode("auto")}
              disabled={saving}
              className="px-3 py-1 rounded-full bg-primary text-primary-foreground font-bold disabled:opacity-50"
            >
              Yes, automatic
            </button>
          </div>
        </div>
      )}

      {isHost && saving && mode === "auto" && (
        <p className="text-xs text-muted-foreground">Saving…</p>
      )}

      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
};

export default NowPlaying;
