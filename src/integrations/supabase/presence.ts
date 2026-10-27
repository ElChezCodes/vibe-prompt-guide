import { supabase, SUPABASE_URL, SUPABASE_ANON_KEY } from '@/integrations/supabase/client';

// Backend-computed (see supabase/sql/presence_states_2026-10-26.sql): the
// frontend only reports the connection and displays the state.
export type PresenceState = 'active' | 'passive' | 'inactive';

export interface ArenaPresence {
  my_state: PresenceState | null;
  active_count: number;
  passive_count: number;
  inactive_count: number;
}

// Connection only, never activity (v4 §1.3): keeps the caller's current arena
// from going INACTIVO, never makes anyone ACTIVO
export async function sendPresenceHeartbeat(): Promise<void> {
  const { error } = await supabase.rpc('presence_heartbeat');
  if (error) console.error('Presence heartbeat failed:', error.message);
}

// Fired while the page unloads, so it can't await the client: a keepalive
// fetch outlives the page
export function sendPresenceDisconnect(accessToken: string): void {
  fetch(`${SUPABASE_URL}/rest/v1/rpc/presence_disconnect`, {
    method: 'POST',
    keepalive: true,
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: '{}',
  }).catch(() => {});
}

export async function getArenaPresence(arenaId: string): Promise<ArenaPresence | null> {
  const { data, error } = await supabase
    .rpc('get_arena_presence', { p_arena_id: arenaId })
    .maybeSingle();

  if (error) {
    console.error('Failed to fetch presence:', error.message);
    return null;
  }

  return (data as ArenaPresence) ?? null;
}
