import { supabase } from '@/integrations/supabase/client';

interface Arena {
  id: string;
  name: string;
  state: string;
  mood: string;
  host_id: string | null;
  created_at: string;
}

export async function createArena(name?: string): Promise<Arena> {
  const trimmed = name?.trim();
  const normalizedName = trimmed && trimmed.length > 0 ? trimmed : 'Test Arena';

  const { data, error } = await supabase
    .from('arenas')
    .insert({
      name: normalizedName,
      state: 'active',
      mood: 'warmup',
      host_id: null,
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create arena:', error.message);
    throw error;
  }

  return data as Arena;
}
