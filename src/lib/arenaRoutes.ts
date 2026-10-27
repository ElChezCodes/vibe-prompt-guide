// The arena travels in the URL (/a/:code/...) so reloads, browser back and
// shared links (Stage View on the venue screen, the join QR) all work.

export type ArenaScreen = "battle" | "lobby" | "connect" | "propose" | "stage";

export const arenaPath = (code: string, screen: ArenaScreen) => `/a/${code}/${screen}`;

// What the lobby QR encodes: opens Join with the code filled in
export const joinUrl = (code: string) => `${window.location.origin}/join/${code}`;

export const stageUrl = (code: string) => `${window.location.origin}${arenaPath(code, "stage")}`;

// Arena tab target: the host runs a waiting arena from the lobby
export const arenaHomePath = (code: string, isHost: boolean, state: string) =>
  arenaPath(code, isHost && state === "waiting" ? "lobby" : "battle");
