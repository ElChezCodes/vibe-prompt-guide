import { useEffect, useState } from "react";
import { Heart } from "lucide-react";
import { QRCodeSVG } from "qrcode.react";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import { ArenaPlayback, ControlMode, setArenaControlMode } from "@/integrations/supabase/spotify";

interface Props {
  arenaId: string;
  playback: ArenaPlayback | null;
  isHost: boolean;
  // Like the song playing now (user request 2026-11-01), same as the battle
  // cards' like: mirrored in the liker's own Spotify Liked Songs, removed on
  // unlike if MF added it. Never a vote (the song isn't in the open battle).
  likedSongIds?: Set<string>;
  onToggleLike?: (songId: string) => void;
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
const NowPlaying = ({ arenaId, playback, isHost, likedSongIds, onToggleLike }: Props) => {
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  // The mode the host just chose, until a poll of get_arena_playback shows it
  const [chosenMode, setChosenMode] = useState<ControlMode | null>(null);
  // The put-back the host already answered (a newer one asks again)
  const [answeredChangeAt, setAnsweredChangeAt] = useState<string | null>(null);
  const [confirmAuto, setConfirmAuto] = useState(false);
  const [showQr, setShowQr] = useState(false);

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

  const nowSongId = playback.now_playing_song_id;
  const spotifyUrl = `https://open.spotify.com/track/${playback.now_playing_spotify_track_id}`;
  const isLiked = !!nowSongId && !!likedSongIds?.has(nowSongId);

  const showPrompt =
    isHost && !!playback.manual_change_at && mode !== "manual" && playback.manual_change_at !== answeredChangeAt;

  return (
    <div className="flex flex-col gap-1.5 w-full max-w-md mx-auto">
      {playback.now_playing_title && playback.now_playing_spotify_track_id ? (
        <div className="neon-row rounded-xl px-2 py-1.5 backdrop-blur-md">
          <SpotifyTrackRow
            size="lg"
            marquee
            stackAction
            track={{
              title: playback.now_playing_title,
              artist: playback.now_playing_artist ?? "",
              artwork_url: playback.now_playing_artwork_url,
              spotify_url: spotifyUrl,
            }}
            details={
              <p className="mt-0.5 text-[11px] uppercase tracking-wider text-muted-foreground truncate flex items-center gap-1.5">
                <span className="relative flex h-1.5 w-1.5 shrink-0">
                  <span className="absolute inline-flex h-full w-full rounded-full bg-primary opacity-60 animate-ping" />
                  <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-primary" />
                </span>
                <span className="text-primary font-semibold">
                  {playback.now_playing_kind === "warmup" ? "Warm-up" : "Winner"}
                </span>
                {playback.next_title ? <span className="truncate">· next: {playback.next_title}</span> : null}
              </p>
            }
            action={
              <div className="flex items-center gap-1">
                {/* The QR to this song (user, 2026-11-06). Too small to scan here:
                    a tap enlarges it, so someone else can scan it from this phone */}
                <button
                  type="button"
                  onClick={(e) => {
                    e.stopPropagation();
                    setShowQr(true);
                  }}
                  aria-label="Show this song's QR"
                  className="bg-white rounded p-0.5"
                >
                  <QRCodeSVG value={spotifyUrl} size={28} marginSize={0} />
                </button>
                {onToggleLike && nowSongId ? (
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      onToggleLike(nowSongId);
                    }}
                    aria-pressed={isLiked}
                    aria-label={isLiked ? "Unlike song" : "Like song"}
                    className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-text-secondary hover:text-foreground transition-colors"
                  >
                    <Heart className={`h-3.5 w-3.5 ${isLiked ? "fill-primary text-primary" : ""}`} />
                    <span className="hidden min-[380px]:inline">{isLiked ? "Liked" : "Like"}</span>
                  </button>
                ) : null}
              </div>
            }
          />
          <Dialog open={showQr} onOpenChange={setShowQr}>
            <DialogContent className="max-w-xs">
              <DialogTitle className="truncate">{playback.now_playing_title}</DialogTitle>
              <DialogDescription>Scan to open this song in Spotify</DialogDescription>
              <div className="mx-auto bg-white rounded-xl p-3">
                <QRCodeSVG value={spotifyUrl} size={220} marginSize={1} />
              </div>
            </DialogContent>
          </Dialog>
        </div>
      ) : playback.player_context === "other" ? (
        <p className="neon-row rounded-full px-3 py-1.5 text-[11px] text-muted-foreground text-center">
          Spotify is playing its own picks until the next winner.
        </p>
      ) : null}

      {playback.unplayable_title && (
        <p className="text-[11px] text-muted-foreground text-center px-2">
          <span className="text-foreground">"{playback.unplayable_title}"</span> isn't available in the host's country: skipped.
        </p>
      )}

      {showPrompt && (
        <div className="rounded-xl border border-primary/40 bg-primary/10 px-3 py-2 text-[11px] leading-snug shadow-[0_0_16px_hsl(var(--primary)/0.15)]">
          <p className="text-foreground">
            <span className="font-bold text-primary">The music changed in Spotify</span>, so Music Fighter put the arena's song back. Do you want to control the
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
        <div className="self-center inline-flex items-center gap-2 rounded-full hud-chip px-3 py-1 text-[11px] text-muted-foreground">
          <span className="h-1.5 w-1.5 rounded-full bg-song-b shrink-0" />
          <span>{saving ? "Saving…" : "You control the music"}</span>
          <span className="opacity-40">·</span>
          <button onClick={() => setConfirmAuto(true)} disabled={saving} className="font-semibold text-foreground hover:text-primary disabled:opacity-50">
            Back to automatic
          </button>
        </div>
      )}

      {/* Cancel comes first, where the link was: a second click can't confirm by accident */}
      {isHost && mode === "manual" && confirmAuto && (
        <div className="rounded-xl border border-primary/40 bg-primary/10 px-3 py-2 text-[11px] leading-snug">
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
        <p className="text-[11px] text-muted-foreground text-center">Saving…</p>
      )}

      {error && <p className="text-[11px] text-destructive text-center">{error}</p>}
    </div>
  );
};

export default NowPlaying;
