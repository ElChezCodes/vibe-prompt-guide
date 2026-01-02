import { supabase } from '@/integrations/supabase/client';

const IDENTITY_ANCHOR_KEY = 'identity_anchor_id';

export interface IdentityAnchor {
  id: string;
  created_at: string;
}

export async function getOrCreateIdentityAnchor(): Promise<string> {
  const existing = localStorage.getItem(IDENTITY_ANCHOR_KEY);
  if (existing) {
    return existing;
  }

  const { data, error } = await supabase
    .from('identity_anchors')
    .insert({})
    .select()
    .single();

  if (error) {
    console.error('Failed to create identity anchor:', error.message, error);
    throw error;
  }

  const anchorId = (data as IdentityAnchor).id;
  localStorage.setItem(IDENTITY_ANCHOR_KEY, anchorId);
  return anchorId;
}
