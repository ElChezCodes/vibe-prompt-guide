import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = "https://uuxzjroikbzwaszpgiks.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_ME9IUFjuJMkG4NWep8saaA_xB2A0dnQ";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
