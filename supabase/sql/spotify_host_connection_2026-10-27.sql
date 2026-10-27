-- Step 5: host Spotify connection (2026-10-27)
--
-- One Spotify connection per host user (auth.uid()), reusable across all of
-- their arenas (Backend_Block_4 §1 "StreamingAccount 1:1 con Host"; user
-- decision 2026-10-27). Only the `spotify-host` Edge Function (service_role)
-- touches these tables: tokens are AES-256-GCM encrypted there with a key
-- that lives in the Edge secrets (SPOTIFY_TOKEN_KEY), never in the database,
-- so neither SQL access nor a dump reveals them, and plaintext tokens never
-- appear in a SQL statement or Postgres log.
--
-- Clients only see the non-secret summary via get_my_streaming_connection().
-- Disconnecting deletes the row (Spotify Developer Policy I.1.2: delete the
-- user's data on disconnect).
--
-- The old streaming_accounts table (plaintext token columns, no policies,
-- never written, 0 rows, no dependents) is replaced.

drop table if exists public.streaming_accounts;

create table public.streaming_accounts (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users(id) on delete cascade,
  provider text not null default 'spotify' check (provider = 'spotify'),
  provider_account_id text not null,
  display_name text,
  -- "v<key version>:" || base64(iv || ciphertext+tag), AAD = host_id + column
  access_token_enc text not null,
  refresh_token_enc text not null,
  token_expires_at timestamptz not null,
  scopes text[] not null default '{}',
  -- GET /me no longer returns `product` (Spotify Feb 2026 changes): Premium is
  -- learnt from the player API (403 PREMIUM_REQUIRED = not Premium)
  premium_status text not null default 'unverified'
    check (premium_status in ('unverified', 'premium', 'not_premium')),
  premium_checked_at timestamptz,
  -- Device the host chose to play on (steps 6/18 use it); may disappear
  preferred_device_id text,
  preferred_device_name text,
  connected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (host_id, provider)
);

-- PKCE: verifier and state are generated server-side, bound to the user and
-- single-use; rows live 10 minutes
create table if not exists public.spotify_oauth_states (
  state text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  code_verifier text not null,
  redirect_uri text not null,
  return_to text not null,
  expires_at timestamptz not null default now() + interval '10 minutes',
  created_at timestamptz not null default now()
);

create index if not exists spotify_oauth_states_user_idx on public.spotify_oauth_states (user_id);

-- No client access at all: RLS on, no policies, no grants
alter table public.streaming_accounts enable row level security;
alter table public.spotify_oauth_states enable row level security;
revoke all on public.streaming_accounts from anon, authenticated;
revoke all on public.spotify_oauth_states from anon, authenticated;
grant all on public.streaming_accounts to service_role;
grant all on public.spotify_oauth_states to service_role;

-- Non-secret summary of the caller's own connection (no tokens, no Spotify
-- user id). Live device list comes from the Edge Function.
create or replace function public.get_my_streaming_connection()
returns table (
  provider text,
  display_name text,
  premium_status text,
  preferred_device_id text,
  preferred_device_name text,
  connected_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select provider, display_name, premium_status, preferred_device_id,
         preferred_device_name, connected_at
  from public.streaming_accounts
  where host_id = auth.uid();
$$;

revoke all on function public.get_my_streaming_connection() from public, anon;
grant execute on function public.get_my_streaming_connection() to authenticated;
