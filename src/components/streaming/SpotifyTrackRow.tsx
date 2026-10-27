import { SpotifyTrack } from "@/integrations/supabase/spotify";
import { formatDuration } from "@/integrations/supabase/arenas";

// Spotify icon (Design Guidelines: logo next to Spotify metadata)
export const SpotifyIcon = ({ className = "h-4 w-4" }: { className?: string }) => (
  <svg viewBox="0 0 24 24" className={className} fill="currentColor" role="img" aria-label="Spotify">
    <path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z" />
  </svg>
);

interface Props {
  track: Pick<SpotifyTrack, "title" | "artist" | "artwork_url" | "spotify_url"> & { duration_ms?: number };
  selected?: boolean;
  onSelect?: () => void;
  disabled?: boolean;
}

/**
 * One Spotify track: artwork shown whole (never cropped or covered), title,
 * artist, the Spotify logo and an "Open Spotify" link back to the track
 * (Spotify Design Guidelines / Developer Policy II.4). Minimal markup; visual
 * design is done in Lovable.
 */
const SpotifyTrackRow = ({ track, selected = false, onSelect, disabled }: Props) => (
  <div
    onClick={disabled ? undefined : onSelect}
    role={onSelect ? "button" : undefined}
    aria-pressed={onSelect ? selected : undefined}
    className={`flex items-center gap-3 p-2 rounded-xl transition-all ${
      onSelect ? "cursor-pointer" : ""
    } ${selected ? "neon-row-selected" : "neon-row hover:border-song-a/60"}`}
  >
    {track.artwork_url ? (
      <img src={track.artwork_url} alt="" className="w-12 h-12 flex-shrink-0 rounded object-contain bg-black/40" />
    ) : (
      <div className="w-12 h-12 flex-shrink-0 rounded bg-muted/60" />
    )}
    <div className="flex-1 min-w-0">
      <p className="text-sm font-medium text-foreground truncate">{track.title}</p>
      <p className="text-xs text-muted-foreground truncate">{track.artist}</p>
    </div>
    {track.duration_ms ? (
      <span className="flex-shrink-0 text-xs text-muted-foreground tabular-nums">{formatDuration(track.duration_ms)}</span>
    ) : null}
    <a
      href={track.spotify_url}
      target="_blank"
      rel="noopener noreferrer"
      onClick={(e) => e.stopPropagation()}
      className="flex-shrink-0 flex items-center gap-1 text-[10px] font-bold uppercase tracking-wide text-[#1DB954]"
    >
      <SpotifyIcon />
      Open Spotify
    </a>
  </div>
);

export default SpotifyTrackRow;
