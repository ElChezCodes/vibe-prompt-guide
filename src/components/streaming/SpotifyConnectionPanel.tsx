import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useSpotifyConnection } from "@/hooks/useSpotifyConnection";
import { isEmbedded } from "@/integrations/supabase/spotify";

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
      <div className="flex justify-center py-6">
        <Loader2 className="w-5 h-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!status.connected) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-text-secondary">
          Music Fighter curates a private playlist in your Spotify account and plays it on your own device. You need
          Spotify Premium.
        </p>
        <Button className="w-full h-12 font-bold" disabled={busy} onClick={() => connect(returnTo)}>
          {busy ? <Loader2 className="w-5 h-5 mr-2 animate-spin" /> : null}
          Connect Spotify
        </Button>
        {error && <p className="text-sm text-destructive">{error}</p>}
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
      {/* Account */}
      <div className="neon-panel rounded-xl p-4 flex items-center justify-between gap-3">
        <div className="min-w-0">
          <p className="text-xs text-muted-foreground">Spotify</p>
          <p className="font-medium text-foreground truncate">{status.display_name}</p>
        </div>
        <span className="text-sm text-primary font-medium">Connected</span>
      </div>

      {/* Step 7: connections made before it lack the playlist/library scopes (soft re-consent) */}
      {status.can_read_library === false && (
        <div className="space-y-2">
          <p className="text-sm text-text-secondary">
            Reconnect Spotify to propose songs from your playlists and Liked Songs in any arena.
          </p>
          <Button variant="neon" className="w-full" disabled={busy} onClick={() => connect(returnTo)}>
            Reconnect Spotify
          </Button>
        </div>
      )}

      {/* Premium: only the player API can tell (GET /me no longer returns it) */}
      {status.premium_status === "not_premium" && (
        <p className="text-sm text-destructive">
          This Spotify account isn't Premium. Music Fighter can't play on it: switch to a Premium account.
        </p>
      )}
      {status.premium_status === "unverified" && (
        <p className="text-sm text-muted-foreground">Premium not verified yet: pick a device below to check it.</p>
      )}
      {status.premium_status === "premium" && <p className="text-sm text-muted-foreground">Premium account</p>}

      {/* Devices */}
      <div className="space-y-2">
        <p className="neon-label">Playback device</p>
        {status.preferred_device_id && !status.preferred_device_available && (
          <p className="text-sm text-destructive">
            "{status.preferred_device_name}" isn't available. Open Spotify on it, or pick another device.
          </p>
        )}
        {devices.length === 0 && (
          <p className="text-sm text-muted-foreground">
            No devices found. Open Spotify on the phone, computer or speaker that will play the music.
          </p>
        )}
        {devices.map((device) => {
          const isPreferred = device.id === status.preferred_device_id;
          return (
            <div key={device.id} className="neon-row rounded-lg px-3 py-2 flex items-center justify-between gap-3">
              <div className="min-w-0">
                <p className="text-sm font-medium text-foreground truncate">{device.name}</p>
                <p className="text-xs text-muted-foreground">
                  {device.type}
                  {device.is_active ? " · active now" : ""}
                  {device.is_restricted ? " · can't be controlled" : ""}
                </p>
              </div>
              {isPreferred ? (
                <span className="text-xs text-primary font-medium flex-shrink-0">Selected</span>
              ) : (
                <Button
                  size="sm"
                  variant="neon"
                  disabled={busy || device.is_restricted}
                  onClick={() => selectDevice(device.id)}
                >
                  Use this
                </Button>
              )}
            </div>
          );
        })}
        <a
          href={OPEN_SPOTIFY_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-block text-xs font-bold tracking-widest text-primary"
        >
          OPEN SPOTIFY
        </a>
      </div>

      {error && <p className="text-sm text-destructive">{error}</p>}

      {/* Disconnect deletes every Spotify datum we hold (Developer Policy I.1.2) */}
      {confirmDisconnect ? (
        <div className="space-y-2">
          <p className="text-sm text-text-secondary">
            This deletes your Spotify tokens and data from Music Fighter. To also remove the app's access, go to{" "}
            <a href={SPOTIFY_APPS_URL} target="_blank" rel="noopener noreferrer" className="underline">
              spotify.com/account/apps
            </a>
            .
          </p>
          <div className="flex gap-2">
            <Button
              variant="ghost"
              className="flex-1 border border-destructive/40 text-destructive"
              disabled={busy}
              onClick={async () => {
                await disconnect();
                setConfirmDisconnect(false);
              }}
            >
              Disconnect
            </Button>
            <Button variant="ghost" className="flex-1" onClick={() => setConfirmDisconnect(false)}>
              Cancel
            </Button>
          </div>
        </div>
      ) : (
        <Button
          variant="ghost"
          className="w-full text-muted-foreground hover:text-foreground"
          onClick={() => setConfirmDisconnect(true)}
        >
          Disconnect Spotify
        </Button>
      )}
    </div>
  );
};

export default SpotifyConnectionPanel;
