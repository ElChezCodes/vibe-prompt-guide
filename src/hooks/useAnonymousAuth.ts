import { useEffect, useState } from 'react';
import { supabase } from '@/integrations/supabase/client';

export function useAnonymousAuth() {
  const [isReady, setIsReady] = useState(false);

  useEffect(() => {
    let mounted = true;

    const ensureSession = async () => {
      const { data: { session } } = await supabase.auth.getSession();
      
      if (!session) {
        await supabase.auth.signInAnonymously();
      }
      
      if (mounted) {
        setIsReady(true);
      }
    };

    ensureSession();

    return () => {
      mounted = false;
    };
  }, []);

  return { isReady };
}
