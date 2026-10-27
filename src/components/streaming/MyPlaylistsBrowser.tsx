import { useEffect, useState } from "react";
import { ChevronLeft, Heart, Loader2 } from "lucide-react";
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
          {playlists.map((playlist) => (
            <div key={playlist.id} className="relative">
              <SpotifyTrackRow
                track={{
                  title: playlist.name,
                  artist: `${playlist.total} songs`,
                  artwork_url: playlist.artwork_url,
                  spotify_url: playlist.spotify_url,
                }}
                onSelect={() => openPlaylist(playlist)}
              />
              {playlist.id === "liked" && (
                <Heart className="absolute left-5 top-1/2 -translate-y-1/2 h-5 w-5 text-song-b pointer-events-none" />
              )}
            </div>
          ))}
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
      <button
        onClick={() => setOpen(null)}
        className="flex-shrink-0 flex items-center gap-1 text-sm text-text-secondary hover:text-foreground"
      >
        <ChevronLeft className="h-4 w-4" />
        <span className="truncate">{open.name}</span>
      </button>
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
            <Button variant="ghost" className="w-full" onClick={() => loadTracks(open, nextOffset)}>
              Load more
            </Button>
          )}
          {error && <p className="text-sm text-center text-destructive">{error}</p>}
        </div>
      </ScrollArea>
    </div>
  );
};

export default MyPlaylistsBrowser;
