import { supabase } from '@/integrations/supabase/client';

export interface Arena {
  id: string;
  name: string;
  state: string;
  mood: string;
  host_id: string | null;
  arena_code: string;
  created_at: string;
}

export async function resolveArenaByCode(code: string): Promise<string> {
  const { data, error } = await supabase
    .from('arenas')
    .select('id')
    .eq('arena_code', code)
    .maybeSingle();

  if (error) {
    console.error('Failed to resolve arena by code:', error.message, error);
    throw error;
  }

  if (!data) {
    throw new Error('Arena not found');
  }

  return data.id;
}

export async function createArena(name: string): Promise<Arena> {
  const { data: { session } } = await supabase.auth.getSession();
  
  if (!session?.user) {
    throw new Error('No authenticated session');
  }

  const trimmed = name.trim();
  const normalizedName =
    trimmed.length > 0 ? trimmed : 'Test Arena';

  const { data: arenaId, error: rpcError } = await supabase
    .rpc('create_arena', { p_name: normalizedName, p_host_id: session.user.id });

  if (rpcError) {
    console.error('Failed to create arena:', rpcError.message, rpcError);
    throw rpcError;
  }

  const { data, error } = await supabase
    .from('arenas')
    .select('*')
    .eq('id', arenaId)
    .single();

  if (error) {
    console.error('Failed to fetch arena:', error.message, error);
    throw error;
  }

  return data as Arena;
}
