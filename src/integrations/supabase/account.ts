import { supabase } from '@/integrations/supabase/client';

// Optional Music Fighter accounts (step 7b, supabase/sql/accounts_2026-10-27.sql).
// Everyone starts anonymous; an email + 6-digit code turns the session into an
// account. A new email keeps the same user id (updateUser + email_change code);
// an email that already has an account signs into it and the anonymous
// session's data is merged into it (merge ticket created before switching).

export const PRIVACY_POLICY_VERSION = '2026-10-28';

export type SignInMode = 'convert' | 'signin';

export interface PendingSignIn {
  email: string;
  mode: SignInMode;
  ticket: string | null;
}

export class AccountError extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

// Sends the code. Must be called from an anonymous session.
export async function startSignIn(rawEmail: string): Promise<PendingSignIn> {
  const email = rawEmail.trim().toLowerCase();
  const { error } = await supabase.auth.updateUser({ email });
  if (!error) return { email, mode: 'convert', ticket: null };
  if ((error as { code?: string }).code !== 'email_exists') {
    throw new AccountError((error as { code?: string }).code ?? 'send_failed', error.message);
  }

  // Existing account: prove this anonymous session first, then sign in
  const { data: ticket, error: ticketError } = await supabase.rpc('create_merge_ticket');
  if (ticketError) throw new AccountError('ticket_failed', ticketError.message);
  const { error: otpError } = await supabase.auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
  if (otpError) throw new AccountError((otpError as { code?: string }).code ?? 'send_failed', otpError.message);
  return { email, mode: 'signin', ticket: ticket as string };
}

export async function verifySignIn(pending: PendingSignIn, code: string): Promise<{ mergeError: string | null }> {
  const token = code.replace(/\s+/g, '');
  const { error } = await supabase.auth.verifyOtp({
    email: pending.email,
    token,
    type: pending.mode === 'convert' ? 'email_change' : 'email',
  });
  if (error) throw new AccountError((error as { code?: string }).code ?? 'invalid_code', error.message);

  // Fresh JWT so is_anonymous = false reaches the database
  await supabase.auth.refreshSession();
  const { error: consentError } = await supabase.rpc('record_privacy_consent', { p_version: PRIVACY_POLICY_VERSION });
  if (consentError) console.error('Failed to record privacy consent:', consentError.message);

  // Signed into an existing account: bring this device's anonymous activity along
  let mergeError: string | null = null;
  if (pending.mode === 'signin' && pending.ticket) {
    const { error: mergeErr } = await supabase.functions.invoke('spotify-host', {
      body: { action: 'merge_anonymous', ticket: pending.ticket },
    });
    if (mergeErr) {
      const payload = await (mergeErr as { context?: Response }).context?.json?.().catch(() => null);
      mergeError = payload?.message ?? mergeErr.message;
    }
  }
  return { mergeError };
}

// Back to a fresh anonymous session on this device (the account stays)
export async function signOutToAnonymous() {
  await supabase.auth.signOut();
  await supabase.auth.signInAnonymously();
}

export async function deleteMyAccount() {
  const { error } = await supabase.functions.invoke('spotify-host', { body: { action: 'delete_account' } });
  if (error) {
    const payload = await (error as { context?: Response }).context?.json?.().catch(() => null);
    throw new AccountError(payload?.error ?? 'delete_failed', payload?.message ?? error.message);
  }
  await signOutToAnonymous();
}
