-- Batch 1 / part 2: login + register hardening.
-- Root cause fixed: the old functions inserted into lv_fail and then RAISED, which rolled the insert back,
-- so no failure was ever recorded (no brute-force protection). Failures now RETURN an error response
-- (HTTP 400/429 with {"message": code}) so the failure row commits. Client-visible codes are unchanged:
-- bad | locked | badcode | full | invalid | duplicate.
-- Rollback: previous definitions are in migrations 20261027080736 / 20261027081611 (us_app_backend).

create or replace function public.lv_req_ip() returns text
language plpgsql stable set search_path to 'public', 'extensions' as $$
declare h json; v text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then h := null;
  end;
  if h is null then return 'unknown'; end if;
  v := nullif(btrim(h->>'cf-connecting-ip'), '');
  if v is null then v := nullif(btrim(split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1)), ''); end if;
  return left(coalesce(v, 'unknown'), 64);
end $$;

create or replace function public.lv_err(p_code text, p_status int default 400) returns json
language plpgsql set search_path to 'public', 'extensions' as $$
begin
  perform set_config('response.status', p_status::text, true);
  return json_build_object('message', p_code);
end $$;

revoke all on function public.lv_req_ip() from public, anon, authenticated;
revoke all on function public.lv_err(text, int) from public, anon, authenticated;

drop function if exists public.lv_login(text, text);
create function public.lv_login(p_name text, p_pass text) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  u public.lv_users; ok boolean := false;
  v_ip text := public.lv_req_ip();
  v_nm text := left(lower(trim(coalesce(p_name, ''))), 40);
  w interval := interval '10 minutes';
begin
  -- Locks are scoped so a stranger cannot lock your partner out of their own account:
  --   6 failures per (name + IP), 30 per IP across names, 40 per name across all IPs (slows distributed guessing).
  if (select count(*) from public.lv_fail where k = 'l' and nm = v_nm and ip = v_ip and at > now() - w) >= 6
     or (select count(*) from public.lv_fail where ip = v_ip and at > now() - w) >= 30
     or (select count(*) from public.lv_fail where k = 'l' and nm = v_nm and at > now() - w) >= 40
  then return public.lv_err('locked', 429); end if;

  select * into u from public.lv_users where lower(name) = v_nm;
  if u.id is not null and length(coalesce(p_pass, '')) <= 200 then
    ok := (u.pass = crypt(p_pass, u.pass));
  else
    perform crypt(left(coalesce(p_pass, ''), 200), gen_salt('bf'));  -- equalise timing for unknown names
  end if;

  if not ok then
    delete from public.lv_fail where at < now() - interval '1 day';
    if (select count(*) from public.lv_fail) < 20000 then   -- hard cap: table cannot grow without bound
      insert into public.lv_fail (k, ip, nm) values ('l', v_ip, v_nm);
    end if;
    return public.lv_err('bad');
  end if;

  delete from public.lv_fail where k = 'l' and nm = v_nm and ip = v_ip;
  return to_json(public.lv_mk(u.id));
end $$;

drop function if exists public.lv_register(text, text, text);
create function public.lv_register(p_name text, p_pass text, p_code text) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  u uuid; v_n text := trim(coalesce(p_name, ''));
  v_ip text := public.lv_req_ip(); w interval := interval '10 minutes';
begin
  if (select count(*) from public.lv_fail where k = 'reg' and ip = v_ip and at > now() - w) >= 5
     or (select count(*) from public.lv_fail where k = 'reg' and at > now() - w) >= 30
  then return public.lv_err('locked', 429); end if;

  if length(coalesce(p_code, '')) > 100
     or not exists (select 1 from public.lv_cfg where k = 'invite' and v = crypt(coalesce(p_code, ''), v)) then
    delete from public.lv_fail where at < now() - interval '1 day';
    if (select count(*) from public.lv_fail) < 20000 then
      insert into public.lv_fail (k, ip) values ('reg', v_ip);
    end if;
    return public.lv_err('badcode');
  end if;

  if length(v_n) not between 1 and 20 or length(coalesce(p_pass, '')) not between 6 and 200 then
    return public.lv_err('invalid');
  end if;

  perform pg_advisory_xact_lock(7001);                       -- serialises concurrent sign-ups
  if (select count(*) from public.lv_users) >= 2 then return public.lv_err('full'); end if;
  if exists (select 1 from public.lv_users where lower(name) = lower(v_n)) then return public.lv_err('duplicate'); end if;

  insert into public.lv_users (name, pass) values (v_n, crypt(p_pass, gen_salt('bf'))) returning id into u;
  return to_json(public.lv_mk(u));
end $$;

revoke all on function public.lv_login(text, text) from public, authenticated;
revoke all on function public.lv_register(text, text, text) from public, authenticated;
grant execute on function public.lv_login(text, text) to anon;
grant execute on function public.lv_register(text, text, text) to anon;
