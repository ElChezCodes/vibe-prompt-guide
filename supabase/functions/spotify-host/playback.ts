// Spotify payloads are untyped JSON from an outside service
/* eslint-disable @typescript-eslint/no-explicit-any */

/**
 * Playback Provider (roadmap step 6; v3.2 "Playback real", Backend_Block_4 §1).
 *
 * Music Fighter never plays audio: a provider drives the host's own player.
 * The interface is provider-neutral so the streaming service can be swapped
 * for legal/licensing reasons; SpotifyPlaybackProvider is the only
 * implementation. getStatus/play/queue/skip act on the host's player;
 * onProgress is the watcher (spotify-host action "watch", run by pg_cron
 * every 15 s), which reports each observed status to the callback.
 */

export interface CatalogTrack {
  spotify_track_id: string;
  title: string;
  artist: string;
  duration_ms: number;
  artwork_url: string | null;
  spotify_url: string;
  // external_ids.isrc: the only thing that crosses into MF's own affinity
  // data (step 8, mapped to MusicBrainz); null when Spotify doesn't send it
  isrc: string | null;
}

// A playlist of the user's own library they can open (step 7): owned or
// collaborative; "liked" = their Liked Songs
export interface LibraryPlaylist {
  id: string;
  name: string;
  artwork_url: string | null;
  total: number;
  spotify_url: string;
}

export interface LibraryPage {
  tracks: CatalogTrack[];
  next_offset: number | null;
  total: number;
}

export interface PlaybackDevice {
  id: string;
  name: string;
  type: string;
  is_active: boolean;
  is_restricted: boolean;
}

export interface PlaybackStatus {
  devices: PlaybackDevice[];
  // The device that is actually playing/selected in the host's player, if any
  activeDeviceId: string | null;
  isPlaying: boolean;
  contextUri: string | null;
  trackUri: string | null;
  progressMs: number | null;
}

export interface PlaybackSession {
  id: string;
  uri: string;
}

export interface PlaybackProvider {
  getStatus(): Promise<PlaybackStatus>;
  play(opts: { deviceId: string; contextUri: string; offsetUri?: string; positionMs?: number }): Promise<void>;
  // Appends a track to the arena's session (the playlist): what plays next
  queue(session: PlaybackSession, trackUri: string): Promise<void>;
  skip(deviceId: string): Promise<void>;
  pause(deviceId: string): Promise<void>;
  onProgress(handler: (status: PlaybackStatus) => Promise<void>): Promise<void>;
  // Session = the arena's private playlist, first track = the warm-up
  createSession(name: string, firstTrackUri: string): Promise<PlaybackSession>;
  search(query: string): Promise<CatalogTrack[]>;
  getTrack(trackId: string): Promise<CatalogTrack | null>;
  // The token owner's own library, only to pick a song to propose (step 7)
  listPlaylists(ownerId: string): Promise<LibraryPlaylist[]>;
  playlistTracks(playlistId: string, offset: number): Promise<LibraryPage>;
  // The token owner's Liked Songs, only when they like a song in MF
  isSaved(trackId: string): Promise<boolean>;
  save(trackId: string): Promise<void>;
  unsave(trackId: string): Promise<void>;
}

export class PlaybackError extends Error {
  constructor(public status: number, public reason: string | null, message: string) {
    super(message);
  }
  get premiumRequired() {
    return this.status === 403 && this.reason === "PREMIUM_REQUIRED";
  }
}

const API = "https://api.spotify.com/v1";
export const LIBRARY_PAGE = 50;
// /me/playlists pages read per listing (50 each)
const MAX_PLAYLIST_PAGES = 4;
export const LIKED_SONGS_ID = "liked";

export const trackUri = (id: string) => `spotify:track:${id}`;

function toCatalogTrack(t: any): CatalogTrack {
  const images: any[] = t.album?.images ?? [];
  return {
    spotify_track_id: t.id,
    title: t.name,
    artist: (t.artists ?? []).map((a: any) => a.name).join(", "),
    duration_ms: t.duration_ms,
    // Spotify sorts images widest first
    artwork_url: images[0]?.url ?? null,
    spotify_url: t.external_urls?.spotify ?? `https://open.spotify.com/track/${t.id}`,
    isrc: t.external_ids?.isrc ?? null,
  };
}

export class SpotifyPlaybackProvider implements PlaybackProvider {
  constructor(private accessToken: string) {}

  private async api(path: string, init: RequestInit = {}) {
    const res = await fetch(`${API}${path}`, {
      ...init,
      headers: { Authorization: `Bearer ${this.accessToken}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
    });
    const text = await res.text();
    let body: any = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = null;
    }
    return { status: res.status, body };
  }

  private async must(path: string, init: RequestInit = {}) {
    const res = await this.api(path, init);
    if (res.status < 200 || res.status >= 300) {
      throw new PlaybackError(
        res.status,
        res.body?.error?.reason ?? null,
        res.body?.error?.message ?? `Spotify answered ${res.status}`,
      );
    }
    return res.body;
  }

  async getStatus(): Promise<PlaybackStatus> {
    const [devicesRes, playerRes] = await Promise.all([this.api("/me/player/devices"), this.api("/me/player")]);
    if (devicesRes.status !== 200) {
      throw new PlaybackError(devicesRes.status, null, `Spotify devices answered ${devicesRes.status}`);
    }
    const devices: PlaybackDevice[] = (devicesRes.body?.devices ?? []).map((d: any) => ({
      id: d.id,
      name: d.name,
      type: d.type,
      is_active: !!d.is_active,
      // Restricted devices can't be controlled through the Web API
      is_restricted: !!d.is_restricted,
    }));
    // 204 = no active player
    const player = playerRes.status === 200 ? playerRes.body : null;
    return {
      devices,
      activeDeviceId: player?.device?.id ?? null,
      isPlaying: !!player?.is_playing,
      contextUri: player?.context?.uri ?? null,
      trackUri: player?.item?.uri ?? null,
      progressMs: player?.progress_ms ?? null,
    };
  }

  async play({ deviceId, contextUri, offsetUri, positionMs }: {
    deviceId: string;
    contextUri: string;
    offsetUri?: string;
    positionMs?: number;
  }) {
    await this.must(`/me/player/play?device_id=${encodeURIComponent(deviceId)}`, {
      method: "PUT",
      body: JSON.stringify({
        context_uri: contextUri,
        offset: offsetUri ? { uri: offsetUri } : { position: 0 },
        position_ms: Math.max(0, Math.floor(positionMs ?? 0)),
      }),
    });
    // The playlist plays in order and stops at its end: no shuffle, no repeat
    // (no crossfade either: that is a player setting MF never touches, III.7)
    const q = `device_id=${encodeURIComponent(deviceId)}`;
    await this.api(`/me/player/shuffle?state=false&${q}`, { method: "PUT" });
    await this.api(`/me/player/repeat?state=off&${q}`, { method: "PUT" });
  }

  async queue(session: PlaybackSession, uri: string) {
    await this.must(`/playlists/${session.id}/items`, { method: "POST", body: JSON.stringify({ uris: [uri] }) });
  }

  async skip(deviceId: string) {
    await this.must(`/me/player/next?device_id=${encodeURIComponent(deviceId)}`, { method: "POST" });
  }

  async pause(deviceId: string) {
    await this.api(`/me/player/pause?device_id=${encodeURIComponent(deviceId)}`, { method: "PUT" });
  }

  async onProgress(handler: (status: PlaybackStatus) => Promise<void>) {
    await handler(await this.getStatus());
  }

  async createSession(name: string, firstTrackUri: string): Promise<PlaybackSession> {
    // POST /me/playlists (POST /users/{id}/playlists is gone since Feb 2026)
    const playlist = await this.must("/me/playlists", {
      method: "POST",
      body: JSON.stringify({ name, public: false, description: "Created by Music Fighter" }),
    });
    const session = { id: playlist.id, uri: playlist.uri ?? `spotify:playlist:${playlist.id}` };
    await this.queue(session, firstTrackUri);
    return session;
  }

  async search(query: string): Promise<CatalogTrack[]> {
    // limit ≤ 10 since Feb 2026. No market param: "from_token" needs the
    // user-read-private scope (403 "Insufficient client scope"), and with a user
    // token Spotify already applies the host's country
    const params = new URLSearchParams({ q: query, type: "track", limit: "10" });
    const body = await this.must(`/search?${params}`);
    return (body?.tracks?.items ?? []).filter((t: any) => t?.id).map(toCatalogTrack);
  }

  async getTrack(trackId: string): Promise<CatalogTrack | null> {
    if (!/^[A-Za-z0-9]{10,40}$/.test(trackId)) return null;
    const res = await this.api(`/tracks/${trackId}`);
    return res.status === 200 && res.body?.id ? toCatalogTrack(res.body) : null;
  }

  async listPlaylists(ownerId: string): Promise<LibraryPlaylist[]> {
    const liked = await this.must("/me/tracks?limit=1");
    const out: LibraryPlaylist[] = [{
      id: LIKED_SONGS_ID,
      name: "Liked Songs",
      artwork_url: null,
      total: liked?.total ?? 0,
      spotify_url: "https://open.spotify.com/collection/tracks",
    }];
    for (let page = 0, offset = 0; page < MAX_PLAYLIST_PAGES; page++, offset += LIBRARY_PAGE) {
      const body = await this.must(`/me/playlists?limit=${LIBRARY_PAGE}&offset=${offset}`);
      for (const p of body?.items ?? []) {
        // Since Feb 2026 only owned/collaborative playlists can be opened
        if (!p?.id || (p.owner?.id !== ownerId && !p.collaborative)) continue;
        out.push({
          id: p.id,
          name: p.name,
          artwork_url: p.images?.[0]?.url ?? null,
          total: p.items?.total ?? p.tracks?.total ?? 0,
          spotify_url: p.external_urls?.spotify ?? `https://open.spotify.com/playlist/${p.id}`,
        });
      }
      if (!body?.next) break;
    }
    return out;
  }

  // Feb 2026: /me/library (URIs) replaces /me/tracks for saving/checking
  async isSaved(trackId: string): Promise<boolean> {
    const body = await this.must(`/me/library/contains?uris=${encodeURIComponent(trackUri(trackId))}`);
    return Array.isArray(body) ? !!body[0] : false;
  }

  async save(trackId: string) {
    await this.must(`/me/library?uris=${encodeURIComponent(trackUri(trackId))}`, { method: "PUT" });
  }

  async unsave(trackId: string) {
    await this.must(`/me/library?uris=${encodeURIComponent(trackUri(trackId))}`, { method: "DELETE" });
  }

  async playlistTracks(playlistId: string, offset: number): Promise<LibraryPage> {
    const page = `limit=${LIBRARY_PAGE}&offset=${offset}`;
    const body = playlistId === LIKED_SONGS_ID
      ? await this.must(`/me/tracks?${page}`)
      : await this.must(`/playlists/${encodeURIComponent(playlistId)}/items?${page}&additional_types=track`);
    const tracks = (body?.items ?? [])
      .filter((e: any) => !e?.is_local)
      .map((e: any) => e?.item ?? e?.track)
      // Local files, episodes and removed tracks can't be proposed
      .filter((t: any) => t?.id && (t.type ?? "track") === "track" && !t.is_local)
      .map(toCatalogTrack);
    return { tracks, next_offset: body?.next ? offset + LIBRARY_PAGE : null, total: body?.total ?? 0 };
  }
}
