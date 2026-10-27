import { createClient } from '@supabase/supabase-js';

export const SUPABASE_URL = "https://uuxzjroikbzwaszpgiks.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_ME9IUFjuJMkG4NWep8saaA_xB2A0dnQ";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
