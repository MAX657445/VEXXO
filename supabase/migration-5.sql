-- Миграция 5: админ-меню Максима.
-- Журнал действий и журнал входов, закрытие сайта для Ули, сброс кода Ули, выход за Улю, сводка,
-- хранилище чертежей, настройки и проверка Telegram, чистка данных, полная резервная копия.
-- Запускать после migration-4.sql. Можно запускать повторно.

-- ---------- Таблицы ----------
create table if not exists vx_settings (key text primary key, value text not null);
create table if not exists vx_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  who text,
  action text not null,
  detail text not null default ''
);
create index if not exists vx_log_at on vx_log(at);
create table if not exists vx_logins (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  name text,
  kind text not null,
  device text not null default ''
);
create index if not exists vx_logins_at on vx_logins(at);
alter table vx_settings enable row level security;
alter table vx_log enable row level security;
alter table vx_logins enable row level security;
revoke all on vx_settings, vx_log, vx_logins from anon, authenticated;

alter table vx_sessions add column if not exists device text not null default '';
alter table vx_sessions add column if not exists last_seen timestamptz;

-- ---------- Служебные функции ----------
-- Настройка уведомлений: включена, пока явно не выключена.
create or replace function vx_flag(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value from vx_settings where key = p_key), '1') <> '0'
$$;
create or replace function vx_locked() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value from vx_settings where key = 'locked'), '0') = '1'
$$;
-- Человек отключил свои сообщения в Telegram (сам в кабинете или Максим в админке).
create or replace function vx_muted(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value from vx_settings where key = 'tg_mute_' || p_name), '0') = '1'
$$;
-- Все переключатели Telegram одним объектом: all, по типам, mute_ulya, mute_maxim.
create or replace function vx_tg_flags() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('all', vx_flag('tg_all'), 'items', vx_flag('tg_items'), 'events', vx_flag('tg_events'), 'votes', vx_flag('tg_votes'),
                            'edits', vx_flag('tg_edits'), 'remind', vx_flag('tg_remind'), 'digest', vx_flag('tg_digest'),
                            'mute_ulya', vx_muted('ulya'), 'mute_maxim', vx_muted('maxim'))
$$;
revoke all on function vx_flag(text), vx_locked(), vx_muted(text), vx_tg_flags() from public, anon, authenticated;

-- Кто это. Дополнено: запоминает имя на время запроса (для журнала действий) и не пускает Улю, пока сайт закрыт.
create or replace function vx_who(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if p_code is null then return null; end if;
  if p_code ~ '^[0-9a-f]{64}$' then
    select name into n from vx_sessions
     where token_hash = encode(sha256(convert_to('vexxo-s:' || p_code, 'utf8')), 'hex') and expires_at > now();
  elsif p_code ~ '^[0-9]{4,12}$' then
    if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then
      raise exception 'too_many_attempts';
    end if;
    select name into n from vx_users
     where code_hash = encode(sha256(convert_to('vexxo:' || p_code, 'utf8')), 'hex');
    if n is null then
      insert into vx_attempts default values;
      delete from vx_attempts where at < now() - interval '1 day';
    end if;
  else
    return null;
  end if;
  if n = 'ulya' and vx_locked() then
    perform set_config('vexxo.who', '', true);
    raise exception 'site_locked';
  end if;
  perform set_config('vexxo.who', coalesce(n, ''), true);
  return n;
end $$;
revoke all on function vx_who(text) from public, anon, authenticated;

create or replace function vx_is_admin(p_code text) returns boolean
language sql security definer set search_path = public as $$ select coalesce(vx_who(p_code) = 'maxim', false) $$;
revoke all on function vx_is_admin(text) from public, anon, authenticated;

-- ---------- Журнал действий (кто что добавил, изменил, удалил) ----------
create or replace function vx_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text := nullif(current_setting('vexxo.who', true), ''); a text; d text;
begin
  if w is null then return null; end if;
  if TG_TABLE_NAME = 'vx_events' then
    if TG_OP = 'INSERT' then a := 'event_add'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif TG_OP = 'DELETE' then a := 'event_del'; d := old.title;
    elsif new.title is distinct from old.title or new.day is distinct from old.day or new.at_time is distinct from old.at_time then
      a := 'event_edit'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif new.votes is distinct from old.votes then
      a := 'event_vote'; d := new.title || ': ' || coalesce(nullif(new.votes ->> w, ''), 'сброшен ответ');
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_items' then
    if TG_OP = 'INSERT' then a := new.kind || '_add'; d := 'для ' || case new.owner when 'ulya' then 'Ули' else 'Максима' end || ': ' || new.body
      || case when new.day is not null then ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')' else '' end;
    elsif TG_OP = 'DELETE' then a := old.kind || '_del'; d := old.body;
    elsif new.done is distinct from old.done then a := 'item_done'; d := new.body || case when new.done then ' (выполнено)' else ' (вернули в работу)' end;
    elsif new.body is distinct from old.body or new.day is distinct from old.day or new.at_time is distinct from old.at_time then
      a := 'item_edit'; d := new.body;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_files' then
    if TG_OP = 'INSERT' then a := 'file_add'; d := new.title || ' / ' || new.filename;
    elsif TG_OP = 'DELETE' then a := 'file_del'; d := old.title || ' / ' || old.filename;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_schedule' then
    if TG_OP = 'INSERT' then a := 'sched_add'; d := case new.owner when 'ulya' then 'Уля' else 'Максим' end || ': ' || to_char(new.day, 'DD.MM') || ' ' || new.pair || '-я ' || new.subject;
    elsif TG_OP = 'DELETE' then a := 'sched_del'; d := case old.owner when 'ulya' then 'Уля' else 'Максим' end || ': ' || to_char(old.day, 'DD.MM') || ' ' || old.pair || '-я ' || old.subject;
    else return null; end if;
  else
    return null;
  end if;
  insert into vx_log(who, action, detail) values (w, a, left(d, 300));
  if random() < 0.02 then delete from vx_log where at < now() - interval '120 days'; end if;
  return null;
end $$;
revoke all on function vx_log_change() from public, anon, authenticated;

drop trigger if exists vx_events_log on vx_events;
create trigger vx_events_log after insert or update or delete on vx_events for each row execute function vx_log_change();
drop trigger if exists vx_items_log on vx_items;
create trigger vx_items_log after insert or update or delete on vx_items for each row execute function vx_log_change();
drop trigger if exists vx_files_log on vx_files;
create trigger vx_files_log after insert or delete on vx_files for each row execute function vx_log_change();
drop trigger if exists vx_schedule_log on vx_schedule;
create trigger vx_schedule_log after insert or delete on vx_schedule for each row execute function vx_log_change();

-- ---------- Telegram: отправка возвращает номер запроса; каждый тип уведомлений можно выключить ----------
drop function if exists vx_tg(text, text);
create or replace function vx_tg(p_to text, p_text text, p_kind text default 'misc') returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; cid bigint; rid bigint;
begin
  -- Автоматические уведомления: главный выключатель, тип и личное отключение. Явные действия из админки (misc) идут всегда.
  if p_kind <> 'misc' and (not vx_flag('tg_all') or not vx_flag('tg_' || p_kind) or vx_muted(p_to)) then return null; end if;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  select chat_id into cid from vx_notify where name = p_to;
  if tok is null or cid is null then return null; end if;
  select net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', cid, 'text', p_text)
  ) into rid;
  return rid;
exception when others then
  return null; -- уведомление не должно ломать основное действие
end $$;
revoke all on function vx_tg(text, text, text) from public, anon, authenticated;

create or replace function vx_notify_item() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text; what text;
begin
  if new.by_user is null or new.by_user = new.owner then return new; end if;
  who := case new.by_user when 'ulya' then 'Уля' else 'Максим' end;
  what := case when new.kind = 'plan'
    then 'план: ' || new.body || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')'
    else 'задачу: ' || new.body end;
  perform vx_tg(new.owner, who || case new.by_user when 'ulya' then ' добавила' else ' добавил' end || ' тебе ' || what, 'items');
  return new;
end $$;

create or replace function vx_notify_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text; other text;
begin
  who := case new.by_user when 'ulya' then 'Уля' else 'Максим' end;
  other := case new.by_user when 'ulya' then 'maxim' else 'ulya' end;
  perform vx_tg(other, who || case new.by_user when 'ulya' then ' предложила' else ' предложил' end || ' общий план: ' || new.title || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || '). Ответь на сайте: согласен или отказаться.', 'events');
  return new;
end $$;

create or replace function vx_notify_vote() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; v text; who text;
begin
  foreach k in array array['ulya', 'maxim'] loop
    v := new.votes ->> k;
    if k <> new.by_user and v in ('yes', 'no') and v is distinct from (old.votes ->> k) then
      who := case k when 'ulya' then (case v when 'yes' then 'Уля согласилась' else 'Уля отказалась' end)
                    else (case v when 'yes' then 'Максим согласился' else 'Максим отказался' end) end;
      perform vx_tg(new.by_user, who || ': ' || new.title || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')', 'votes');
    end if;
  end loop;
  return new;
end $$;

-- Максим может править и отмечать любые записи (в том числе Улины), Уля только свои.
create or replace function vx_item_set(p_code text, p_id uuid, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_items set done = p_done where id = p_id and (owner = w or by_user = w or w = 'maxim');
end $$;

create or replace function vx_item_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_items where id = p_id and (owner = w or by_user = w or w = 'maxim');
end $$;

create or replace function vx_item_edit(p_code text, p_id uuid, p_body text, p_day date, p_time text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_items set body = btrim(p_body),
         day = case when kind = 'plan' then coalesce(p_day, day) else null end,
         at_time = case when kind = 'plan' then coalesce(p_time, at_time) else null end
   where id = p_id and (owner = w or by_user = w or w = 'maxim');
end $$;

create or replace function vx_sched_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_schedule where id = p_id and (owner = w or w = 'maxim');
end $$;

create or replace function vx_event_edit(p_code text, p_id uuid, p_title text, p_day date, p_time text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); ev vx_events; other text;
begin
  if w is null then return; end if;
  update vx_events set title = btrim(p_title), day = p_day, at_time = p_time, votes = jsonb_build_object(w, 'yes')
   where id = p_id and (by_user = w or w = 'maxim') returning * into ev;
  if ev.id is null then return; end if;
  other := case w when 'ulya' then 'maxim' else 'ulya' end;
  perform vx_tg(other, (case w when 'ulya' then 'Уля изменила' else 'Максим изменил' end) || ' общий план: ' || ev.title
    || ' (' || to_char(ev.day, 'DD.MM') || ' в ' || ev.at_time || '). Ответь на сайте ещё раз.', 'edits');
end $$;

create or replace function vx_remind() returns void
language plpgsql security definer set search_path = public as $$
declare r record; nowm timestamp := (now() at time zone 'Europe/Moscow'); k text;
begin
  for r in select * from vx_events where not reminded and (day + at_time::time) > nowm and (day + at_time::time) <= nowm + interval '1 hour' loop
    foreach k in array array['ulya', 'maxim'] loop
      if coalesce(r.votes ->> k, '') <> 'no' then
        perform vx_tg(k, 'Через час: ' || r.title || ' (' || r.at_time || ')', 'remind');
      end if;
    end loop;
    update vx_events set reminded = true where id = r.id;
  end loop;
  for r in select * from vx_items where kind = 'plan' and not reminded and not done and day is not null
            and (day + at_time::time) > nowm and (day + at_time::time) <= nowm + interval '1 hour' loop
    perform vx_tg(r.owner, 'Через час: ' || r.body || ' (' || r.at_time || ')', 'remind');
    update vx_items set reminded = true where id = r.id;
  end loop;
end $$;
revoke all on function vx_remind() from public, anon, authenticated;

-- Утренняя сводка. Без аргумента идёт обоим (по расписанию); с именем отправляется только ему и даже если рассылка выключена (кнопка «Отправить мне сейчас»).
drop function if exists vx_digest();
create or replace function vx_digest(p_only text default null) returns void
language plpgsql security definer set search_path = public as $$
declare k text; today date := (now() at time zone 'Europe/Moscow')::date; msg text; part text; n int; tg_kind text;
  dn text[] := array['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];
  pt text[] := array['08:30', '10:15', '12:30', '14:15', '16:00', '18:00'];
begin
  tg_kind := case when p_only is null then 'digest' else 'misc' end;
  foreach k in array array['ulya', 'maxim'] loop
    if p_only is not null and k <> p_only then continue; end if;
    msg := 'Доброе утро! Сегодня ' || dn[extract(dow from today)::int + 1] || ', ' || to_char(today, 'DD.MM') || '.';
    select string_agg('• ' || s.pair || '-я (' || pt[s.pair] || ') ' || s.subject || case when s.room <> '' then ' ' || s.room else '' end, E'\n' order by s.pair)
      into part from vx_schedule s where s.owner = k and s.day = today;
    if part is not null then msg := msg || E'\n\nПары:\n' || part; end if;
    select string_agg('• ' || x.t || ' ' || x.title, E'\n' order by x.t) into part from (
      select at_time as t, body as title from vx_items where kind = 'plan' and owner = k and day = today and not done
      union all
      select at_time, title from vx_events where day = today and coalesce(votes ->> k, '') <> 'no') x;
    if part is not null then msg := msg || E'\n\nПланы:\n' || part; end if;
    select count(*) into n from vx_items where kind = 'task' and owner = k and not done;
    if n > 0 then msg := msg || E'\n\nНевыполненных задач: ' || n; end if;
    if part is not null or n > 0 or exists (select 1 from vx_schedule where owner = k and day = today) or p_only is not null then
      perform vx_tg(k, msg, tg_kind);
    end if;
  end loop;
end $$;
revoke all on function vx_digest(text) from public, anon, authenticated;

-- ---------- Вход, выход, смена кода: теперь с журналом входов ----------
drop function if exists vx_session_start(text);
create or replace function vx_session_start(p_code text, p_device text default '') returns text
language plpgsql security definer set search_path = public as $$
declare n text; tok text; dev text := left(btrim(coalesce(p_device, '')), 60);
begin
  if p_code is null or p_code !~ '^[0-9]{4,12}$' then return null; end if;
  n := vx_who(p_code);
  if n is null then return null; end if;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into vx_sessions(token_hash, name, expires_at, device, last_seen)
  values (encode(sha256(convert_to('vexxo-s:' || tok, 'utf8')), 'hex'), n, now() + interval '30 days', dev, now());
  delete from vx_sessions where expires_at < now();
  insert into vx_logins(name, kind, device) values (n, 'login', dev);
  delete from vx_logins where at < now() - interval '180 days';
  return tok;
end $$;

create or replace function vx_logout(p_session text) returns void
language plpgsql security definer set search_path = public as $$
declare n text; dev text;
begin
  delete from vx_sessions where token_hash = encode(sha256(convert_to('vexxo-s:' || coalesce(p_session, ''), 'utf8')), 'hex')
  returning name, device into n, dev;
  if n is not null then insert into vx_logins(name, kind, device) values (n, 'logout', dev); end if;
end $$;

create or replace function vx_logout_all(p_session text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_session);
begin
  if w is null then return; end if;
  delete from vx_sessions where name = w;
  insert into vx_logins(name, kind) values (w, 'logout_all');
end $$;

create or replace function vx_change_code(p_session text, p_current text, p_new text) returns text
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_session); h_cur text; h_new text;
begin
  if w is null or p_session !~ '^[0-9a-f]{64}$' then return 'forbidden'; end if;
  if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then
    raise exception 'too_many_attempts';
  end if;
  h_cur := encode(sha256(convert_to('vexxo:' || coalesce(p_current, ''), 'utf8')), 'hex');
  if not exists (select 1 from vx_users where name = w and code_hash = h_cur) then
    insert into vx_attempts default values;
    return 'bad_current';
  end if;
  if p_new is null or p_new !~ '^[0-9]{6,12}$' then return 'bad_new'; end if;
  h_new := encode(sha256(convert_to('vexxo:' || p_new, 'utf8')), 'hex');
  if exists (select 1 from vx_users where name <> w and code_hash = h_new) then return 'taken'; end if;
  update vx_users set code_hash = h_new where name = w;
  delete from vx_sessions
   where name = w and token_hash <> encode(sha256(convert_to('vexxo-s:' || p_session, 'utf8')), 'hex');
  insert into vx_logins(name, kind) values (w, 'code_change');
  return 'ok';
end $$;

-- Загрузка данных: заодно отмечает, когда устройство было на сайте (не чаще раза в минуту).
create or replace function vx_load(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return jsonb_build_object('error', 'forbidden'); end if;
  if p_code ~ '^[0-9a-f]{64}$' then
    update vx_sessions set last_seen = now()
     where token_hash = encode(sha256(convert_to('vexxo-s:' || p_code, 'utf8')), 'hex')
       and (last_seen is null or last_seen < now() - interval '1 minute');
  end if;
  return jsonb_build_object(
    'me', w,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'date', day, 'time', at_time, 'by', by_user, 'votes', votes) order by day, at_time, created_at) from vx_events), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'owner', owner, 'text', body, 'when', when_text, 'done', done, 'date', day, 'time', at_time, 'by', coalesce(by_user, owner)) order by day nulls last, at_time nulls last, created_at) from vx_items), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename) order by day, created_at) from vx_files), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'owner', owner, 'date', day, 'pair', pair, 'subject', subject, 'room', room) order by day, pair) from vx_schedule), '[]'::jsonb),
    'trash', case when w = 'maxim' then coalesce((select jsonb_agg(path) from vx_trash), '[]'::jsonb) else '[]'::jsonb end,
    'tg_muted', vx_muted(w)
  );
end $$;

-- Свои сообщения в Telegram: включить или выключить (p_on = true значит получать).
create or replace function vx_me_tg(p_code text, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return null; end if;
  insert into vx_settings(key, value) values ('tg_mute_' || w, case when p_on then '0' else '1' end)
  on conflict (key) do update set value = excluded.value;
  insert into vx_log(who, action, detail) values (w, 'tg_self', case when p_on then 'включил(а) свои сообщения в Telegram' else 'выключил(а) свои сообщения в Telegram' end);
  return vx_muted(w);
end $$;

-- ---------- Админ-функции (только Максим; у Ули всегда {"error":"forbidden"}) ----------
-- Сводка: счётчики, хранилище, активность, неудачные входы, состояние Telegram и расписаний (pg_cron).
create or replace function vx_admin_overview(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare cr jsonb := '[]'::jsonb; net_ok int := 0; net_fail int := 0; tokok boolean := false; st_bytes bigint := 0; st_n int := 0;
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  begin
    select coalesce(jsonb_agg(jsonb_build_object('name', j.jobname, 'schedule', j.schedule, 'active', j.active,
             'last_at', d.start_time, 'last_status', d.status, 'last_msg', left(coalesce(d.return_message, ''), 120)) order by j.jobname), '[]'::jsonb)
      into cr
      from cron.job j
      left join lateral (select x.start_time, x.status, x.return_message from cron.job_run_details x where x.jobid = j.jobid order by x.start_time desc limit 1) d on true
     where j.jobname like 'vexxo-%';
  exception when others then cr := '[]'::jsonb; end;
  begin
    select count(*) filter (where status_code between 200 and 299),
           count(*) filter (where status_code is null or status_code not between 200 and 299)
      into net_ok, net_fail from net._http_response where created > now() - interval '1 day';
  exception when others then null; end;
  begin
    select exists (select 1 from vault.decrypted_secrets where name = 'tg_token') into tokok;
  exception when others then tokok := false; end;
  begin
    select coalesce(sum((metadata ->> 'size')::bigint), 0), count(*) into st_bytes, st_n from storage.objects where bucket_id = 'drawings';
  exception when others then null; end;
  return jsonb_build_object(
    'locked', vx_locked(),
    'counts', jsonb_build_object(
      'events', (select count(*) from vx_events),
      'events_upcoming', (select count(*) from vx_events where day >= (now() at time zone 'Europe/Moscow')::date),
      'tasks_open', (select count(*) from vx_items where kind = 'task' and not done),
      'tasks_done', (select count(*) from vx_items where kind = 'task' and done),
      'plans_open', (select count(*) from vx_items where kind = 'plan' and not done),
      'plans_done', (select count(*) from vx_items where kind = 'plan' and done),
      'files', (select count(*) from vx_files),
      'sched', (select count(*) from vx_schedule),
      'log', (select count(*) from vx_log)),
    'storage', jsonb_build_object('bytes', st_bytes, 'objects', st_n),
    'users', (select jsonb_object_agg(u.name, jsonb_build_object(
        'sessions', (select count(*) from vx_sessions s where s.name = u.name and s.expires_at > now()),
        'last_seen', (select max(s.last_seen) from vx_sessions s where s.name = u.name),
        'last_login', (select max(l.at) from vx_logins l where l.name = u.name and l.kind = 'login')))
      from (values ('ulya'), ('maxim')) u(name)),
    'failed', jsonb_build_object('count_24h', (select count(*) from vx_attempts where at > now() - interval '1 day'), 'last', (select max(at) from vx_attempts)),
    'tg', jsonb_build_object('token', tokok,
      'chats', (select coalesce(jsonb_object_agg(name, true), '{}'::jsonb) from vx_notify),
      'ok', net_ok, 'fail', net_fail,
      'flags', vx_tg_flags()),
    'cron', cr
  );
end $$;

-- Доступ: активные устройства, журнал входов, неудачные попытки.
create or replace function vx_admin_logins(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'locked', vx_locked(),
    'sessions', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'device', device, 'created', created_at, 'last_seen', last_seen)
                                          order by coalesce(last_seen, created_at) desc) from vx_sessions where expires_at > now()), '[]'::jsonb),
    'logins', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'name', name, 'kind', kind, 'device', device) order by id desc)
                        from (select * from vx_logins order by id desc limit 40) x), '[]'::jsonb),
    'failed', jsonb_build_object('count_24h', (select count(*) from vx_attempts where at > now() - interval '1 day'),
                                 'count_5m', (select count(*) from vx_attempts where at > now() - interval '5 minutes'),
                                 'last', (select max(at) from vx_attempts))
  );
end $$;

-- Закрыть сайт для Ули / открыть. Максим заходит всегда. Уля видит «сайт временно закрыт».
create or replace function vx_admin_lock(p_code text, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return null; end if;
  insert into vx_settings(key, value) values ('locked', case when p_on then '1' else '0' end)
  on conflict (key) do update set value = excluded.value;
  insert into vx_logins(name, kind) values ('maxim', case when p_on then 'lock' else 'unlock' end);
  return vx_locked();
end $$;

-- Сбросить код Ули: Максим задаёт новый (6-12 цифр, не такой же, как свой). Все её устройства выходят.
create or replace function vx_admin_reset_code(p_code text, p_new text) returns text
language plpgsql security definer set search_path = public as $$
declare h text;
begin
  if not vx_is_admin(p_code) then return 'forbidden'; end if;
  if p_new is null or p_new !~ '^[0-9]{6,12}$' then return 'bad_new'; end if;
  h := encode(sha256(convert_to('vexxo:' || p_new, 'utf8')), 'hex');
  if exists (select 1 from vx_users where name = 'maxim' and code_hash = h) then return 'taken'; end if;
  insert into vx_users(name, code_hash) values ('ulya', h)
  on conflict (name) do update set code_hash = excluded.code_hash;
  delete from vx_sessions where name = 'ulya';
  insert into vx_logins(name, kind) values ('ulya', 'code_reset');
  return 'ok';
end $$;

-- Выйти за Улю на всех устройствах. Возвращает, сколько устройств закрыто.
create or replace function vx_admin_kick(p_code text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not vx_is_admin(p_code) then return null; end if;
  with d as (delete from vx_sessions where name = 'ulya' returning 1) select count(*) into n from d;
  insert into vx_logins(name, kind) values ('ulya', 'kick');
  return n;
end $$;

-- Хранилище чертежей: занято, что к чему относится, лишние файлы без записи.
create or replace function vx_admin_storage(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st_bytes bigint := 0; st_n int := 0; fl jsonb := '[]'::jsonb; orp jsonb := '[]'::jsonb; orp_b bigint := 0;
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  begin
    select coalesce(sum((metadata ->> 'size')::bigint), 0), count(*) into st_bytes, st_n from storage.objects where bucket_id = 'drawings';
    select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'project', f.project, 'title', f.title, 'filename', f.filename, 'date', f.day,
             'size', (o.metadata ->> 'size')::bigint, 'missing', o.name is null) order by f.day desc, f.created_at desc), '[]'::jsonb)
      into fl from vx_files f left join storage.objects o on o.bucket_id = 'drawings' and o.name = f.path;
    select coalesce(jsonb_agg(jsonb_build_object('name', o.name, 'size', (o.metadata ->> 'size')::bigint, 'created', o.created_at) order by o.created_at), '[]'::jsonb),
           coalesce(sum((o.metadata ->> 'size')::bigint), 0)
      into orp, orp_b from storage.objects o
     where o.bucket_id = 'drawings' and o.created_at < now() - interval '10 minutes'
       and not exists (select 1 from vx_files f where f.path = o.name)
       and not exists (select 1 from vx_uploads u where u.path = o.name)
       and not exists (select 1 from vx_trash t where t.path = o.name);
  exception when others then
    return jsonb_build_object('error', 'storage_unavailable');
  end;
  return jsonb_build_object('bytes', st_bytes, 'objects', st_n, 'files', fl, 'orphans', orp, 'orphan_bytes', orp_b,
                            'trash', (select count(*) from vx_trash));
end $$;

-- Лишние файлы (есть в хранилище, но нет записи) отправляются в «корзину»; сайт сам стирает их из хранилища при следующей загрузке.
create or replace function vx_admin_clean_orphans(p_code text) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not vx_is_admin(p_code) then return null; end if;
  with ins as (
    insert into vx_trash(path)
    select o.name from storage.objects o
     where o.bucket_id = 'drawings' and o.created_at < now() - interval '10 minutes'
       and not exists (select 1 from vx_files f where f.path = o.name)
       and not exists (select 1 from vx_uploads u where u.path = o.name)
    on conflict do nothing returning 1)
  select count(*) into n from ins;
  delete from vx_uploads where created_at < now() - interval '1 day';
  insert into vx_log(who, action, detail) values ('maxim', 'admin_clean', 'лишних файлов: ' || n);
  return n;
end $$;

-- Telegram: тест и сообщение от сайта. Возвращает номер запроса, по нему проверяется результат.
create or replace function vx_admin_tg(p_code text, p_to text, p_text text) returns bigint
language plpgsql security definer set search_path = public as $$
declare rid bigint;
begin
  if not vx_is_admin(p_code) then return null; end if;
  if p_to not in ('ulya', 'maxim') or btrim(coalesce(p_text, '')) = '' then return null; end if;
  rid := vx_tg(p_to, left(btrim(p_text), 1000), 'misc');
  insert into vx_log(who, action, detail) values ('maxim', 'admin_tg', left(p_to || ': ' || btrim(p_text), 300));
  return rid;
end $$;

create or replace function vx_admin_tg_status(p_code text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_id is null then return jsonb_build_object('state', 'not_sent'); end if;
  begin
    select status_code, error_msg, timed_out, left(coalesce(content, ''), 200) as body into r from net._http_response where id = p_id;
  exception when others then return jsonb_build_object('state', 'unknown'); end;
  if not found then return jsonb_build_object('state', 'pending'); end if;
  return jsonb_build_object('state', case when r.status_code between 200 and 299 then 'ok' else 'fail' end,
                            'status', r.status_code, 'error', r.error_msg, 'body', r.body);
end $$;

-- Включить или выключить тип уведомлений.
create or replace function vx_admin_set(p_code text, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_key not in ('tg_all', 'tg_items', 'tg_events', 'tg_votes', 'tg_edits', 'tg_remind', 'tg_digest', 'tg_mute_ulya', 'tg_mute_maxim') then return jsonb_build_object('error', 'bad_key'); end if;
  -- для tg_mute_* значение p_on = true значит «отключить этому человеку»; для остальных true значит «включено»
  insert into vx_settings(key, value) values (p_key, case when p_on then '1' else '0' end)
  on conflict (key) do update set value = excluded.value;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_setting', p_key || ' = ' || case when p_on then 'вкл' else 'выкл' end);
  return vx_tg_flags();
end $$;

-- Запустить задание вручную: 'digest' шлёт сводку только Максиму, 'remind' рассылает напоминания, которые подошли по времени.
create or replace function vx_admin_run(p_code text, p_job text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return null; end if;
  if p_job = 'digest' then perform vx_digest('maxim');
  elsif p_job = 'remind' then perform vx_remind();
  else return false; end if;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_run', p_job);
  return true;
end $$;

-- Чистка: выполненные записи / события и планы старше недели / пары старше 30 дней. Возвращает, сколько удалено.
create or replace function vx_admin_purge(p_code text, p_what text) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; m int := 0; today date := (now() at time zone 'Europe/Moscow')::date;
begin
  if not vx_is_admin(p_code) then return null; end if;
  perform set_config('vexxo.who', '', true); -- одна запись в журнале вместо сотни
  if p_what = 'done' then
    with d as (delete from vx_items where done returning 1) select count(*) into n from d;
  elsif p_what = 'old' then
    with d as (delete from vx_events where day < today - 7 returning 1) select count(*) into n from d;
    with d as (delete from vx_items where kind = 'plan' and day is not null and day < today - 7 returning 1) select count(*) into m from d;
    n := n + m;
  elsif p_what = 'sched' then
    with d as (delete from vx_schedule where day < today - 30 returning 1) select count(*) into n from d;
  else
    return -1;
  end if;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_purge', p_what || ': удалено ' || n);
  return n;
end $$;

-- Журнал действий.
create or replace function vx_admin_log(p_code text, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', at, 'who', who, 'action', action, 'detail', detail) order by id desc)
                   from (select * from vx_log order by id desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) x), '[]'::jsonb);
end $$;

-- Полная резервная копия: все записи, расписание, список чертежей (со ссылками), настройки, журналы. Коды, токены и chat_id не входят.
create or replace function vx_admin_backup(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'exported_at', now(),
    'events', coalesce((select jsonb_agg(to_jsonb(e) - 'reminded' order by e.day, e.at_time) from vx_events e), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i) - 'reminded' order by i.created_at) from vx_items i), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(to_jsonb(s) order by s.day, s.pair) from vx_schedule s), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(to_jsonb(f) order by f.day, f.created_at) from vx_files f), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from vx_settings), '{}'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select * from vx_log order by id desc limit 500) l), '[]'::jsonb),
    'logins', coalesce((select jsonb_agg(to_jsonb(g) order by g.id desc) from (select * from vx_logins order by id desc limit 200) g), '[]'::jsonb)
  );
end $$;

-- ---------- Права ----------
revoke all on function vx_session_start(text, text), vx_logout(text), vx_logout_all(text), vx_change_code(text, text, text), vx_load(text),
  vx_item_set(text, uuid, boolean), vx_item_del(text, uuid), vx_item_edit(text, uuid, text, date, text), vx_sched_del(text, uuid),
  vx_event_edit(text, uuid, text, date, text), vx_me_tg(text, boolean),
  vx_admin_overview(text), vx_admin_logins(text), vx_admin_lock(text, boolean), vx_admin_reset_code(text, text), vx_admin_kick(text),
  vx_admin_storage(text), vx_admin_clean_orphans(text), vx_admin_tg(text, text, text), vx_admin_tg_status(text, bigint),
  vx_admin_set(text, text, boolean), vx_admin_run(text, text), vx_admin_purge(text, text), vx_admin_log(text, int), vx_admin_backup(text) from public;
grant execute on function vx_session_start(text, text), vx_logout(text), vx_logout_all(text), vx_change_code(text, text, text), vx_load(text),
  vx_item_set(text, uuid, boolean), vx_item_del(text, uuid), vx_item_edit(text, uuid, text, date, text), vx_sched_del(text, uuid),
  vx_event_edit(text, uuid, text, date, text), vx_me_tg(text, boolean),
  vx_admin_overview(text), vx_admin_logins(text), vx_admin_lock(text, boolean), vx_admin_reset_code(text, text), vx_admin_kick(text),
  vx_admin_storage(text), vx_admin_clean_orphans(text), vx_admin_tg(text, text, text), vx_admin_tg_status(text, bigint),
  vx_admin_set(text, text, boolean), vx_admin_run(text, text), vx_admin_purge(text, text), vx_admin_log(text, int), vx_admin_backup(text) to anon;
revoke all on function vx_notify_item(), vx_notify_event(), vx_notify_vote() from public, anon, authenticated;

notify pgrst, 'reload schema';
