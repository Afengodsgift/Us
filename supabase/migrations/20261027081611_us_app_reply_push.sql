-- Replies and Web Push (applied 2026-10-27). The project URL below is public; the push secret is generated in the database.
create extension if not exists pg_net;
alter table public.lv_msgs add column reply bigint references public.lv_msgs(id) on delete set null;
create table public.lv_push(id bigint generated always as identity primary key, uid uuid not null references public.lv_users(id) on delete cascade, endpoint text not null unique, sub jsonb not null, preview boolean not null default false);
alter table public.lv_push enable row level security;
revoke all on public.lv_push from anon, authenticated;
insert into public.lv_cfg(k,v) values ('push_secret', encode(extensions.gen_random_bytes(24),'hex')) on conflict (k) do nothing;

drop function public.lv_send(text,text,text,text,text);
create function public.lv_send(p_tok text, p_kind text, p_body text, p_mime text, p_data text, p_reply bigint default null) returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); mid bigint; nid bigint; begin
 if p_data is not null then insert into lv_media(mime,data) values (p_mime,p_data) returning id into mid; end if;
 insert into lv_msgs(uid,kind,body,media,reply) values (u,p_kind,coalesce(p_body,''),mid,(select id from lv_msgs where id = p_reply)) returning id into nid; return nid; end $$;

create or replace function public.lv_poll(p_tok text, p_last bigint default 0, p_typing boolean default false) returns json language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 insert into lv_seen(uid,seen,typing) values (u, now(), case when p_typing then now() end)
  on conflict (uid) do update set seen = now(), typing = case when p_typing then now() else lv_seen.typing end;
 return json_build_object(
  'me', u,
  'users', (select coalesce(json_agg(json_build_object('id',x.id,'name',x.name,'on',coalesce(s.seen > now() - interval '15 seconds', false),'ty',coalesce(s.typing > now() - interval '4 seconds', false)) order by x.created_at),'[]'::json) from lv_users x left join lv_seen s on s.uid = x.id),
  'msgs', (select coalesce(json_agg(m order by m.id),'[]'::json) from (select x.id, x.uid, x.kind, x.body, x.media, x.reply, (extract(epoch from x.at)*1000)::bigint as at, r.kind as rk, left(r.body,160) as rb, r.uid as ru from lv_msgs x left join lv_msgs r on r.id = x.reply where x.id > p_last order by x.id desc limit 200) m),
  'reacts', (select coalesce(json_agg(json_build_object('m',r.msg,'u',r.uid,'e',r.emoji)),'[]'::json) from lv_reacts r where r.msg > (select coalesce(max(id),0) - 200 from lv_msgs)),
  'epoch', (select v from lv_cfg where k='epoch'),
  'used', (select coalesce(json_agg(n),'[]'::json) from lv_used),
  'favs', (select coalesce(json_agg(n),'[]'::json) from lv_favs),
  'lv', (select md5(list) from lv_game where id=1)); end $$;

create function public.lv_pushsub(p_tok text, p_sub jsonb, p_preview boolean default false) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin
 if coalesce(p_sub->>'endpoint','') = '' then raise exception 'invalid'; end if;
 insert into lv_push(uid,endpoint,sub,preview) values (u, p_sub->>'endpoint', p_sub, coalesce(p_preview,false))
  on conflict (endpoint) do update set uid = excluded.uid, sub = excluded.sub, preview = excluded.preview; end $$;
create function public.lv_pushoff(p_tok text, p_endpoint text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare u uuid := lv_uid(p_tok); begin delete from lv_push where endpoint = p_endpoint and uid = u; end $$;

create function public.lv_notify() returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
 perform net.http_post(
  url := 'https://lzqnxawxehmqgswuzpyn.supabase.co/functions/v1/lv-push',
  headers := jsonb_build_object('Content-Type','application/json','x-push-secret',(select v from lv_cfg where k='push_secret')),
  body := jsonb_build_object('uid',new.uid,'kind',new.kind,'body',left(new.body,120),'name',(select name from lv_users where id = new.uid)));
 return new; exception when others then return new; end $$;
create trigger lv_msgs_notify after insert on public.lv_msgs for each row execute function public.lv_notify();

revoke all on function public.lv_send(text,text,text,text,text,bigint), public.lv_pushsub(text,jsonb,boolean), public.lv_pushoff(text,text), public.lv_notify() from public, anon, authenticated;
grant execute on function public.lv_send(text,text,text,text,text,bigint), public.lv_pushsub(text,jsonb,boolean), public.lv_pushoff(text,text) to anon;
grant execute on function public.lv_poll(text,bigint,boolean) to anon;
