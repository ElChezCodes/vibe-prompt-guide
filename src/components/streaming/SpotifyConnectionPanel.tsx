import { useState } from "react";
import { AlertTriangle, BadgeCheck, Check, HelpCircle, Loader2, MonitorSpeaker, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useSpotifyConnection } from "@/hooks/useSpotifyConnection";
import { isEmbedded } from "@/integrations/supabase/spotify";
import { SpotifyIcon, SPOTIFY_LINK_CLASS } from "@/components/streaming/SpotifyTrackRow";

// Spotify's own app links (Design Guidelines: "OPEN SPOTIFY")
const OPEN_SPOTIFY_URL = "https://open.spotify.com";
const SPOTIFY_APPS_URL = "https://www.spotify.com/account/apps/";

interface Props {
  // Where /spotify/callback returns after Spotify's consent screen
  returnTo: string;
}

/**
 * The user's Spotify connection (hosting + step 7 proposing from their library): connect, Premium status, devices (which one is
 * active, which one MF will use), disconnect. Functional/minimal markup; the
 * visual pass is done in Lovable.
 */
const SpotifyConnectionPanel = ({ returnTo }: Props) => {
  const { status, error, busy, connect, selectDevice, disconnect } = useSpotifyConnection();
  const [confirmDisconnect, setConfirmDisconnect] = useState(false);

  if (!status) {
    return (
      <div className="flex justify-center py-6" role="status" aria-label="Loading Spotify">
        <span className="relative w-12 h-12 rounded-2xl bg-background/70 border border-border/70 flex items-center justify-center">
          <SpotifyIcon className="w-6 h-6 text-[#1DB954]" />
          <span className="absolute -bottom-1.5 -right-1.5 w-5 h-5 rounded-full bg-secondary border border-border flex items-center justify-center">
            <Loader2 className="w-3 h-3 text-song-a motion-safe:animate-spin" />
          </span>
        </span>
      </div>
    );
  }

  if (!status.connected) {
    return (
      <div className="space-y-3">
        <div className="flex items-start gap-3 neon-row rounded-xl p-3">
          <span className="w-10 h-10 flex-shrink-0 rounded-lg bg-background/70 border border-border/70 flex items-center justify-center">
            <SpotifyIcon className="w-5 h-5 text-[#1DB954]" />
          </span>
        <p className="text-sm text-text-secondary leading-relaxed">
          Music Fighter curates a private playlist in your Spotify account and plays it on your own device. You need
          Spotify Premium.
        </p>
        </div>
        <Button className="w-full h-12 font-bold" disabled={busy} onClick={() => connect(returnTo)}>
          {busy ? <Loader2 className="w-5 h-5 mr-2 animate-spin" /> : null}
          Connect Spotify
        </Button>
        {error && (
          <p role="alert" className="flex items-start gap-2 rounded-xl border border-destructive/50 bg-destructive/10 px-3 py-2.5 text-sm text-destructive">
            <AlertTriangle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <span className="min-w-0 break-words">{error}</span>
          </p>
        )}
        {isEmbedded() && (
          <a
            href={window.location.href}
            target="_blank"
            rel="noopener noreferrer"
            className="block text-center text-sm underline text-text-secondary"
          >
            Open the app in a new tab
          </a>
        )}
      </div>
    );
  }

  const devices = status.devices ?? [];

  return (
    <div className="space-y-4">
      {/* Account card + Premium status line */}
      <div className="neon-row rounded-xl p-3 space-y-3">
        <div className="flex items-center gap-3">
          <span className="w-10 h-10 flex-shrink-0 rounded-lg bg-background/70 border border-border/70 flex items-center justify-center">
            <SpotifyIcon className="w-5 h-5 text-[#1DB954]" />
          </span>
          <div className="flex-1 min-w-0">
            <p className="text-[11px] uppercase tracking-widest text-muted-foreground">Spotify</p>
            <p className="font-semibold text-foreground truncate">{status.display_name}</p>
          </div>
          <span className="flex-shrink-0 inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium text-primary bg-primary/10 border border-primary/40">
            <span className="w-1.5 h-1.5 rounded-full bg-primary shadow-[0_0_6px_hsl(var(--primary))]" />
            Connected
          </span>
        </div>

        {/* Premium: only the player API can tell (GET /me no longer returns it) */}
        {status.premium_status === "not_premium" && (
          <p role="alert" className="flex items-start gap-2 rounded-lg border border-destructive/60 bg-destructive/15 px-3 py-2.5 text-sm font-medium text-destructive shadow-[0_0_16px_-6px_hsl(var(--destructive)/0.8)]">
            <AlertTriangle className="w-5 h-5 flex-shrink-0" />
            <span>This Spotify account isn't Premium. Music Fighter can't play on it: switch to a Premium account.</span>
          </p>
        )}
        {status.premium_status === "unverified" && (
          <p className="flex items-start gap-2 rounded-lg border border-dashed border-border px-3 py-2 text-xs text-muted-foreground">
            <HelpCircle className="w-4 h-4 flex-shrink-0 text-energy-yellow" />
            Premium not verified yet: pick a device below to check it.
          </p>
        )}
        {status.premium_status === "premium" && (
          <p className="inline-flex items-center gap-1.5 rounded-full border border-primary/40 bg-primary/10 px-2.5 py-1 text-xs font-semibold text-primary">
            <BadgeCheck className="w-4 h-4 flex-shrink-0" />
            Premium account
          </p>
        )}
      </div>

      {/* Step 7 / likes: older connections lack the library scopes (soft re-consent) */}
      {(status.can_read_library === false || status.can_save_likes === false || status.can_check_market === false) && (
        <div className="rounded-xl border border-energy-yellow/50 bg-energy-yellow/10 p-3 space-y-3">
          <div className="flex items-start gap-2">
            <span className="w-8 h-8 flex-shrink-0 rounded-lg bg-energy-yellow/15 flex items-center justify-center">
              <RefreshCw className="w-4 h-4 text-energy-yellow" />
            </span>
            <p className="text-xs leading-relaxed text-text-secondary">
              Reconnect Spotify to propose songs from your playlists and Liked Songs, to save the songs you like
              in Music Fighter to your Liked Songs, and so Music Fighter can spot songs that aren't available in
              your country.
            </p>
          </div>
          <Button variant="neon" size="sm" className="w-full" disabled={busy} onClick={() => connect(returnTo)}>
            Reconnect Spotify
          </Button>
        </div>
      )}

      {/* Devices */}
      <div className="space-y-2">
        <div className="flex items-center justify-between gap-2">
          <p className="neon-label">Playback device</p>
          <a
            href={OPEN_SPOTIFY_URL}
            target="_blank"
            rel="noopener noreferrer"
            className={SPOTIFY_LINK_CLASS}
          >
            <SpotifyIcon className="w-3.5 h-3.5" />
            OPEN SPOTIFY
          </a>
        </div>
        {status.preferred_device_id && !status.preferred_device_available && (
          <p className="flex items-start gap-2 rounded-lg border border-destructive/50 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            <AlertTriangle className="w-4 h-4 flex-shrink-0" />
            "{status.preferred_device_name}" isn't available. Open Spotify on it, or pick another device.
          </p>
        )}
        {devices.length === 0 && (
          <p className="text-xs text-muted-foreground rounded-xl border border-dashed border-border px-3 py-4 text-center">
            No devices found. Open Spotify on the phone, computer or speaker that will play the music.
          </p>
        )}
        {devices.map((device) => {
          const isPreferred = device.id === status.preferred_device_id;
          const unusable = busy || device.is_restricted;
          return (
            <button
              key={device.id}
              type="button"
              aria-pressed={isPreferred}
              aria-disabled={device.is_restricted || undefined}
              disabled={isPreferred || unusable}
              onClick={() => selectDevice(device.id)}
              className={`w-full text-left rounded-xl px-3 py-2.5 flex items-center gap-3 transition-all disabled:cursor-default ${
                isPreferred
                  ? "neon-row-selected"
                  : device.is_restricted
                    ? "border border-dashed border-border/70 bg-transparent opacity-50 disabled:cursor-not-allowed"
                    : "neon-row hover:border-song-a/60"
              }`}
            >
              <span
                className={`w-9 h-9 flex-shrink-0 rounded-lg flex items-center justify-center ${
                  isPreferred ? "bg-primary/20 text-primary" : "bg-muted/60 text-muted-foreground"
                }`}
              >
                <MonitorSpeaker className="w-4 h-4" />
              </span>
              <span className="flex-1 min-w-0">
                <span className="block text-sm font-medium text-foreground truncate">{device.name}</span>
                <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                  <span className="truncate">{device.type}</span>
                  {device.is_active && (
                    <span className="inline-flex items-center gap-1 text-primary flex-shrink-0">
                      <span className="w-1.5 h-1.5 rounded-full bg-primary motion-safe:animate-pulse" />
                      active now
                    </span>
                  )}
                  {device.is_restricted && <span className="flex-shrink-0">· can't be controlled</span>}
                </span>
              </span>
              {isPreferred ? (
                <span className="flex-shrink-0 inline-flex items-center gap-1 text-xs font-semibold text-primary">
                  <Check className="w-4 h-4" strokeWidth={3} />
                  Selected
                </span>
              ) : (
                !device.is_restricted && (
                  <span className="flex-shrink-0 rounded-full border border-song-a/50 px-2.5 py-1 text-xs font-semibold text-song-a">Use this</span>
                )
              )}
            </button>
          );
        })}
      </div>

      {error && (
        <p role="alert" className="flex items-start gap-2 rounded-xl border border-destructive/50 bg-destructive/10 px-3 py-2.5 text-sm text-destructive">
          <AlertTriangle className="w-4 h-4 mt-0.5 flex-shrink-0" />
          <span className="min-w-0 break-words">{error}</span>
        </p>
      )}

      {/* Disconnect deletes every Spotify datum we hold (Developer Policy I.1.2) */}
      {confirmDisconnect ? (
        <div className="space-y-3 rounded-xl border border-destructive/50 bg-destructive/10 p-3">
          <p className="flex items-start gap-2 text-sm text-text-secondary">
            <AlertTriangle className="w-4 h-4 mt-0.5 flex-shrink-0 text-destructive" />
            <span className="min-w-0">
            This deletes your Spotify tokens and data from Music Fighter. To also remove the app's access, go to{" "}
            <a href={SPOTIFY_APPS_URL} target="_blank" rel="noopener noreferrer" className="underline text-foreground break-all">
              spotify.com/account/apps
            </a>
            .
            </span>
          </p>
          <div className="flex gap-2">
            <Button
              variant="ghost"
              className="flex-1 bg-destructive text-destructive-foreground hover:bg-destructive/90 font-bold glow-destructive"
              disabled={busy}
              onClick={async () => {
                await disconnect();
                setConfirmDisconnect(false);
              }}
            >
              Disconnect
            </Button>
            <Button variant="ghost" className="flex-1 border border-border/70" onClick={() => setConfirmDisconnect(false)}>
              Cancel
            </Button>
          </div>
        </div>
      ) : (
        <Button
          variant="ghost"
          className="w-full text-muted-foreground hover:text-destructive hover:bg-destructive/10"
          onClick={() => setConfirmDisconnect(true)}
        >
          Disconnect Spotify
        </Button>
      )}
    </div>
  );
};

export default SpotifyConnectionPanel;
