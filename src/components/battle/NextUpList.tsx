import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import { NextUpSong } from "@/integrations/supabase/proposals";

const timeLabel = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

const detail = (song: NextUpSong): string => {
  if (song.available_at) return `Can play again at ${timeLabel(song.available_at)}`;
  const parts: string[] = [];
  if (song.pair_no === 1) parts.push(song.vs_system ? "Next battle · vs a song picked by the system" : "Next battle");
  if (song.is_mine) parts.push("Your song");
  return parts.join(" · ");
};

/**
 * Step 17: the next 10 songs in the order matchmaking would send them to
 * fight (style continuity with the music playing, fair turns). Read-only.
 */
const NextUpList = ({ songs }: { songs: NextUpSong[] }) => (
  <div>
    <p className="neon-label mb-3">Next up to fight</p>
    <ol className="space-y-2 pr-4">
      {songs.map((song) => {
        const label = detail(song);
        return (
          <li key={song.song_id} className="flex items-center gap-2">
            <span
              className={`w-6 flex-shrink-0 text-center text-sm font-bold tabular-nums ${
                song.pair_no === 1 ? "text-song-a" : "text-muted-foreground"
              }`}
            >
              {song.pos}
            </span>
            <div className="flex-1 min-w-0">
              <SpotifyTrackRow
                track={{ ...song, spotify_url: `https://open.spotify.com/track/${song.spotify_track_id}` }}
                details={label ? <p className="text-xs text-song-a truncate">{label}</p> : undefined}
              />
            </div>
          </li>
        );
      })}
    </ol>
  </div>
);

export default NextUpList;
