import { useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { sendPresenceDisconnect, sendPresenceHeartbeat } from "@/integrations/supabase/presence";

const HEARTBEAT_MS = 30_000;

// While the app is open (any screen), tell the backend the user is connected
// to their current arena; closing the tab marks them INACTIVO at once. The
// backend allows 10 min without a heartbeat before INACTIVO (locked phones).
export function usePresenceHeartbeat(enabled: boolean) {
  useEffect(() => {
    if (!enabled) return;

    let accessToken: string | null = null;
    supabase.auth.getSession().then(({ data: { session } }) => {
      accessToken = session?.access_token ?? null;
    });
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      accessToken = session?.access_token ?? null;
    });

    sendPresenceHeartbeat();
    const interval = window.setInterval(sendPresenceHeartbeat, HEARTBEAT_MS);

    const onVisibility = () => {
      if (document.visibilityState === "visible") sendPresenceHeartbeat();
    };
    const onPageHide = () => {
      if (accessToken) sendPresenceDisconnect(accessToken);
    };
    // Back from the bfcache: pageshow, not a remount
    const onPageShow = (e: PageTransitionEvent) => {
      if (e.persisted) sendPresenceHeartbeat();
    };

    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("pagehide", onPageHide);
    window.addEventListener("pageshow", onPageShow);

    return () => {
      window.clearInterval(interval);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("pagehide", onPageHide);
      window.removeEventListener("pageshow", onPageShow);
      subscription.unsubscribe();
    };
  }, [enabled]);
}
