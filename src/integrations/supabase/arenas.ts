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

  const { data, error } = await supabase
    .from('arenas')
    .insert({
      name: normalizedName,
      state: 'active',
      mood: 'warmup',
      host_id: session.user.id,
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create arena:', error.message, error);
    throw error;
  }

  return data as Arena;
}
