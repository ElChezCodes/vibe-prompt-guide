import { supabase } from '@/integrations/supabase/client';

export async function createArena() {
  const { data, error } = await supabase
    .from('arenas')
    .insert({
      name: 'Test Arena',
      state: 'waiting',
      mood: 'neutral',
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create arena:', error);
    throw error;
  }

  return data;
}
