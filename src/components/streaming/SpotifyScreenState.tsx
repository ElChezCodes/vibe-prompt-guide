import { ReactNode } from "react";
import { AlertTriangle, Loader2 } from "lucide-react";
import { SpotifyIcon } from "@/components/streaming/SpotifyTrackRow";

// Presentational loading / error card shared by the Spotify screens, so they
// look like the connection panel (same tile, spinner and warning box).
const SpotifyScreenState = ({
  message,
  isError = false,
  children,
}: {
  message: string;
  isError?: boolean;
  children?: ReactNode;
}) => (
  <div className="min-h-dvh w-full flex flex-col items-center justify-center space-bg px-4">
    <div className="neon-panel rounded-2xl p-5 w-full max-w-sm flex flex-col items-center gap-4 text-center motion-safe:animate-fade-in">
      <span className="relative w-14 h-14 rounded-2xl bg-background/70 border border-border/70 flex items-center justify-center">
        <SpotifyIcon className="w-7 h-7 text-[#1DB954]" />
        {isError ? (
          <span className="absolute -bottom-1.5 -right-1.5 w-6 h-6 rounded-full bg-destructive text-destructive-foreground flex items-center justify-center">
            <AlertTriangle className="w-3.5 h-3.5" />
          </span>
        ) : (
          <span className="absolute -bottom-1.5 -right-1.5 w-6 h-6 rounded-full bg-secondary border border-border flex items-center justify-center">
            <Loader2 className="w-3.5 h-3.5 text-song-a motion-safe:animate-spin" />
          </span>
        )}
      </span>
      {isError ? (
        <p role="alert" className="w-full rounded-xl border border-destructive/50 bg-destructive/10 px-3 py-2.5 text-sm font-medium text-destructive">
          {message}
        </p>
      ) : (
        <p role="status" className="text-sm text-text-secondary">{message}</p>
      )}
      {children}
    </div>
  </div>
);

export default SpotifyScreenState;
