-- Original US backend (applied 2026-10-27). Kept as history; later migrations replace several of these functions.
create extension if not exists pgcrypto with schema extensions;
create table public.lv_users(id uuid primary key default gen_random_uuid(), name text not null, pass text not null, created_at timestamptz default now());
create unique index lv_users_name on public.lv_users(lower(name));
create table public.lv_sessions(th text primary key, uid uuid not null references public.lv_users(id) on delete cascade, exp timestamptz not null);
create table public.lv_cfg(k text primary key, v text);
create table public.lv_fail(k text not null, at timestamptz not null default now());
create table public.lv_media(id bigint generated always as identity primary key, mime text not null, data text not null check (length(data) < 3500000), created_at timestamptz default now());
create table public.lv_msgs(id bigint generated always as identity primary key, uid uuid not null references public.lv_users(id) on delete cascade, kind text not null check (kind in ('text','photo','voice','q')), body text not null default '' check (length(body) < 3000), media bigint references public.lv_media(id) on delete set null, at timestamptz not null default now());
create table public.lv_reacts(msg bigint references public.lv_msgs(id) on delete cascade, uid uuid references public.lv_users(id) on delete cascade, emoji text not null check (length(emoji) < 12), primary key(msg,uid));
create table public.lv_seen(uid uuid primary key references public.lv_users(id) on delete cascade, seen timestamptz default now(), typing timestamptz);
create table public.lv_game(id int primary key check (id = 1), list text not null default '');
create table public.lv_used(n text primary key);
create table public.lv_favs(n text primary key);
alter table public.lv_users enable row level security; alter table public.lv_sessions enable row level security; alter table public.lv_cfg enable row level security; alter table public.lv_fail enable row level security; alter table public.lv_media enable row level security; alter table public.lv_msgs enable row level security; alter table public.lv_reacts enable row level security; alter table public.lv_seen enable row level security; alter table public.lv_game enable row level security; alter table public.lv_used enable row level security; alter table public.lv_favs enable row level security;
revoke all on public.lv_users, public.lv_sessions, public.lv_cfg, public.lv_fail, public.lv_media, public.lv_msgs, public.lv_reacts, public.lv_seen, public.lv_game, public.lv_used, public.lv_favs from anon, authenticated;
insert into public.lv_cfg values ('epoch','0');
-- NOTE: the production run seeded lv_game from the earlier prototype table qg_questions (not part of this repo).
-- On a fresh database, seed the question list yourself: insert into public.lv_game(id,list) values (1, '<questions>');
-- The invite code is stored hashed in lv_cfg (k='invite', v=crypt('<code>', gen_salt('bf'))) and is NOT in this repo.

create function public.lv_uid(p text) returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare u uuid; begin
 select uid into u from lv_sessions where th = encode(digest(coalesce(p,''),'sha256'),'hex') and exp > now();
 if u is null then raise exception 'auth'; end if; return u; end $$;
create function public.lv_mk(u uuid) returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(24),'hex'); begin
 insert into lv_sessions(th,uid,exp) values (encode(digest(t,'sha256'),'hex'), u, now() + interval '60 days');
 delete from lv_sessions where exp < now(); return t; end $$;
create function public.lv_register(p_name text, p_pass text, p_code text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare u uuid; n text := trim(coalesce(p_name,'')); begin
 delete from lv_fail where at < now() - interval '1 day';
 if (select count(*) from lv_fail where k='reg' and at > now() - interval '10 minutes') >= 5 then raise exception 'locked'; end if;
 if not exists (select 1 from lv_cfg where k='invite' and v = crypt(coalesce(p_code,''), v)) then insert into lv_fail(k) values ('reg'); raise exception 'badcode'; end if;
 if length(n) not between 1 and 20 or length(coalesce(p_pass,'')) < 6 then raise exception 'invalid'; end if;
 if (select count(*) from lv_users) >= 2 then raise exception 'full'; end if;
 insert into lv_users(name,pass) values (n, crypt(p_pass, gen_salt('bf'))) returning id into u;
 return lv_mk(u); end $$;
create function public.lv_login(p_name text, p_pass text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare u lv_users; kk text := 'l:' || lower(trim(coalesce(p_name,''))); begin
 if (select count(*) from lv_fail where k = kk and at > now() - interval '10 minutes') >= 6 then raise exception 'locked'; end if;
 select * into u from lv_users where lower(name) = lower(trim(coalesce(p_name,'')));
 if u.id is null or u.pass <> crypt(coalesce(p_pass,''), u.pass) then insert into lv_fail(k) values (kk); raise exception 'bad'; end if;
 return lv_mk(u.id); end $$;
create function public.lv_poll(p_tok text, p_last bigint default 0, p_typing boolean default false) returns json language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 insert into lv_seen(uid,seen,typing) values (u, now(), case when p_typing then now() end)
  on conflict (uid) do update set seen = now(), typing = case when p_typing then now() else lv_seen.typing end;
 return json_build_object(
  'me', u,
  'users', (select coalesce(json_agg(json_build_object('id',x.id,'name',x.name,'on',coalesce(s.seen > now() - interval '15 seconds', false),'ty',coalesce(s.typing > now() - interval '4 seconds', false)) order by x.created_at),'[]'::json) from lv_users x left join lv_seen s on s.uid = x.id),
  'msgs', (select coalesce(json_agg(m order by m.id),'[]'::json) from (select id, uid, kind, body, media, (extract(epoch from at)*1000)::bigint as at from lv_msgs where id > p_last order by id desc limit 200) m),
  'reacts', (select coalesce(json_agg(json_build_object('m',r.msg,'u',r.uid,'e',r.emoji)),'[]'::json) from lv_reacts r where r.msg > (select coalesce(max(id),0) - 200 from lv_msgs)),
  'epoch', (select v from lv_cfg where k='epoch'),
  'used', (select coalesce(json_agg(n),'[]'::json) from lv_used),
  'favs', (select coalesce(json_agg(n),'[]'::json) from lv_favs),
  'lv', (select md5(list) from lv_game where id=1)); end $$;
create function public.lv_send(p_tok text, p_kind text, p_body text, p_mime text, p_data text) returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); mid bigint; nid bigint; begin
 if p_data is not null then insert into lv_media(mime,data) values (p_mime,p_data) returning id into mid; end if;
 insert into lv_msgs(uid,kind,body,media) values (u,p_kind,coalesce(p_body,''),mid) returning id into nid; return nid; end $$;
create function public.lv_getmedia(p_tok text, p_id bigint) returns json language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 return (select json_build_object('mime',mime,'data',data) from lv_media where id = p_id); end $$;
create function public.lv_react(p_tok text, p_msg bigint, p_emoji text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 if exists (select 1 from lv_reacts where msg=p_msg and uid=u and emoji=p_emoji) then delete from lv_reacts where msg=p_msg and uid=u;
 else insert into lv_reacts(msg,uid,emoji) values (p_msg,u,p_emoji) on conflict (msg,uid) do update set emoji = excluded.emoji; end if; end $$;
create function public.lv_clear(p_tok text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 delete from lv_msgs where id > 0; delete from lv_media where true;
 update lv_cfg set v = (v::int + 1)::text where k='epoch'; end $$;
create function public.lv_ask(p_tok text, p_n text, p_q text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 insert into lv_used(n) values (left(p_n,7)) on conflict do nothing;
 insert into lv_msgs(uid,kind,body) values (u,'q', left(p_n,7) || E'\n' || left(p_q,2500)); end $$;
create function public.lv_unuse(p_tok text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin delete from lv_used where true; end $$;
create function public.lv_fav(p_tok text, p_n text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 if exists (select 1 from lv_favs where n=p_n) then delete from lv_favs where n=p_n; else insert into lv_favs(n) values (left(p_n,7)); end if; end $$;
create function public.lv_setlist(p_tok text, p_t text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 if length(coalesce(p_t,'')) > 150000 then raise exception 'toolong'; end if;
 insert into lv_game(id,list) values (1, coalesce(p_t,'')) on conflict (id) do update set list = excluded.list; end $$;
create function public.lv_getlist(p_tok text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin return (select list from lv_game where id=1); end $$;
create function public.lv_logout(p_tok text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin delete from lv_sessions where th = encode(digest(coalesce(p_tok,''),'sha256'),'hex'); end $$;

revoke all on function public.lv_uid(text), public.lv_mk(uuid), public.lv_register(text,text,text), public.lv_login(text,text), public.lv_poll(text,bigint,boolean), public.lv_send(text,text,text,text,text), public.lv_getmedia(text,bigint), public.lv_react(text,bigint,text), public.lv_clear(text), public.lv_ask(text,text,text), public.lv_unuse(text), public.lv_fav(text,text), public.lv_setlist(text,text), public.lv_getlist(text), public.lv_logout(text) from public, anon, authenticated;
grant execute on function public.lv_register(text,text,text), public.lv_login(text,text), public.lv_poll(text,bigint,boolean), public.lv_send(text,text,text,text,text), public.lv_getmedia(text,bigint), public.lv_react(text,bigint,text), public.lv_clear(text), public.lv_ask(text,text,text), public.lv_unuse(text), public.lv_fav(text,text), public.lv_setlist(text,text), public.lv_getlist(text), public.lv_logout(text) to anon;
