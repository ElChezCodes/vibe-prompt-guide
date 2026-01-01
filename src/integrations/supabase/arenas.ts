import { supabase } from '@/integrations/supabase/client';

interface CreateArenaParams {
  name?: string;
  state?: string;
  mood?: string;
}

export async function createArena(params: CreateArenaParams = {}) {
  const { data, error } = await supabase
    .from('arenas')
    .insert({
      name: params.name || 'Untitled Arena',
      state: params.state || 'active',
      mood: params.mood || 'warmup',
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create arena:', error);
    throw error;
  }

  return data;
}
