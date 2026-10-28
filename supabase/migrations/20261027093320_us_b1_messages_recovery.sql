-- Batch 1 / part 3: media validation, idempotent sends, recoverable destructive operations.
-- Rollback: previous definitions are in migrations us_app_backend / us_app_reply_push. Soft-deleted rows stay in lv_msgs/lv_media.
-- NOT automatically reversible: none of these statements delete existing data.

create or replace function public.lv_valid_media(p_kind text, p_mime text, p_data text) returns boolean
language plpgsql immutable set search_path to 'public', 'extensions' as $$
declare h bytea; m text := lower(coalesce(p_mime, ''));
begin
  if p_data is null or length(p_data) < 16 or length(p_data) >= 3500000 or length(p_data) % 4 <> 0 then return false; end if;
  if p_data ~ '[^A-Za-z0-9+/=]' then return false; end if;
  begin h := decode(left(p_data, 24), 'base64'); exception when others then return false; end;
  if p_kind = 'photo' then
    return case m
      when 'image/jpeg' then get_byte(h,0)=255 and get_byte(h,1)=216 and get_byte(h,2)=255
      when 'image/png'  then get_byte(h,0)=137 and get_byte(h,1)=80 and get_byte(h,2)=78 and get_byte(h,3)=71
      when 'image/webp' then get_byte(h,0)=82 and get_byte(h,1)=73 and get_byte(h,2)=70 and get_byte(h,3)=70
                             and get_byte(h,8)=87 and get_byte(h,9)=69 and get_byte(h,10)=66 and get_byte(h,11)=80
      when 'image/gif'  then get_byte(h,0)=71 and get_byte(h,1)=73 and get_byte(h,2)=70 and get_byte(h,3)=56
      else false end;
  elsif p_kind = 'voice' then
    return case m
      when 'audio/webm' then get_byte(h,0)=26 and get_byte(h,1)=69 and get_byte(h,2)=223 and get_byte(h,3)=163
      when 'audio/mp4'  then get_byte(h,4)=102 and get_byte(h,5)=116 and get_byte(h,6)=121 and get_byte(h,7)=112
      when 'audio/x-m4a' then get_byte(h,4)=102 and get_byte(h,5)=116 and get_byte(h,6)=121 and get_byte(h,7)=112
      when 'audio/ogg'  then get_byte(h,0)=79 and get_byte(h,1)=103 and get_byte(h,2)=103 and get_byte(h,3)=83
      when 'audio/mpeg' then (get_byte(h,0)=73 and get_byte(h,1)=68 and get_byte(h,2)=51)
                             or (get_byte(h,0)=255 and (get_byte(h,1) & 224)=224)
      when 'audio/aac'  then get_byte(h,0)=255 and (get_byte(h,1) & 240)=240
      else false end;
  end if;
  return false;
end $$;
revoke all on function public.lv_valid_media(text, text, text) from public, anon, authenticated;

drop function if exists public.lv_send(text, text, text, text, text, bigint);
create function public.lv_send(p_tok text, p_kind text, p_body text, p_mime text, p_data text,
                               p_reply bigint default null, p_cid text default null) returns bigint
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); mid bigint; nid bigint;
        v_body text := coalesce(p_body, ''); v_cid text := nullif(btrim(coalesce(p_cid, '')), '');
begin
  if v_cid is not null then
    if length(v_cid) > 40 or v_cid !~ '^[A-Za-z0-9_-]+$' then raise exception 'invalid'; end if;
    select id into nid from public.lv_msgs where uid = u and cid = v_cid;
    if nid is not null then return nid; end if;               -- retry of a message that already arrived
  end if;
  if p_kind is null or p_kind not in ('text', 'photo', 'voice') then raise exception 'invalid'; end if;
  if p_kind = 'text' then
    if length(btrim(v_body)) = 0 or length(v_body) >= 3000 or p_data is not null then raise exception 'invalid'; end if;
  else
    if not public.lv_valid_media(p_kind, p_mime, p_data) then raise exception 'badmedia'; end if;
    if p_kind = 'voice' and v_body !~ '^[0-9]{1,3}$' then raise exception 'invalid'; end if;
    if p_kind = 'photo' then v_body := ''; end if;
    insert into public.lv_media (mime, data) values (lower(p_mime), p_data) returning id into mid;
  end if;
  begin
    insert into public.lv_msgs (uid, kind, body, media, reply, cid)
    values (u, p_kind, v_body, mid, (select id from public.lv_msgs where id = p_reply and deleted_at is null), v_cid)
    returning id into nid;
  exception when unique_violation then                         -- two simultaneous retries: keep one
    select id into nid from public.lv_msgs where uid = u and cid = v_cid;
    if mid is not null then delete from public.lv_media where id = mid; end if;
  end;
  return nid;
end $$;
revoke all on function public.lv_send(text, text, text, text, text, bigint, text) from public, authenticated;
grant execute on function public.lv_send(text, text, text, text, text, bigint, text) to anon;

drop function if exists public.lv_ask(text, text, text);
create function public.lv_ask(p_tok text, p_n text, p_q text, p_cid text default null) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); v_cid text := nullif(btrim(coalesce(p_cid, '')), '');
begin
  if v_cid is not null then
    if length(v_cid) > 40 or v_cid !~ '^[A-Za-z0-9_-]+$' then raise exception 'invalid'; end if;
    if exists (select 1 from public.lv_msgs where uid = u and cid = v_cid) then return; end if;
  end if;
  if length(btrim(coalesce(p_n, ''))) = 0 or length(btrim(coalesce(p_q, ''))) = 0 then raise exception 'invalid'; end if;
  insert into public.lv_used (n) values (left(p_n, 7)) on conflict do nothing;
  begin
    insert into public.lv_msgs (uid, kind, body, cid) values (u, 'q', left(p_n, 7) || E'\n' || left(p_q, 2500), v_cid);
  exception when unique_violation then null;
  end;
end $$;
revoke all on function public.lv_ask(text, text, text, text) from public, authenticated;
grant execute on function public.lv_ask(text, text, text, text) to anon;

-- "Clear chat" becomes a soft delete; media and rows stay for recovery.
create or replace function public.lv_clear(p_tok text) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); t timestamptz := now();
begin
  update public.lv_msgs set deleted_at = t, cleared_at = t where deleted_at is null;
  update public.lv_cfg set v = (v::int + 1)::text where k = 'epoch';
end $$;

create or replace function public.lv_undo_clear(p_tok text) returns integer
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); t timestamptz; n integer;
begin
  select max(cleared_at) into t from public.lv_msgs where cleared_at is not null and deleted_at = cleared_at;
  if t is null then return 0; end if;
  update public.lv_msgs set deleted_at = null, cleared_at = null where cleared_at = t and deleted_at = t;
  get diagnostics n = row_count;
  update public.lv_cfg set v = (v::int + 1)::text where k = 'epoch';
  return n;
end $$;
revoke all on function public.lv_undo_clear(text) from public, authenticated;
grant execute on function public.lv_undo_clear(text) to anon;

-- Same output shape as before, plus cid; hides soft-deleted rows.
create or replace function public.lv_poll(p_tok text, p_last bigint default 0, p_typing boolean default false) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); begin
 insert into public.lv_seen(uid,seen,typing) values (u, now(), case when p_typing then now() end)
  on conflict (uid) do update set seen = now(), typing = case when p_typing then now() else public.lv_seen.typing end;
 return json_build_object(
  'me', u,
  'users', (select coalesce(json_agg(json_build_object('id',x.id,'name',x.name,'on',coalesce(s.seen > now() - interval '15 seconds', false),'ty',coalesce(s.typing > now() - interval '4 seconds', false)) order by x.created_at),'[]'::json) from public.lv_users x left join public.lv_seen s on s.uid = x.id),
  'msgs', (select coalesce(json_agg(m order by m.id),'[]'::json) from (select x.id, x.uid, x.kind, x.body, x.media, x.reply, x.cid, (extract(epoch from x.at)*1000)::bigint as at, r.kind as rk, left(r.body,160) as rb, r.uid as ru from public.lv_msgs x left join public.lv_msgs r on r.id = x.reply and r.deleted_at is null where x.id > p_last and x.deleted_at is null order by x.id desc limit 200) m),
  'reacts', (select coalesce(json_agg(json_build_object('m',r.msg,'u',r.uid,'e',r.emoji)),'[]'::json) from public.lv_reacts r where r.msg > (select coalesce(max(id),0) - 200 from public.lv_msgs) and exists (select 1 from public.lv_msgs mm where mm.id = r.msg and mm.deleted_at is null)),
  'epoch', (select v from public.lv_cfg where k='epoch'),
  'used', (select coalesce(json_agg(n),'[]'::json) from public.lv_used),
  'favs', (select coalesce(json_agg(n),'[]'::json) from public.lv_favs),
  'lv', (select md5(list) from public.lv_game where id=1)); end $$;

-- Question list: never empty, and every overwrite keeps the previous text.
create or replace function public.lv_setlist(p_tok text, p_t text) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); v_old text;
begin
  if length(coalesce(p_t, '')) > 150000 then raise exception 'toolong'; end if;
  if length(btrim(coalesce(p_t, ''))) = 0 then raise exception 'empty'; end if;
  select list into v_old from public.lv_game where id = 1;
  if v_old is distinct from p_t then
    insert into public.lv_game_versions (list, saved_by, reason) values (coalesce(v_old, ''), u, 'before overwrite');
    insert into public.lv_game (id, list) values (1, p_t) on conflict (id) do update set list = excluded.list;
  end if;
end $$;

-- "Reset asked questions" keeps an archive of what was reset.
create or replace function public.lv_unuse(p_tok text) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare u uuid := public.lv_uid(p_tok); begin
  insert into public.lv_used_archive (n, archived_by) select n, u from public.lv_used;
  delete from public.lv_used where true;
end $$;
