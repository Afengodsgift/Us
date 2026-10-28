-- Batch 1 / part 1: additive schema. No data is deleted or rewritten.
-- Rollback: columns/indexes/tables below are additive and can be dropped without touching existing data.

-- Retry-safe sends + soft delete
alter table public.lv_msgs
  add column if not exists cid text,
  add column if not exists deleted_at timestamptz,
  add column if not exists cleared_at timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lv_msgs_cid_len') then
    alter table public.lv_msgs add constraint lv_msgs_cid_len check (cid is null or length(cid) <= 40);
  end if;
end $$;

create unique index if not exists lv_msgs_uid_cid_uq on public.lv_msgs (uid, cid) where cid is not null;
create index if not exists lv_msgs_live_idx on public.lv_msgs (id) where deleted_at is null;

-- Failure log: per-IP / per-name tracking, indexed so counts and cleanup stay cheap
alter table public.lv_fail add column if not exists ip text, add column if not exists nm text;
create index if not exists lv_fail_ip_at on public.lv_fail (ip, at);
create index if not exists lv_fail_nm_at on public.lv_fail (nm, at);
create index if not exists lv_fail_at on public.lv_fail (at);

-- Names unique case-insensitively (both existing names are distinct)
create unique index if not exists lv_users_name_lower_uq on public.lv_users (lower(name));

-- Atomic two-user cap enforced at the table, whatever code path inserts
create or replace function public.lv_users_cap() returns trigger
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform pg_advisory_xact_lock(7001);
  if (select count(*) from public.lv_users) >= 2 then raise exception 'full'; end if;
  return new;
end $$;
revoke all on function public.lv_users_cap() from public, anon, authenticated;
drop trigger if exists lv_users_cap_t on public.lv_users;
create trigger lv_users_cap_t before insert on public.lv_users for each row execute function public.lv_users_cap();

-- Question list version history + asked-questions archive
create table if not exists public.lv_game_versions (
  id bigint generated always as identity primary key,
  list text not null,
  saved_at timestamptz not null default now(),
  saved_by uuid,
  reason text
);
create table if not exists public.lv_used_archive (
  id bigint generated always as identity primary key,
  n text not null,
  archived_at timestamptz not null default now(),
  archived_by uuid
);
alter table public.lv_game_versions enable row level security;
alter table public.lv_used_archive enable row level security;
revoke all on public.lv_game_versions, public.lv_used_archive from anon, authenticated;

insert into public.lv_game_versions (list, reason)
select list, 'baseline before Batch 1 (2026-10-27)' from public.lv_game
where id = 1 and not exists (select 1 from public.lv_game_versions);
