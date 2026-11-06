// The arena travels in the URL (/a/:code/...) so reloads, browser back and
// shared links (Stage View on the venue screen, the join QR) all work.

export type ArenaScreen = "battle" | "lobby" | "connect" | "propose" | "stage";

export const arenaPath = (code: string, screen: ArenaScreen) => `/a/${code}/${screen}`;

// What the lobby QR encodes: opens Join with the code filled in
export const joinUrl = (code: string) => `${window.location.origin}/join/${code}`;

// What a card's QR on the Stage View encodes: scanning it votes that song of
// that battle (the token dies with the battle, which is how the QR rotates)
export const voteUrl = (token: string, side: "a" | "b") => `${window.location.origin}/v/${token}/${side}`;

export const stageUrl = (code: string) => `${window.location.origin}${arenaPath(code, "stage")}`;

// Arena tab target: the host runs a waiting arena from the lobby
export const arenaHomePath = (code: string, isHost: boolean, state: string) =>
  arenaPath(code, isHost && state === "waiting" ? "lobby" : "battle");
