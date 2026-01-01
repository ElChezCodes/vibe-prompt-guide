import { supabase } from '@/integrations/supabase/client';

function normalizeName(name?: string) {
  const n = name?.trim();
  return n && n.length > 0 ? n : 'Test Arena';
}

export async function createArena(
  name?: string,
  state: string = 'active',
  mood: string = 'warmup'
) {
  const insertPayload = {
    name: normalizeName(name),
    state,
    mood,
    // Host is anonymous for now; DB is assumed to allow null.
    host_id: null as null,
  };

  const { data, error } = await supabase
    .from('arenas')
    .insert(insertPayload)
    .select()
    .single();

  if (error) {
    console.error('Failed to create arena:', error.message, error);
    throw error;
  }

  return data;
}
