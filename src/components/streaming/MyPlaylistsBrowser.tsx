import { useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, Heart, ListMusic, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  getMyPlaylists,
  getPlaylistTracks,
  SpotifyHostError,
  SpotifyPlaylist,
  SpotifyTrack,
  startSpotifyConnect,
} from "@/integrations/supabase/spotify";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";

interface Props {
  arenaId: string;
  // The connection predates step 7 (no playlist-read-private / user-library-read)
  needsReconnect: boolean;
  selectedTrackId: string | null;
  onSelect: (track: SpotifyTrack) => void;
}

/**
 * The member's own Spotify library (Liked Songs + owned/collaborative
 * playlists), only to pick a song to propose (step 7). Read live through
 * spotify-host with their own token; nothing is stored. Minimal markup; the
 * visual pass is done in Lovable.
 */
const MyPlaylistsBrowser = ({ arenaId, needsReconnect, selectedTrackId, onSelect }: Props) => {
  const [playlists, setPlaylists] = useState<SpotifyPlaylist[] | null>(null);
  const [open, setOpen] = useState<SpotifyPlaylist | null>(null);
  const [tracks, setTracks] = useState<SpotifyTrack[]>([]);
  const [nextOffset, setNextOffset] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [reconnect, setReconnect] = useState(needsReconnect);

  const fail = (err: unknown) => {
    if (err instanceof SpotifyHostError && err.code === "needs_reconnect") return setReconnect(true);
    setError(err instanceof Error ? err.message : String(err));
  };

  useEffect(() => {
    if (reconnect) return;
    let cancelled = false;
    getMyPlaylists(arenaId)
      .then((rows) => !cancelled && setPlaylists(rows))
      .catch((err) => !cancelled && fail(err));
    return () => {
      cancelled = true;
    };
  }, [arenaId, reconnect]);

  const loadTracks = async (playlist: SpotifyPlaylist, offset: number) => {
    setLoading(true);
    setError("");
    try {
      const page = await getPlaylistTracks(arenaId, playlist.id, offset);
      setTracks((prev) => (offset === 0 ? page.tracks : [...prev, ...page.tracks]));
      setNextOffset(page.next_offset);
    } catch (err) {
      fail(err);
    } finally {
      setLoading(false);
    }
  };

  const openPlaylist = (playlist: SpotifyPlaylist) => {
    setOpen(playlist);
    setTracks([]);
    setNextOffset(null);
    loadTracks(playlist, 0);
  };

  if (reconnect) {
    return (
      <div className="h-full flex flex-col items-center justify-center gap-3 text-center px-6">
        <p className="text-sm text-text-secondary">
          Reconnect Spotify to propose from your playlists and Liked Songs.
        </p>
        <Button
          className="w-full"
          onClick={() => startSpotifyConnect(window.location.pathname).catch((err) => setError(err.message))}
        >
          Reconnect Spotify
        </Button>
        {error && <p className="text-sm text-destructive">{error}</p>}
      </div>
    );
  }

  if (!open) {
    if (!playlists) {
      return error ? (
        <p className="text-sm text-center text-destructive">{error}</p>
      ) : (
        <div className="flex justify-center py-6">
          <Loader2 className="w-5 h-5 animate-spin text-muted-foreground" />
        </div>
      );
    }
    return (
      <ScrollArea className="h-full">
        <div className="space-y-2 pr-4">
          {playlists.map((playlist) => {
            const isLiked = playlist.id === "liked";
            return (
              <div
                key={playlist.id}
                role="button"
                onClick={() => openPlaylist(playlist)}
                className="flex items-center gap-3 p-2 pr-2.5 rounded-xl cursor-pointer transition-all neon-row hover:border-song-a/60"
              >
                {isLiked ? (
                  <div className="w-12 h-12 flex-shrink-0 rounded-md flex items-center justify-center bg-gradient-to-br from-nebula-glow/70 via-song-b/50 to-song-a/40">
                    <Heart className="w-5 h-5 text-foreground" fill="currentColor" />
                  </div>
                ) : playlist.artwork_url ? (
                  <img
                    src={playlist.artwork_url}
                    alt=""
                    className="w-12 h-12 flex-shrink-0 rounded-md object-contain bg-background/60"
                  />
                ) : (
                  <div className="w-12 h-12 flex-shrink-0 rounded-md bg-muted/60 flex items-center justify-center">
                    <ListMusic className="w-5 h-5 text-muted-foreground" />
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold text-foreground truncate">{playlist.name}</p>
                  <p className="flex items-center gap-1 text-xs text-muted-foreground min-w-0">
                    <SpotifyIcon className="w-3 h-3 flex-shrink-0 text-[#1DB954]" />
                    <span className="truncate tabular-nums">{playlist.total} songs</span>
                  </p>
                </div>
                <a
                  href={playlist.spotify_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  onClick={(e) => e.stopPropagation()}
                  className={SPOTIFY_LINK_CLASS}
                >
                  <SpotifyIcon className="w-3.5 h-3.5" />
                  Open Spotify
                </a>
                <ChevronRight className="w-4 h-4 flex-shrink-0 text-muted-foreground" />
              </div>
            );
          })}
          {playlists.length === 1 && (
            <p className="text-xs text-muted-foreground text-center">
              Only playlists you own or collaborate on can be opened.
            </p>
          )}
        </div>
      </ScrollArea>
    );
  }

  return (
    <div className="h-full flex flex-col gap-2">
      <div className="flex-shrink-0 flex items-center gap-2 neon-row rounded-xl p-1.5 pr-2.5">
        <button
          onClick={() => setOpen(null)}
          aria-label="Back to my playlists"
          className="w-8 h-8 flex-shrink-0 rounded-lg flex items-center justify-center text-text-secondary hover:text-foreground hover:bg-muted/60 transition-colors"
        >
          <ChevronLeft className="h-5 w-5" />
        </button>
        {open.id === "liked" && <Heart className="w-4 h-4 flex-shrink-0 text-song-b" fill="currentColor" />}
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-foreground truncate">{open.name}</p>
          <p className="flex items-center gap-1 text-[11px] text-muted-foreground">
            <SpotifyIcon className="w-3 h-3 flex-shrink-0 text-[#1DB954]" />
            <span className="tabular-nums">{open.total} songs</span>
          </p>
        </div>
      </div>
      <ScrollArea className="flex-1 min-h-0">
        <div className="space-y-2 pr-4">
          {tracks.map((track) => (
            <SpotifyTrackRow
              key={track.spotify_track_id}
              track={track}
              selected={selectedTrackId === track.spotify_track_id}
              onSelect={() => onSelect(track)}
            />
          ))}
          {!loading && tracks.length === 0 && !error && (
            <p className="text-sm text-center text-muted-foreground">No songs that can be proposed here</p>
          )}
          {loading && (
            <div className="flex justify-center py-3">
              <Loader2 className="w-5 h-5 animate-spin text-muted-foreground" />
            </div>
          )}
          {!loading && nextOffset !== null && (
            <div className="flex justify-center pt-1 pb-2">
              <Button
                variant="ghost"
                size="sm"
                className="rounded-full border border-border/70 px-4 text-xs text-text-secondary hover:text-foreground hover:border-song-a/60"
                onClick={() => loadTracks(open, nextOffset)}
              >
                Load more
              </Button>
            </div>
          )}
          {error && <p className="text-sm text-center text-destructive">{error}</p>}
        </div>
      </ScrollArea>
    </div>
  );
};

export default MyPlaylistsBrowser;
