-- Point-in-time snapshot taken before Batch 1. Additive only; rollback = drop these tables (never needed for app function).
create table if not exists public.bk_20261027_lv_msgs  as table public.lv_msgs;
create table if not exists public.bk_20261027_lv_media as table public.lv_media;
create table if not exists public.bk_20261027_lv_game  as table public.lv_game;
create table if not exists public.bk_20261027_lv_used  as table public.lv_used;
create table if not exists public.bk_20261027_lv_favs  as table public.lv_favs;
create table if not exists public.bk_20261027_lv_reacts as table public.lv_reacts;

do $$
declare t text;
begin
  foreach t in array array['bk_20261027_lv_msgs','bk_20261027_lv_media','bk_20261027_lv_game','bk_20261027_lv_used','bk_20261027_lv_favs','bk_20261027_lv_reacts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
