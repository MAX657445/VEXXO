-- Миграция 4: сессии на 30 дней, смена кода в кабинете, защищённая загрузка и удаление чертежей,
-- расписание в базе, редактирование записей, расширенные уведомления в Telegram (ответ, напоминание, утренняя сводка).
-- Запускать после schema.sql, migration-2.sql и migration-3.sql. Можно запускать повторно.

-- ---------- Сессии ----------
create table if not exists vx_sessions (
  token_hash text primary key,
  name text not null check (name in ('ulya', 'maxim')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table vx_sessions enable row level security;
revoke all on vx_sessions from anon, authenticated;

-- Кто это: по коду (4-12 цифр, с защитой от подбора) или по токену сессии (64 hex-символа).
-- Токен не зависит от блокировки попыток, поэтому запомненные устройства работают даже когда вход по коду временно закрыт.
create or replace function vx_who(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if p_code is null then return null; end if;
  if p_code ~ '^[0-9a-f]{64}$' then
    select name into n from vx_sessions
     where token_hash = encode(sha256(convert_to('vexxo-s:' || p_code, 'utf8')), 'hex') and expires_at > now();
    return n;
  end if;
  if p_code !~ '^[0-9]{4,12}$' then return null; end if;
  if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then
    raise exception 'too_many_attempts';
  end if;
  select name into n from vx_users
   where code_hash = encode(sha256(convert_to('vexxo:' || p_code, 'utf8')), 'hex');
  if n is null then
    insert into vx_attempts default values;
    delete from vx_attempts where at < now() - interval '1 day';
  end if;
  return n;
end $$;
revoke all on function vx_who(text) from public, anon, authenticated;

-- Вход по коду -> токен сессии на 30 дней (или null при неверном коде).
create or replace function vx_session_start(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare n text; tok text;
begin
  if p_code is null or p_code !~ '^[0-9]{4,12}$' then return null; end if;
  n := vx_who(p_code);
  if n is null then return null; end if;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into vx_sessions(token_hash, name, expires_at)
  values (encode(sha256(convert_to('vexxo-s:' || tok, 'utf8')), 'hex'), n, now() + interval '30 days');
  delete from vx_sessions where expires_at < now();
  return tok;
end $$;

create or replace function vx_logout(p_session text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from vx_sessions where token_hash = encode(sha256(convert_to('vexxo-s:' || coalesce(p_session, ''), 'utf8')), 'hex');
end $$;

create or replace function vx_logout_all(p_session text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_session);
begin
  if w is null then return; end if;
  delete from vx_sessions where name = w;
end $$;

-- Смена своего кода. Нужен текущий код. Новый: 6-12 цифр и не такой же, как у другого человека.
-- Возвращает: ok | forbidden | bad_current | bad_new | taken. Остальные устройства выходят.
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
  return 'ok';
end $$;

-- ---------- Чертежи: загрузка и удаление только с разрешения базы ----------
create table if not exists vx_uploads (path text primary key, created_at timestamptz not null default now());
create table if not exists vx_trash (path text primary key, created_at timestamptz not null default now());
alter table vx_uploads enable row level security;
alter table vx_trash enable row level security;
revoke all on vx_uploads, vx_trash from anon, authenticated;

-- Максим просит у базы путь для нового файла; без такого пути хранилище загрузку не принимает (15 минут, один путь на файл).
create or replace function vx_file_prepare(p_code text, p_filename text) returns text
language plpgsql security definer set search_path = public as $$
declare safe text; pth text;
begin
  if vx_who(p_code) is distinct from 'maxim' then return null; end if;
  safe := regexp_replace(coalesce(p_filename, ''), '[^A-Za-z0-9._-]+', '_', 'g');
  safe := regexp_replace(safe, '^[_.]+', '');
  if char_length(safe) > 80 then safe := right(safe, 80); end if;
  if safe = '' then safe := 'file'; end if;
  pth := gen_random_uuid()::text || '/' || safe;
  insert into vx_uploads(path) values (pth);
  delete from vx_uploads where created_at < now() - interval '1 day';
  return pth;
end $$;

create or replace function vx_upload_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_uploads where path = p_name and created_at > now() - interval '15 minutes')
$$;
create or replace function vx_trash_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_trash where path = p_name)
$$;
grant execute on function vx_upload_ok(text), vx_trash_ok(text) to anon;

drop policy if exists "vexxo drawings upload" on storage.objects;
drop policy if exists "vexxo drawings upload v2" on storage.objects;
create policy "vexxo drawings upload v2" on storage.objects for insert to anon
  with check (bucket_id = 'drawings' and vx_upload_ok(name));
drop policy if exists "vexxo drawings remove" on storage.objects;
create policy "vexxo drawings remove" on storage.objects for delete to anon
  using (bucket_id = 'drawings' and vx_trash_ok(name));
drop policy if exists "vexxo drawings find trash" on storage.objects;
create policy "vexxo drawings find trash" on storage.objects for select to anon
  using (bucket_id = 'drawings' and vx_trash_ok(name));

create or replace function vx_file_add(p_code text, p_project text, p_title text, p_date date, p_note text, p_path text, p_filename text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is distinct from 'maxim' then return; end if;
  if not exists (select 1 from vx_uploads where path = p_path) then return; end if;
  insert into vx_files(project, title, day, note, path, filename)
  values (p_project, btrim(p_title), p_date, btrim(coalesce(p_note, '')), p_path, coalesce(p_filename, ''));
  delete from vx_uploads where path = p_path;
end $$;

-- Удаление: запись уходит из списка, путь файла попадает в «корзину», сайт стирает сам файл из хранилища и подтверждает.
create or replace function vx_file_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pth text;
begin
  if vx_who(p_code) is distinct from 'maxim' then return; end if;
  delete from vx_files where id = p_id returning path into pth;
  if pth is not null then insert into vx_trash(path) values (pth) on conflict do nothing; end if;
end $$;

create or replace function vx_trash_done(p_code text, p_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is distinct from 'maxim' then return; end if;
  delete from vx_trash where path = p_path;
end $$;

-- ---------- Расписание ----------
create table if not exists vx_schedule (
  id uuid primary key default gen_random_uuid(),
  owner text not null check (owner in ('ulya', 'maxim')),
  day date not null,
  pair int not null check (pair between 1 and 6),
  subject text not null check (char_length(subject) between 1 and 80),
  room text not null default '' check (char_length(room) <= 20),
  created_at timestamptz not null default now()
);
alter table vx_schedule enable row level security;
revoke all on vx_schedule from anon, authenticated;

create or replace function vx_sched_add(p_code text, p_day date, p_pair int, p_subject text, p_room text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null or p_pair not between 1 and 6 then return; end if;
  insert into vx_schedule(owner, day, pair, subject, room) values (w, p_day, p_pair, btrim(p_subject), btrim(coalesce(p_room, '')));
end $$;

create or replace function vx_sched_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_schedule where id = p_id and owner = w;
end $$;

-- ---------- Редактирование ----------
create or replace function vx_item_edit(p_code text, p_id uuid, p_body text, p_day date, p_time text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_items set body = btrim(p_body),
         day = case when kind = 'plan' then coalesce(p_day, day) else null end,
         at_time = case when kind = 'plan' then coalesce(p_time, at_time) else null end
   where id = p_id and (owner = w or by_user = w);
end $$;

-- Событие меняет тот, кто его предложил; ответы сбрасываются (его «согласен» остаётся), второй человек получает уведомление.
create or replace function vx_event_edit(p_code text, p_id uuid, p_title text, p_day date, p_time text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); ev vx_events; other text;
begin
  if w is null then return; end if;
  update vx_events set title = btrim(p_title), day = p_day, at_time = p_time, votes = jsonb_build_object(w, 'yes')
   where id = p_id and by_user = w returning * into ev;
  if ev.id is null then return; end if;
  other := case w when 'ulya' then 'maxim' else 'ulya' end;
  perform vx_tg(other, (case w when 'ulya' then 'Уля изменила' else 'Максим изменил' end) || ' общий план: ' || ev.title
    || ' (' || to_char(ev.day, 'DD.MM') || ' в ' || ev.at_time || '). Ответь на сайте ещё раз.');
end $$;

-- ---------- Загрузка данных ----------
create or replace function vx_load(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'me', w,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'date', day, 'time', at_time, 'by', by_user, 'votes', votes) order by day, at_time, created_at) from vx_events), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'owner', owner, 'text', body, 'when', when_text, 'done', done, 'date', day, 'time', at_time, 'by', coalesce(by_user, owner)) order by day nulls last, at_time nulls last, created_at) from vx_items), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename) order by day, created_at) from vx_files), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'owner', owner, 'date', day, 'pair', pair, 'subject', subject, 'room', room) order by day, pair) from vx_schedule), '[]'::jsonb),
    'trash', case when w = 'maxim' then coalesce((select jsonb_agg(path) from vx_trash), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;

-- ---------- Telegram: ответ на событие, напоминания, утренняя сводка ----------
alter table vx_events add column if not exists reminded boolean not null default false;
alter table vx_items add column if not exists reminded boolean not null default false;

create or replace function vx_notify_vote() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; v text; who text;
begin
  foreach k in array array['ulya', 'maxim'] loop
    v := new.votes ->> k;
    if k <> new.by_user and v in ('yes', 'no') and v is distinct from (old.votes ->> k) then
      who := case k when 'ulya' then (case v when 'yes' then 'Уля согласилась' else 'Уля отказалась' end)
                    else (case v when 'yes' then 'Максим согласился' else 'Максим отказался' end) end;
      perform vx_tg(new.by_user, who || ': ' || new.title || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')');
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists vx_events_vote_notify on vx_events;
create trigger vx_events_vote_notify after update of votes on vx_events for each row execute function vx_notify_vote();

-- Напоминание за час: события (тем, кто не отказался) и планы по времени (хозяину, если не выполнены).
create or replace function vx_remind() returns void
language plpgsql security definer set search_path = public as $$
declare r record; nowm timestamp := (now() at time zone 'Europe/Moscow'); k text;
begin
  for r in select * from vx_events where not reminded and (day + at_time::time) > nowm and (day + at_time::time) <= nowm + interval '1 hour' loop
    foreach k in array array['ulya', 'maxim'] loop
      if coalesce(r.votes ->> k, '') <> 'no' then
        perform vx_tg(k, 'Через час: ' || r.title || ' (' || r.at_time || ')');
      end if;
    end loop;
    update vx_events set reminded = true where id = r.id;
  end loop;
  for r in select * from vx_items where kind = 'plan' and not reminded and not done and day is not null
            and (day + at_time::time) > nowm and (day + at_time::time) <= nowm + interval '1 hour' loop
    perform vx_tg(r.owner, 'Через час: ' || r.body || ' (' || r.at_time || ')');
    update vx_items set reminded = true where id = r.id;
  end loop;
end $$;
revoke all on function vx_remind() from public, anon, authenticated;

-- Утренняя сводка в 8:00 по Москве: пары, планы и события на сегодня, количество невыполненных задач.
create or replace function vx_digest() returns void
language plpgsql security definer set search_path = public as $$
declare k text; today date := (now() at time zone 'Europe/Moscow')::date; msg text; part text; n int;
  dn text[] := array['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];
  pt text[] := array['08:30', '10:15', '12:30', '14:15', '16:00', '18:00'];
begin
  foreach k in array array['ulya', 'maxim'] loop
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
    if part is not null or n > 0 or exists (select 1 from vx_schedule where owner = k and day = today) then
      perform vx_tg(k, msg);
    end if;
  end loop;
end $$;
revoke all on function vx_digest() from public, anon, authenticated;

do $$
begin
  begin create extension if not exists pg_cron with schema pg_catalog; exception when others then raise notice 'pg_cron: %', sqlerrm; end;
  begin perform cron.unschedule('vexxo-remind'); exception when others then null; end;
  begin perform cron.unschedule('vexxo-digest'); exception when others then null; end;
  begin
    perform cron.schedule('vexxo-remind', '*/5 * * * *', 'select vx_remind()');
    perform cron.schedule('vexxo-digest', '0 5 * * *', 'select vx_digest()');
  exception when others then raise notice 'cron schedule: %', sqlerrm;
  end;
end $$;

-- ---------- Права ----------
revoke all on function vx_session_start(text), vx_logout(text), vx_logout_all(text), vx_change_code(text, text, text),
  vx_file_prepare(text, text), vx_file_add(text, text, text, date, text, text, text), vx_file_del(text, uuid), vx_trash_done(text, text),
  vx_sched_add(text, date, int, text, text), vx_sched_del(text, uuid), vx_item_edit(text, uuid, text, date, text),
  vx_event_edit(text, uuid, text, date, text), vx_load(text) from public;
grant execute on function vx_session_start(text), vx_logout(text), vx_logout_all(text), vx_change_code(text, text, text),
  vx_file_prepare(text, text), vx_file_add(text, text, text, date, text, text, text), vx_file_del(text, uuid), vx_trash_done(text, text),
  vx_sched_add(text, date, int, text, text), vx_sched_del(text, uuid), vx_item_edit(text, uuid, text, date, text),
  vx_event_edit(text, uuid, text, date, text), vx_load(text) to anon;
revoke all on function vx_notify_vote() from public, anon, authenticated;

-- Пинг для GitHub Actions: раз в пару дней, чтобы бесплатный проект Supabase не ставился на паузу. Ничего не читает и не пишет.
create or replace function vx_ping() returns timestamptz
language sql security definer set search_path = public as $$ select now() $$;
revoke all on function vx_ping() from public;
grant execute on function vx_ping() to anon;
