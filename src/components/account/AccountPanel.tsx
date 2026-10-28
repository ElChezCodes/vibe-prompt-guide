import { useState } from "react";
import { Link } from "react-router-dom";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAuthUser } from "@/hooks/useAuthUser";
import {
  deleteMyAccount,
  PendingSignIn,
  signOutToAnonymous,
  startSignIn,
  verifySignIn,
} from "@/integrations/supabase/account";

// After switching user every screen must reload its data
const reloadAs = (path: string) => window.location.assign(path);

/**
 * Optional account (step 7b): email + 6-digit code. Anonymous users can keep
 * playing without it; signing in keeps (or merges) what they did on this
 * device. Minimal markup; the visual pass is done in Lovable.
 */
const AccountPanel = () => {
  const user = useAuthUser();
  const [email, setEmail] = useState("");
  const [accepted, setAccepted] = useState(false);
  const [pending, setPending] = useState<PendingSignIn | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    setError("");
    try {
      await action();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  if (!user) {
    return (
      <div className="flex justify-center py-4">
        <Loader2 className="w-5 h-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!user.is_anonymous) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-text-secondary">
          Signed in as <span className="font-medium text-foreground break-all">{user.email}</span>
        </p>
        <Button variant="ghost" className="w-full" disabled={busy} onClick={() => run(async () => {
          await signOutToAnonymous();
          reloadAs("/");
        })}>
          Sign out on this device
        </Button>
        {confirmDelete ? (
          <div className="space-y-2">
            <p className="text-sm text-text-secondary">
              This ends the arenas you host, deletes your Spotify connection and your account. Your past votes and
              proposals stay in their arenas without your identity.
            </p>
            <div className="flex gap-2">
              <Button
                variant="ghost"
                className="flex-1 border border-destructive/40 text-destructive"
                disabled={busy}
                onClick={() => run(async () => {
                  await deleteMyAccount();
                  reloadAs("/");
                })}
              >
                Delete account
              </Button>
              <Button variant="ghost" className="flex-1" onClick={() => setConfirmDelete(false)}>
                Cancel
              </Button>
            </div>
          </div>
        ) : (
          <Button variant="ghost" className="w-full text-muted-foreground" onClick={() => setConfirmDelete(true)}>
            Delete my account
          </Button>
        )}
        {error && <p className="text-sm text-destructive">{error}</p>}
      </div>
    );
  }

  if (pending) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-text-secondary">
          We sent a 6-digit code to <span className="font-medium text-foreground break-all">{pending.email}</span>.
        </p>
        <Input
          inputMode="numeric"
          autoComplete="one-time-code"
          placeholder="123456"
          value={code}
          onChange={(e) => setCode(e.target.value)}
        />
        <Button className="w-full" disabled={busy || code.trim().length < 6} onClick={() => run(async () => {
          const { mergeError } = await verifySignIn(pending, code);
          if (mergeError) {
            // Signed in anyway; tell them what didn't come along
            setError(mergeError);
            return;
          }
          reloadAs("/profile");
        })}>
          {busy ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : null}
          Confirm
        </Button>
        <Button variant="ghost" className="w-full" disabled={busy} onClick={() => {
          setPending(null);
          setCode("");
        }}>
          Use another email
        </Button>
        {error && <p className="text-sm text-destructive">{error}</p>}
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <p className="text-sm text-text-secondary">
        Optional. An account keeps your Music Fighter profile across devices and nights. Already have one? Sign in and
        what you did on this device joins it.
      </p>
      <Input type="email" autoComplete="email" placeholder="you@email.com" value={email} onChange={(e) => setEmail(e.target.value)} />
      <label className="flex items-start gap-2 text-xs text-text-secondary">
        <input type="checkbox" className="mt-0.5" checked={accepted} onChange={(e) => setAccepted(e.target.checked)} />
        <span>
          I accept the{" "}
          <Link to="/privacy" className="underline">
            privacy policy
          </Link>
        </span>
      </label>
      <Button className="w-full" disabled={busy || !accepted || !email.includes("@")} onClick={() => run(async () => {
        setPending(await startSignIn(email));
      })}>
        {busy ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : null}
        Send code
      </Button>
      {error && <p className="text-sm text-destructive">{error}</p>}
    </div>
  );
};

export default AccountPanel;
