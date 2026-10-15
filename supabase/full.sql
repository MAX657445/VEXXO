-- VEXXO: чистая схема одним файлом.
-- РАЗРУШАЕТ все таблицы и функции vx_* (участники, коды, задачи, события, комментарии, чертежи в таблице, настройки)
-- и создаёт их заново по новой структуре (карта сайта, друзья, доступ, списки, колокольчик).
-- Не трогает: Vault (токен бота), бакет drawings (старые файлы в хранилище останутся лишними), другие схемы.
-- В конце выдаёт стартовые коды входа Уле и Максиму (случайные, 6 цифр): запиши их из результата запроса и сменишь в кабинете.
-- После запуска один раз выполни:  select vx_tg_setup_webhook();  а Telegram каждый подключит заново ссылкой из бота.

do $$ declare r record; begin
  begin
    for r in select jobname from cron.job where jobname like 'vexxo-%' loop perform cron.unschedule(r.jobname); end loop;
  exception when others then null; end;
end $$;
do $$ declare r record; begin
  for r in select p.oid::regprocedure::text as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'vx\_%' loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
  for r in select tablename from pg_tables where schemaname = 'public' and tablename like 'vx\_%' loop
    execute 'drop table if exists public.' || quote_ident(r.tablename) || ' cascade';
  end loop;
end $$;


-- ======== schema.sql ========
-- VEXXO: таблицы, функции и хранилище для календаря, досок и чертежей.
-- Выполнить один раз: Supabase -> SQL Editor -> New query -> вставить -> Run.
-- Коды входа здесь не хранятся. Их задают отдельной командой (см. README), чтобы они не попали в GitHub.

-- ---------- Таблицы ----------
create table if not exists vx_users (
  name text primary key check (name in ('ulya', 'maxim')),
  code_hash text not null
);
create table if not exists vx_attempts (at timestamptz not null default now());
create table if not exists vx_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  day date not null,
  at_time text not null check (at_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  by_user text not null check (by_user in ('ulya', 'maxim')),
  votes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists vx_items (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('plan', 'task')),
  owner text not null check (owner in ('ulya', 'maxim')),
  body text not null check (char_length(body) between 1 and 200),
  when_text text not null default '' check (char_length(when_text) <= 60),
  done boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists vx_files (
  id uuid primary key default gen_random_uuid(),
  project text not null check (project in ('sapr', 'arch')),
  title text not null check (char_length(title) between 1 and 100),
  day date not null,
  note text not null default '' check (char_length(note) <= 200),
  path text not null check (path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+$'),
  filename text not null default '' check (char_length(filename) <= 200),
  created_at timestamptz not null default now()
);

-- Прямой доступ к таблицам закрыт: всё идёт только через функции ниже, которые проверяют код.
alter table vx_users enable row level security;
alter table vx_attempts enable row level security;
alter table vx_events enable row level security;
alter table vx_items enable row level security;
alter table vx_files enable row level security;
revoke all on vx_users, vx_attempts, vx_events, vx_items, vx_files from anon, authenticated;

-- ---------- Служебные функции ----------
-- Хеш кода. Запускать вручную (см. README), анонимному доступу не выдаётся.
create or replace function vx_set_code(p_name text, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_code !~ '^[0-9]{4,12}$' then raise exception 'code must be 4-12 digits'; end if;
  insert into vx_users(name, code_hash)
  values (p_name, encode(sha256(convert_to('vexxo:' || p_code, 'utf8')), 'hex'))
  on conflict (name) do update set code_hash = excluded.code_hash;
end $$;
revoke all on function vx_set_code(text, text) from public, anon, authenticated;

-- Кто это по коду. Неверные попытки считаются; при 30 неудачах за 5 минут вход временно закрывается.
create or replace function vx_who(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if p_code is null or p_code !~ '^[0-9]{4,12}$' then return null; end if;
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

-- ---------- Функции для сайта ----------
-- При неверном коде функции ничего не делают и не падают с ошибкой: так неудачная попытка остаётся записанной в vx_attempts.
create or replace function vx_login(p_code text) returns text
language sql security definer set search_path = public as $$ select vx_who(p_code) $$;

create or replace function vx_load(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'me', w,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'date', day, 'time', at_time, 'by', by_user, 'votes', votes) order by day, at_time, created_at) from vx_events), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'owner', owner, 'text', body, 'when', when_text, 'done', done) order by created_at) from vx_items), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename) order by day, created_at) from vx_files), '[]'::jsonb)
  );
end $$;

create or replace function vx_event_add(p_code text, p_title text, p_date date, p_time text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  insert into vx_events(title, day, at_time, by_user, votes)
  values (btrim(p_title), p_date, p_time, w, jsonb_build_object(w, 'yes'));
end $$;

create or replace function vx_event_vote(p_code text, p_id uuid, p_vote text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  if p_vote not in ('yes', 'no', '') then raise exception 'bad vote'; end if;
  update vx_events set votes = votes || jsonb_build_object(w, p_vote) where id = p_id;
end $$;

create or replace function vx_event_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is null then return; end if;
  delete from vx_events where id = p_id;
end $$;

create or replace function vx_item_add(p_code text, p_kind text, p_body text, p_when text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  insert into vx_items(kind, owner, body, when_text) values (p_kind, w, btrim(p_body), btrim(coalesce(p_when, '')));
end $$;

create or replace function vx_item_set(p_code text, p_id uuid, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_items set done = p_done where id = p_id and owner = w;
end $$;

create or replace function vx_item_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_items where id = p_id and owner = w;
end $$;

-- Чертежи добавляет и удаляет только Максим.
create or replace function vx_file_add(p_code text, p_project text, p_title text, p_date date, p_note text, p_path text, p_filename text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is distinct from 'maxim' then return; end if;
  insert into vx_files(project, title, day, note, path, filename)
  values (p_project, btrim(p_title), p_date, btrim(coalesce(p_note, '')), p_path, coalesce(p_filename, ''));
end $$;

create or replace function vx_file_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is distinct from 'maxim' then return; end if;
  delete from vx_files where id = p_id;
end $$;

-- Доступ к функциям для сайта (анонимный ключ). Внутри каждая функция сама проверяет код.
revoke all on function vx_login(text), vx_load(text), vx_event_add(text, text, date, text), vx_event_vote(text, uuid, text),
  vx_event_del(text, uuid), vx_item_add(text, text, text, text), vx_item_set(text, uuid, boolean), vx_item_del(text, uuid),
  vx_file_add(text, text, text, date, text, text, text), vx_file_del(text, uuid) from public;
grant execute on function vx_login(text), vx_load(text), vx_event_add(text, text, date, text), vx_event_vote(text, uuid, text),
  vx_event_del(text, uuid), vx_item_add(text, text, text, text), vx_item_set(text, uuid, boolean), vx_item_del(text, uuid),
  vx_file_add(text, text, text, date, text, text, text), vx_file_del(text, uuid) to anon;

-- ---------- Хранилище чертежей ----------
-- Бакет публичный: файл открывается по ссылке с длинным случайным именем. Загрузка разрешена сайту, размер до 25 МБ.
insert into storage.buckets (id, name, public, file_size_limit)
values ('drawings', 'drawings', true, 26214400)
on conflict (id) do update set public = true, file_size_limit = 26214400;

drop policy if exists "vexxo drawings upload" on storage.objects;
create policy "vexxo drawings upload" on storage.objects for insert to anon with check (bucket_id = 'drawings');

-- ======== migration-2.sql ========
-- Миграция 2: планы и задачи можно добавлять друг другу; у плана есть дата и время.
alter table vx_items add column if not exists day date;
alter table vx_items add column if not exists at_time text;
alter table vx_items add column if not exists by_user text;
alter table vx_items drop constraint if exists vx_items_at_time_check;
alter table vx_items add constraint vx_items_at_time_check check (at_time is null or at_time ~ '^[0-2][0-9]:[0-5][0-9]$');
alter table vx_items drop constraint if exists vx_items_by_user_check;
alter table vx_items add constraint vx_items_by_user_check check (by_user is null or by_user in ('ulya', 'maxim'));

create or replace function vx_load(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'me', w,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'date', day, 'time', at_time, 'by', by_user, 'votes', votes) order by day, at_time, created_at) from vx_events), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'owner', owner, 'text', body, 'when', when_text, 'done', done, 'date', day, 'time', at_time, 'by', coalesce(by_user, owner)) order by day nulls last, at_time nulls last, created_at) from vx_items), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename) order by day, created_at) from vx_files), '[]'::jsonb)
  );
end $$;

drop function if exists vx_item_add(text, text, text, text);
create or replace function vx_item_add(p_code text, p_kind text, p_body text, p_when text default '', p_owner text default null, p_day date default null, p_time text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); o text;
begin
  if w is null then return; end if;
  o := coalesce(p_owner, w);
  if o not in ('ulya', 'maxim') then return; end if;
  if p_kind = 'plan' and (p_day is null or p_time is null) then return; end if;
  insert into vx_items(kind, owner, body, when_text, by_user, day, at_time)
  values (p_kind, o, btrim(p_body), btrim(coalesce(p_when, '')), w,
          case when p_kind = 'plan' then p_day end, case when p_kind = 'plan' then p_time end);
end $$;

create or replace function vx_item_set(p_code text, p_id uuid, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_items set done = p_done where id = p_id and (owner = w or by_user = w);
end $$;

create or replace function vx_item_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_items where id = p_id and (owner = w or by_user = w);
end $$;

revoke all on function vx_item_add(text, text, text, text, text, date, text) from public;
grant execute on function vx_item_add(text, text, text, text, text, date, text), vx_item_set(text, uuid, boolean), vx_item_del(text, uuid), vx_load(text) to anon;

-- ======== migration-3.sql ========
-- Миграция 3: уведомления в Telegram, когда другой человек добавил запись или предложил событие.
-- Токен бота и chat_id в репозиторий не кладутся: токен лежит в Supabase Vault, chat_id в таблице vx_notify.
create extension if not exists pg_net with schema extensions;

create table if not exists vx_notify (
  name text primary key check (name in ('ulya', 'maxim')),
  chat_id bigint not null
);
alter table vx_notify enable row level security;
revoke all on vx_notify from anon, authenticated;

create or replace function vx_tg(p_to text, p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; cid bigint;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  select chat_id into cid from vx_notify where name = p_to;
  if tok is null or cid is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', cid, 'text', p_text)
  );
exception when others then
  return; -- уведомление не должно ломать добавление записи
end $$;
revoke all on function vx_tg(text, text) from public, anon, authenticated;

create or replace function vx_notify_item() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text; what text;
begin
  if new.by_user is null or new.by_user = new.owner then return new; end if;
  who := case new.by_user when 'ulya' then 'Уля' else 'Максим' end;
  what := case when new.kind = 'plan'
    then 'план: ' || new.body || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')'
    else 'задачу: ' || new.body end;
  perform vx_tg(new.owner, who || case new.by_user when 'ulya' then ' добавила' else ' добавил' end || ' тебе ' || what);
  return new;
end $$;
drop trigger if exists vx_items_notify on vx_items;
create trigger vx_items_notify after insert on vx_items for each row execute function vx_notify_item();

create or replace function vx_notify_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text; other text;
begin
  who := case new.by_user when 'ulya' then 'Уля' else 'Максим' end;
  other := case new.by_user when 'ulya' then 'maxim' else 'ulya' end;
  perform vx_tg(other, who || case new.by_user when 'ulya' then ' предложила' else ' предложил' end || ' общий план: ' || new.title || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || '). Ответь на сайте: согласен или отказаться.');
  return new;
end $$;
drop trigger if exists vx_events_notify on vx_events;
create trigger vx_events_notify after insert on vx_events for each row execute function vx_notify_event();

-- ======== migration-4.sql ========
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
  safe := regexp_replace(safe, '^_+', '');
  if safe like '.%' then safe := 'file' || safe; end if;
  if char_length(safe) > 80 then safe := right(safe, 80); end if;
  if safe = '' or safe = '.' or safe = '..' then safe := 'file'; end if;
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

-- ======== migration-5.sql ========
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

-- ======== migration-6.sql ========
-- Миграция 6: полноценные задачи (статус, приоритет, срок, комментарии), категории событий и связь события с задачей,
-- лента последних изменений для главной, уведомления о комментариях, сроки задач в утренней сводке.
-- Запускать после migration-5.sql. Можно запускать повторно.

-- ---------- Задачи ----------
alter table vx_items add column if not exists status text not null default 'todo';
alter table vx_items add column if not exists priority text not null default 'mid';
alter table vx_items add column if not exists due date;
alter table vx_items drop constraint if exists vx_items_status_check;
alter table vx_items add constraint vx_items_status_check check (status in ('todo', 'doing', 'review', 'done'));
alter table vx_items drop constraint if exists vx_items_priority_check;
alter table vx_items add constraint vx_items_priority_check check (priority in ('low', 'mid', 'high'));
update vx_items set status = 'done' where done and status <> 'done';

-- «Выполнено» (галочка) и статус «Готово» всегда совпадают.
create or replace function vx_items_sync() returns trigger
language plpgsql as $$
begin
  if TG_OP = 'INSERT' then
    if new.done then new.status := 'done'; else new.done := (new.status = 'done'); end if;
  elsif new.status is distinct from old.status then
    new.done := (new.status = 'done');
  elsif new.done is distinct from old.done then
    new.status := case when new.done then 'done' when old.status = 'done' then 'todo' else old.status end;
  end if;
  return new;
end $$;
drop trigger if exists vx_items_sync_t on vx_items;
create trigger vx_items_sync_t before insert or update on vx_items for each row execute function vx_items_sync();

-- Комментарии к задачам и планам.
create table if not exists vx_comments (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references vx_items(id) on delete cascade,
  by_user text not null check (by_user in ('ulya', 'maxim')),
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists vx_comments_item on vx_comments(item_id);
alter table vx_comments enable row level security;
revoke all on vx_comments from anon, authenticated;

-- ---------- События: категория и связь с задачей ----------
alter table vx_events add column if not exists category text not null default 'personal';
alter table vx_events drop constraint if exists vx_events_category_check;
alter table vx_events add constraint vx_events_category_check check (category in ('work', 'study', 'personal', 'other'));
alter table vx_events add column if not exists task_id uuid references vx_items(id) on delete set null;

-- ---------- Журнал действий: статус, приоритет, срок, комментарии ----------
create or replace function vx_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text := nullif(current_setting('vexxo.who', true), ''); a text; d text;
begin
  if w is null then return null; end if;
  if TG_TABLE_NAME = 'vx_events' then
    if TG_OP = 'INSERT' then a := 'event_add'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif TG_OP = 'DELETE' then a := 'event_del'; d := old.title;
    elsif new.title is distinct from old.title or new.day is distinct from old.day or new.at_time is distinct from old.at_time or new.category is distinct from old.category then
      a := 'event_edit'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif new.votes is distinct from old.votes then
      a := 'event_vote'; d := new.title || ': ' || coalesce(nullif(new.votes ->> w, ''), 'сброшен ответ');
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_items' then
    if TG_OP = 'INSERT' then a := new.kind || '_add'; d := 'для ' || case new.owner when 'ulya' then 'Ули' else 'Максима' end || ': ' || new.body
      || case when new.day is not null then ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')' else '' end;
    elsif TG_OP = 'DELETE' then a := old.kind || '_del'; d := old.body;
    elsif new.done is distinct from old.done then a := 'item_done'; d := new.body || case when new.done then ' (выполнено)' else ' (вернули в работу)' end;
    elsif new.status is distinct from old.status then
      a := 'item_status'; d := new.body || ' → ' || case new.status when 'todo' then 'К выполнению' when 'doing' then 'В работе' when 'review' then 'На проверке' else 'Готово' end;
    elsif new.owner is distinct from old.owner then
      a := 'item_owner'; d := new.body || ' → ' || case new.owner when 'ulya' then 'Уля' else 'Максим' end;
    elsif new.body is distinct from old.body or new.day is distinct from old.day or new.at_time is distinct from old.at_time
          or new.priority is distinct from old.priority or new.due is distinct from old.due then
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
  elsif TG_TABLE_NAME = 'vx_comments' then
    if TG_OP = 'INSERT' then a := 'comment_add'; d := coalesce((select body from vx_items where id = new.item_id), '') || ': ' || new.body;
    else return null; end if;
  else
    return null;
  end if;
  insert into vx_log(who, action, detail) values (w, a, left(d, 300));
  if random() < 0.02 then delete from vx_log where at < now() - interval '120 days'; end if;
  return null;
end $$;
revoke all on function vx_log_change() from public, anon, authenticated;
drop trigger if exists vx_comments_log on vx_comments;
create trigger vx_comments_log after insert on vx_comments for each row execute function vx_log_change();

-- ---------- Функции для сайта ----------
-- Новая запись: у задачи есть приоритет и срок.
drop function if exists vx_item_add(text, text, text, text, text, date, text);
create or replace function vx_item_add(p_code text, p_kind text, p_body text, p_when text default '', p_owner text default null,
                                       p_day date default null, p_time text default null, p_priority text default 'mid', p_due date default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); o text;
begin
  if w is null then return; end if;
  o := coalesce(p_owner, w);
  if o not in ('ulya', 'maxim') then return; end if;
  if p_kind = 'plan' and (p_day is null or p_time is null) then return; end if;
  insert into vx_items(kind, owner, body, when_text, by_user, day, at_time, priority, due)
  values (p_kind, o, btrim(p_body), btrim(coalesce(p_when, '')), w,
          case when p_kind = 'plan' then p_day end, case when p_kind = 'plan' then p_time end,
          case when p_priority in ('low', 'mid', 'high') then p_priority else 'mid' end,
          case when p_kind = 'task' then p_due end);
end $$;

-- Правка задачи или плана: название, статус, приоритет, срок, исполнитель. Пустые параметры значит «не менять».
create or replace function vx_task_update(p_code text, p_id uuid, p_body text default null, p_status text default null, p_priority text default null,
                                          p_due date default null, p_clear_due boolean default false, p_owner text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items;
begin
  if w is null then return; end if;
  select * into it from vx_items where id = p_id and (owner = w or by_user = w or w = 'maxim');
  if it.id is null then return; end if;
  if p_status is not null and p_status not in ('todo', 'doing', 'review', 'done') then return; end if;
  if p_priority is not null and p_priority not in ('low', 'mid', 'high') then return; end if;
  if p_owner is not null and p_owner not in ('ulya', 'maxim') then return; end if;
  if p_body is not null and btrim(p_body) = '' then return; end if;
  update vx_items set body = coalesce(btrim(p_body), body), status = coalesce(p_status, status), priority = coalesce(p_priority, priority),
         due = case when it.kind <> 'task' then null when p_clear_due then null else coalesce(p_due, due) end,
         owner = coalesce(p_owner, owner)
   where id = p_id;
  if p_owner is not null and p_owner <> it.owner then
    perform vx_tg(p_owner, case w when 'ulya' then 'Уля передала' else 'Максим передал' end || ' тебе задачу: ' || coalesce(nullif(btrim(p_body), ''), it.body), 'items');
  end if;
end $$;

create or replace function vx_comment_add(p_code text, p_item uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items; other text;
begin
  if w is null or btrim(coalesce(p_body, '')) = '' then return; end if;
  select * into it from vx_items where id = p_item;
  if it.id is null then return; end if;
  insert into vx_comments(item_id, by_user, body) values (p_item, w, left(btrim(p_body), 500));
  other := case w when 'ulya' then 'maxim' else 'ulya' end;
  if other = it.owner or other = coalesce(it.by_user, it.owner) then
    perform vx_tg(other, case w when 'ulya' then 'Уля прокомментировала' else 'Максим прокомментировал' end || ' «' || left(it.body, 60) || '»: ' || left(btrim(p_body), 200), 'comments');
  end if;
end $$;

create or replace function vx_comment_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_comments where id = p_id and (by_user = w or w = 'maxim');
end $$;

-- Событие: категория и (по желанию) связь с задачей.
drop function if exists vx_event_add(text, text, date, text);
create or replace function vx_event_add(p_code text, p_title text, p_date date, p_time text, p_cat text default 'personal', p_task uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  insert into vx_events(title, day, at_time, by_user, votes, category, task_id)
  values (btrim(p_title), p_date, p_time, w, jsonb_build_object(w, 'yes'),
          case when p_cat in ('work', 'study', 'personal', 'other') then p_cat else 'personal' end,
          (select id from vx_items where id = p_task and kind = 'task'));
end $$;

drop function if exists vx_event_edit(text, uuid, text, date, text);
create or replace function vx_event_edit(p_code text, p_id uuid, p_title text, p_day date, p_time text, p_cat text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); ev vx_events; other text;
begin
  if w is null then return; end if;
  update vx_events set title = btrim(p_title), day = p_day, at_time = p_time, votes = jsonb_build_object(w, 'yes'),
         category = case when p_cat in ('work', 'study', 'personal', 'other') then p_cat else category end
   where id = p_id and (by_user = w or w = 'maxim') returning * into ev;
  if ev.id is null then return; end if;
  other := case w when 'ulya' then 'maxim' else 'ulya' end;
  perform vx_tg(other, (case w when 'ulya' then 'Уля изменила' else 'Максим изменил' end) || ' общий план: ' || ev.title
    || ' (' || to_char(ev.day, 'DD.MM') || ' в ' || ev.at_time || '). Ответь на сайте ещё раз.', 'edits');
end $$;

-- Загрузка данных: добавлены статус/приоритет/срок, комментарии, категория и задача события, лента последних изменений.
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
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'date', day, 'time', at_time, 'by', by_user, 'votes', votes, 'cat', category, 'task', task_id) order by day, at_time, created_at) from vx_events), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'owner', owner, 'text', body, 'when', when_text, 'done', done, 'date', day, 'time', at_time, 'by', coalesce(by_user, owner),
                                                           'status', status, 'priority', priority, 'due', due, 'created', created_at) order by day nulls last, at_time nulls last, created_at) from vx_items), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'by', by_user, 'body', body, 'at', created_at) order by created_at)
                          from (select * from vx_comments order by created_at desc limit 400) c), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename) order by day, created_at) from vx_files), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'owner', owner, 'date', day, 'pair', pair, 'subject', subject, 'room', room) order by day, pair) from vx_schedule), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'who', who, 'action', action, 'detail', detail) order by id desc)
                        from (select * from vx_log where action not like 'admin%' and action <> 'tg_self' order by id desc limit 12) r), '[]'::jsonb),
    'trash', case when w = 'maxim' then coalesce((select jsonb_agg(path) from vx_trash), '[]'::jsonb) else '[]'::jsonb end,
    'tg_muted', vx_muted(w)
  );
end $$;

-- ---------- Telegram: комментарии, сроки задач в сводке ----------
create or replace function vx_tg_flags() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('all', vx_flag('tg_all'), 'items', vx_flag('tg_items'), 'events', vx_flag('tg_events'), 'votes', vx_flag('tg_votes'),
                            'edits', vx_flag('tg_edits'), 'comments', vx_flag('tg_comments'), 'remind', vx_flag('tg_remind'), 'digest', vx_flag('tg_digest'),
                            'mute_ulya', vx_muted('ulya'), 'mute_maxim', vx_muted('maxim'))
$$;
revoke all on function vx_tg_flags() from public, anon, authenticated;

create or replace function vx_admin_set(p_code text, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_key not in ('tg_all', 'tg_items', 'tg_events', 'tg_votes', 'tg_edits', 'tg_comments', 'tg_remind', 'tg_digest', 'tg_mute_ulya', 'tg_mute_maxim') then return jsonb_build_object('error', 'bad_key'); end if;
  -- для tg_mute_* значение p_on = true значит «отключить этому человеку»; для остальных true значит «включено»
  insert into vx_settings(key, value) values (p_key, case when p_on then '1' else '0' end)
  on conflict (key) do update set value = excluded.value;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_setting', p_key || ' = ' || case when p_on then 'вкл' else 'выкл' end);
  return vx_tg_flags();
end $$;

create or replace function vx_digest(p_only text default null) returns void
language plpgsql security definer set search_path = public as $$
declare k text; today date := (now() at time zone 'Europe/Moscow')::date; msg text; part text; due_part text; n int; tg_kind text;
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
    select string_agg('• ' || i.body || case when i.due < today then ' (просрочено, ' || to_char(i.due, 'DD.MM') || ')' else '' end, E'\n' order by i.due, i.created_at)
      into due_part from vx_items i where i.kind = 'task' and i.owner = k and not i.done and i.due is not null and i.due <= today;
    if due_part is not null then msg := msg || E'\n\nСрок сегодня и просрочено:\n' || due_part; end if;
    select count(*) into n from vx_items where kind = 'task' and owner = k and not done;
    if n > 0 then msg := msg || E'\n\nНевыполненных задач: ' || n; end if;
    if part is not null or due_part is not null or n > 0 or exists (select 1 from vx_schedule where owner = k and day = today) or p_only is not null then
      perform vx_tg(k, msg, tg_kind);
    end if;
  end loop;
end $$;
revoke all on function vx_digest(text) from public, anon, authenticated;

-- Резервная копия: добавлены комментарии.
create or replace function vx_admin_backup(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'exported_at', now(),
    'events', coalesce((select jsonb_agg(to_jsonb(e) - 'reminded' order by e.day, e.at_time) from vx_events e), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i) - 'reminded' order by i.created_at) from vx_items i), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from vx_comments c), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(to_jsonb(s) order by s.day, s.pair) from vx_schedule s), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(to_jsonb(f) order by f.day, f.created_at) from vx_files f), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from vx_settings), '{}'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select * from vx_log order by id desc limit 500) l), '[]'::jsonb),
    'logins', coalesce((select jsonb_agg(to_jsonb(g) order by g.id desc) from (select * from vx_logins order by id desc limit 200) g), '[]'::jsonb)
  );
end $$;

-- ---------- Права ----------
revoke all on function vx_item_add(text, text, text, text, text, date, text, text, date), vx_task_update(text, uuid, text, text, text, date, boolean, text),
  vx_comment_add(text, uuid, text), vx_comment_del(text, uuid), vx_event_add(text, text, date, text, text, uuid), vx_event_edit(text, uuid, text, date, text, text),
  vx_load(text), vx_admin_set(text, text, boolean), vx_admin_backup(text) from public;
grant execute on function vx_item_add(text, text, text, text, text, date, text, text, date), vx_task_update(text, uuid, text, text, text, date, boolean, text),
  vx_comment_add(text, uuid, text), vx_comment_del(text, uuid), vx_event_add(text, text, date, text, text, uuid), vx_event_edit(text, uuid, text, date, text, text),
  vx_load(text), vx_admin_set(text, text, boolean), vx_admin_backup(text) to anon;

notify pgrst, 'reload schema';

-- ======== migration-7.sql ========
-- Миграция 7: Telegram подключается по ссылке.
-- Максим (или сам человек в кабинете) создаёт одноразовую ссылку вида t.me/<бот>?start=<код>. Человек нажимает её и жмёт «Запустить» в Telegram,
-- база сама находит это сообщение (опрос getUpdates через pg_net, пока есть неиспользованные ссылки) и записывает его chat_id в vx_notify.
-- Токен бота по-прежнему только в Vault. Код ссылки в базе хранится хэшем, ссылка действует 48 часов и срабатывает один раз.
-- Идемпотентна: повторный запуск безопасен.

create table if not exists vx_invites (
  token_hash text primary key,
  name text not null check (name in ('ulya', 'maxim')),
  created_by text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '48 hours',
  used_at timestamptz
);
alter table vx_invites enable row level security;
revoke all on vx_invites from anon, authenticated;

-- Новая ссылка. Максим может создать для любого, остальные только для себя. Старые неиспользованные ссылки этого человека гасятся.
create or replace function vx_invite_create(p_code text, p_name text default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare w text := vx_who(p_code); n text; tok text;
begin
  if w is null then return null; end if;
  n := coalesce(p_name, w);
  if n not in ('ulya', 'maxim') or (n <> w and w <> 'maxim') then return null; end if;
  tok := replace(gen_random_uuid()::text, '-', '');
  delete from vx_invites where name = n and used_at is null;
  delete from vx_invites where created_at < now() - interval '30 days';
  insert into vx_invites(token_hash, name, created_by, expires_at)
  values (encode(sha256(convert_to('vexxo-i:' || tok, 'utf8')), 'hex'), n, w, now() + interval '48 hours');
  insert into vx_log(who, action, detail) values (w, 'tg_invite', case when n = w then 'создал(а) ссылку для подключения Telegram' else 'создал ссылку для подключения Telegram: ' || (case n when 'ulya' then 'Уля' else 'Максим' end) end);
  return tok;
end $$;

-- Опрос Telegram: сначала разбираем ответ прошлого запроса, потом (если есть ждущие ссылки) отправляем новый.
create or replace function vx_tg_poll() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; prev bigint; r record; upd jsonb; msg jsonb; txt text; inv vx_invites; cid bigint; maxid bigint; off bigint; rid bigint; n int := 0;
        body jsonb; fired boolean := true; pat timestamptz; nm text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  if tok is null then return 0; end if;
  select value::bigint into prev from vx_settings where key = 'tg_poll_req';
  if prev is not null then
    select status_code, content into r from net._http_response where id = prev;
    if found then
      delete from vx_settings where key in ('tg_poll_req', 'tg_poll_at');
      if r.status_code = 200 then
        delete from vx_settings where key = 'tg_poll_err';
        begin body := r.content::jsonb; exception when others then body := null; end;
        for upd in select * from jsonb_array_elements(coalesce(body -> 'result', '[]'::jsonb)) loop
          maxid := greatest(coalesce(maxid, 0), (upd ->> 'update_id')::bigint);
          msg := upd -> 'message'; txt := msg ->> 'text';
          if txt like '/start%' and msg -> 'chat' ->> 'type' = 'private' then
            cid := (msg -> 'chat' ->> 'id')::bigint;
            inv := null;
            if txt ~ '^/start [A-Za-z0-9_-]{16,64}$' then
              select * into inv from vx_invites
               where token_hash = encode(sha256(convert_to('vexxo-i:' || substr(txt, 8), 'utf8')), 'hex') and used_at is null and expires_at > now() for update;
            end if;
            if inv.token_hash is not null then
              insert into vx_notify(name, chat_id) values (inv.name, cid) on conflict (name) do update set chat_id = excluded.chat_id;
              update vx_invites set used_at = now() where token_hash = inv.token_hash;
              nm := case inv.name when 'ulya' then 'Уля' else 'Максим' end;
              insert into vx_log(who, action, detail) values (inv.name, 'tg_link', 'Telegram подключён');
              perform vx_tg(inv.name, 'Готово, ' || nm || '! Теперь я буду присылать сюда напоминания и новости с сайта VEXXO.', 'misc');
              if inv.name <> 'maxim' then perform vx_tg('maxim', nm || ' подключила Telegram.', 'misc'); end if;
              n := n + 1;
            else
              perform net.http_post(url := 'https://api.telegram.org/bot' || tok || '/sendMessage', headers := '{"Content-Type": "application/json"}'::jsonb,
                body := jsonb_build_object('chat_id', cid, 'text', 'Чтобы подключить уведомления, открой ссылку подключения из сайта VEXXO. Она одноразовая: если не сработала, попроси новую.'));
            end if;
          end if;
        end loop;
        if maxid is not null then
          insert into vx_settings(key, value) values ('tg_offset', (maxid + 1)::text) on conflict (key) do update set value = excluded.value;
        end if;
      else
        insert into vx_settings(key, value) values ('tg_poll_err', coalesce(r.status_code::text, 'нет ответа')) on conflict (key) do update set value = excluded.value;
      end if;
    else
      -- ответа ещё нет: ждём, но не дольше двух минут
      select value::timestamptz into pat from vx_settings where key = 'tg_poll_at';
      if pat is not null and pat > now() - interval '2 minutes' then fired := false;
      else delete from vx_settings where key in ('tg_poll_req', 'tg_poll_at'); end if;
    end if;
  end if;
  if fired and exists (select 1 from vx_invites where used_at is null and expires_at > now()) then
    select coalesce((select value::bigint from vx_settings where key = 'tg_offset'), 0) into off;
    select net.http_get(url := 'https://api.telegram.org/bot' || tok || '/getUpdates?timeout=0&allowed_updates=%5B%22message%22%5D' || case when off > 0 then '&offset=' || off else '' end) into rid;
    insert into vx_settings(key, value) values ('tg_poll_req', rid::text) on conflict (key) do update set value = excluded.value;
    insert into vx_settings(key, value) values ('tg_poll_at', now()::text) on conflict (key) do update set value = excluded.value;
  end if;
  return n;
exception when others then
  return 0;
end $$;

-- Для сайта: запустить опрос прямо сейчас (пока открыто окно подключения).
create or replace function vx_tg_poll_now(p_code text) returns int
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is null then return null; end if;
  return vx_tg_poll();
end $$;

-- Состояние подключения: подключён ли Telegram и ждёт ли ссылка.
create or replace function vx_invite_status(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is null then return null; end if;
  return jsonb_build_object(
    'linked', jsonb_build_object('ulya', exists (select 1 from vx_notify where name = 'ulya'), 'maxim', exists (select 1 from vx_notify where name = 'maxim')),
    'pending', jsonb_build_object('ulya', exists (select 1 from vx_invites where name = 'ulya' and used_at is null and expires_at > now()),
                                  'maxim', exists (select 1 from vx_invites where name = 'maxim' and used_at is null and expires_at > now())),
    'error', (select value from vx_settings where key = 'tg_poll_err'));
end $$;

-- Отключить Telegram: Максим любому, остальные себе.
create or replace function vx_tg_unlink(p_code text, p_name text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); n text;
begin
  if w is null then return null; end if;
  n := coalesce(p_name, w);
  if n not in ('ulya', 'maxim') or (n <> w and w <> 'maxim') then return false; end if;
  delete from vx_notify where name = n;
  delete from vx_invites where name = n and used_at is null;
  insert into vx_log(who, action, detail) values (w, 'tg_unlink', case when n = w then 'отключил(а) Telegram' else 'отключил Telegram: ' || (case n when 'ulya' then 'Уля' else 'Максим' end) end);
  return true;
end $$;

revoke all on function vx_invite_create(text, text), vx_tg_poll(), vx_tg_poll_now(text), vx_invite_status(text), vx_tg_unlink(text, text) from public, anon, authenticated;
grant execute on function vx_invite_create(text, text), vx_tg_poll_now(text), vx_invite_status(text), vx_tg_unlink(text, text) to anon;

do $$ begin
  perform cron.schedule('vexxo-tgpoll', '* * * * *', 'select vx_tg_poll()');
exception when others then raise notice 'cron schedule: %', sqlerrm;
end $$;

notify pgrst, 'reload schema';

-- ======== migration-8.sql ========
-- Миграция 8: любое число участников и регистрация через Telegram-бота.
-- Максим создаёт ссылку-приглашение (или включает открытую регистрацию). Человек жмёт «Запустить», бот спрашивает имя, обращение и пароль,
-- создаёт аккаунт, подключает уведомления и присылает ссылку на сайт, по которой он сразу входит. В кабинете появляется его профиль,
-- на сайте появляется новый участник (страница, задачи, ответы на планы, уведомления, утренняя сводка).
-- Бот получает сообщения через webhook (его вызывает Telegram), подпись проверяется секретом из Vault.
-- Запускать после migration-7.sql. Идемпотентна. После неё один раз выполнить:  select vx_tg_setup_webhook();

-- ---------- Участники ----------
alter table vx_users add column if not exists title text;
alter table vx_users add column if not exists fem boolean not null default false;
alter table vx_users add column if not exists disabled boolean not null default false;
alter table vx_users add column if not exists ord int;
alter table vx_users add column if not exists joined_at timestamptz not null default now();
update vx_users set title = 'Уля', fem = true, ord = 1 where name = 'ulya' and title is null;
update vx_users set title = 'Максим', fem = false, ord = 2 where name = 'maxim' and title is null;
update vx_users set title = initcap(name) where title is null;
update vx_users u set ord = 100 + x.rn::int
  from (select name, row_number() over (order by joined_at, name) as rn from vx_users where ord is null) x
 where u.name = x.name;
alter table vx_users alter column title set not null;
alter table vx_users alter column ord set not null;
create unique index if not exists vx_users_code_uq on vx_users(code_hash);

-- Снимаем «только Уля и Максим» со всех таблиц.
do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass as t, c.conname
      from pg_constraint c
     where c.contype = 'c'
       and c.conrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace
                           and relname in ('vx_users', 'vx_events', 'vx_items', 'vx_sessions', 'vx_schedule', 'vx_notify', 'vx_comments', 'vx_invites'))
       and pg_get_constraintdef(c.oid) like '%''ulya''%'
  loop
    execute format('alter table %s drop constraint %I', r.t, r.conname);
  end loop;
end $$;
alter table vx_users drop constraint if exists vx_users_name_fmt;
alter table vx_users add constraint vx_users_name_fmt check (name ~ '^[a-z0-9_]{2,24}$');

-- Приглашения: ссылка для подключения Telegram уже существующему участнику ('link') или для нового участника ('member').
alter table vx_invites alter column name drop not null;
alter table vx_invites add column if not exists kind text not null default 'link';
alter table vx_invites add column if not exists note text;
alter table vx_invites drop constraint if exists vx_invites_kind_check;
alter table vx_invites add constraint vx_invites_kind_check check (kind in ('link', 'member'));

-- Диалог регистрации в боте: на каком шаге человек.
create table if not exists vx_reg (
  chat_id bigint primary key,
  step text not null check (step in ('name', 'gender', 'code')),
  name text,
  fem boolean,
  invite_hash text,
  tries int not null default 0,
  updated_at timestamptz not null default now()
);
alter table vx_reg enable row level security;
revoke all on vx_reg from anon, authenticated;

-- Одноразовые билеты входа: ссылка на сайт с #k=<билет> сразу открывает аккаунт.
create table if not exists vx_tickets (
  token_hash text primary key,
  name text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
alter table vx_tickets enable row level security;
revoke all on vx_tickets from anon, authenticated;

insert into vx_settings(key, value) values ('site_url', 'https://max657445.github.io/VEXXO/') on conflict (key) do nothing;

-- Ручная установка кода (см. README): при создании строки задаёт имя на сайте по умолчанию.
create or replace function vx_set_code(p_name text, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_code !~ '^[0-9]{4,12}$' then raise exception 'code must be 4-12 digits'; end if;
  insert into vx_users(name, code_hash, title, fem, ord)
  values (p_name, encode(sha256(convert_to('vexxo:' || p_code, 'utf8')), 'hex'),
          case p_name when 'ulya' then 'Уля' when 'maxim' then 'Максим' else initcap(p_name) end, p_name = 'ulya', (select coalesce(max(ord), 0) + 1 from vx_users))
  on conflict (name) do update set code_hash = excluded.code_hash;
end $$;
revoke all on function vx_set_code(text, text) from public, anon, authenticated;

-- ---------- Служебные функции ----------
create or replace function vx_title(p_name text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select title from vx_users where name = p_name), initcap(coalesce(p_name, '')))
$$;

-- Слово в нужном роде: vx_g('ulya', 'добавил', 'добавила').
create or replace function vx_g(p_name text, p_m text, p_f text) returns text
language sql stable security definer set search_path = public as $$
  select case when coalesce((select fem from vx_users where name = p_name), false) then p_f else p_m end
$$;

-- Имя в родительном падеже («для Ули», «для Максима», «для Ивана»). Для необычных имён возможны неточности.
create or replace function vx_gen(p_name text) returns text
language plpgsql stable security definer set search_path = public as $$
declare t text := vx_title(p_name); l text := right(t, 1);
begin
  if p_name = 'ulya' then return 'Ули'; end if;
  if p_name = 'maxim' then return 'Максима'; end if;
  if right(t, 2) = 'ья' then return left(t, -2) || 'ьи'; end if;
  if l = 'а' then return left(t, -1) || case when right(left(t, -1), 1) in ('г', 'к', 'х', 'ж', 'ш', 'щ', 'ч') then 'и' else 'ы' end; end if;
  if l = 'я' then return left(t, -1) || 'и'; end if;
  if l in ('й', 'ь') then return left(t, -1) || 'я'; end if;
  if l ~ '[бвгджзклмнпрстфхцчшщ]' then return t || 'а'; end if;
  return t;
end $$;

create or replace function vx_is_member(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_users where name = p_name and not disabled)
$$;

create or replace function vx_open_reg() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value from vx_settings where key = 'open_reg'), '0') = '1'
$$;

create or replace function vx_site_url() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select value from vx_settings where key = 'site_url'), 'https://max657445.github.io/VEXXO/')
$$;

-- Всем участникам, кроме одного (или всем, если p_except пусто).
create or replace function vx_tg_all(p_except text, p_text text, p_kind text default 'misc') returns void
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  for k in select name from vx_users where not disabled and name is distinct from p_except order by ord loop
    perform vx_tg(k, p_text, p_kind);
  end loop;
end $$;

revoke all on function vx_title(text), vx_g(text, text, text), vx_gen(text), vx_is_member(text), vx_open_reg(), vx_site_url(),
  vx_tg_all(text, text, text) from public, anon, authenticated;

-- Кто это. Не пускает отключённых участников; закрытый сайт закрыт для всех, кроме Максима.
create or replace function vx_who(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if p_code is null then return null; end if;
  if p_code ~ '^[0-9a-f]{64}$' then
    select s.name into n from vx_sessions s join vx_users u on u.name = s.name and not u.disabled
     where s.token_hash = encode(sha256(convert_to('vexxo-s:' || p_code, 'utf8')), 'hex') and s.expires_at > now();
  elsif p_code ~ '^[0-9]{4,12}$' then
    if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then
      raise exception 'too_many_attempts';
    end if;
    select u.name into n from vx_users u
     where u.code_hash = encode(sha256(convert_to('vexxo:' || p_code, 'utf8')), 'hex') and not u.disabled;
    if n is null then
      insert into vx_attempts default values;
      delete from vx_attempts where at < now() - interval '1 day';
    end if;
  else
    return null;
  end if;
  if n is not null and n <> 'maxim' and vx_locked() then
    perform set_config('vexxo.who', '', true);
    raise exception 'site_locked';
  end if;
  perform set_config('vexxo.who', coalesce(n, ''), true);
  return n;
end $$;
revoke all on function vx_who(text) from public, anon, authenticated;

-- Смена своего кода: «чужой» код теперь у любого другого участника.
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

-- Вход по одноразовому билету из ссылки бота -> токен сессии на 30 дней.
create or replace function vx_ticket_use(p_ticket text, p_device text default '') returns text
language plpgsql security definer set search_path = public as $$
declare n text; tok text; dev text := left(btrim(coalesce(p_device, '')), 60);
begin
  if p_ticket is null or p_ticket !~ '^[0-9a-f]{32,64}$' then return null; end if;
  if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then
    raise exception 'too_many_attempts';
  end if;
  update vx_tickets set used_at = now()
   where token_hash = encode(sha256(convert_to('vexxo-t:' || p_ticket, 'utf8')), 'hex') and used_at is null and expires_at > now()
  returning name into n;
  if n is null then
    insert into vx_attempts default values;
    return null;
  end if;
  if not vx_is_member(n) then return null; end if;
  if n <> 'maxim' and vx_locked() then raise exception 'site_locked'; end if;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into vx_sessions(token_hash, name, expires_at, device, last_seen)
  values (encode(sha256(convert_to('vexxo-s:' || tok, 'utf8')), 'hex'), n, now() + interval '30 days', dev, now());
  delete from vx_sessions where expires_at < now();
  delete from vx_tickets where expires_at < now() - interval '7 days';
  insert into vx_logins(name, kind, device) values (n, 'login', dev);
  return tok;
end $$;

-- Новый билет входа (внутренняя функция бота). Возвращает ссылку на сайт.
create or replace function vx_ticket_link(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  tok := left(tok, 48);
  insert into vx_tickets(token_hash, name, expires_at)
  values (encode(sha256(convert_to('vexxo-t:' || tok, 'utf8')), 'hex'), p_name, now() + interval '24 hours');
  return vx_site_url() || '#k=' || tok;
end $$;
revoke all on function vx_ticket_link(text) from public, anon, authenticated;

-- Профиль в кабинете: имя на сайте и обращение (для окончаний «добавил/добавила»).
create or replace function vx_me_profile(p_code text, p_title text default null, p_fem boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); t text;
begin
  if w is null then return null; end if;
  if p_title is not null then
    t := btrim(regexp_replace(p_title, '\s+', ' ', 'g'));
    if char_length(t) < 2 or char_length(t) > 20 or t !~ '^[A-Za-zА-Яа-яЁё0-9][A-Za-zА-Яа-яЁё0-9 .-]*$' then return jsonb_build_object('error', 'bad_name'); end if;
    if exists (select 1 from vx_users where name <> w and lower(title) = lower(t)) then return jsonb_build_object('error', 'taken'); end if;
    update vx_users set title = t where name = w;
  end if;
  if p_fem is not null then update vx_users set fem = p_fem where name = w; end if;
  insert into vx_log(who, action, detail) values (w, 'profile', 'изменил(а) профиль');
  return (select jsonb_build_object('name', name, 'title', title, 'fem', fem) from vx_users where name = w);
end $$;

-- ---------- Журнал действий ----------
create or replace function vx_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text := nullif(current_setting('vexxo.who', true), ''); a text; d text;
begin
  if w is null then return null; end if;
  if TG_TABLE_NAME = 'vx_events' then
    if TG_OP = 'INSERT' then a := 'event_add'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif TG_OP = 'DELETE' then a := 'event_del'; d := old.title;
    elsif new.title is distinct from old.title or new.day is distinct from old.day or new.at_time is distinct from old.at_time or new.category is distinct from old.category then
      a := 'event_edit'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif new.votes is distinct from old.votes then
      a := 'event_vote'; d := new.title || ': ' || coalesce(nullif(new.votes ->> w, ''), 'сброшен ответ');
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_items' then
    if TG_OP = 'INSERT' then a := new.kind || '_add'; d := 'для ' || vx_gen(new.owner) || ': ' || new.body
      || case when new.day is not null then ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')' else '' end;
    elsif TG_OP = 'DELETE' then a := old.kind || '_del'; d := old.body;
    elsif new.done is distinct from old.done then a := 'item_done'; d := new.body || case when new.done then ' (выполнено)' else ' (вернули в работу)' end;
    elsif new.status is distinct from old.status then
      a := 'item_status'; d := new.body || ' → ' || case new.status when 'todo' then 'К выполнению' when 'doing' then 'В работе' when 'review' then 'На проверке' else 'Готово' end;
    elsif new.owner is distinct from old.owner then
      a := 'item_owner'; d := new.body || ' → ' || vx_title(new.owner);
    elsif new.body is distinct from old.body or new.day is distinct from old.day or new.at_time is distinct from old.at_time
          or new.priority is distinct from old.priority or new.due is distinct from old.due then
      a := 'item_edit'; d := new.body;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_files' then
    if TG_OP = 'INSERT' then a := 'file_add'; d := new.title || ' / ' || new.filename;
    elsif TG_OP = 'DELETE' then a := 'file_del'; d := old.title || ' / ' || old.filename;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_schedule' then
    if TG_OP = 'INSERT' then a := 'sched_add'; d := vx_title(new.owner) || ': ' || to_char(new.day, 'DD.MM') || ' ' || new.pair || '-я ' || new.subject;
    elsif TG_OP = 'DELETE' then a := 'sched_del'; d := vx_title(old.owner) || ': ' || to_char(old.day, 'DD.MM') || ' ' || old.pair || '-я ' || old.subject;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_comments' then
    if TG_OP = 'INSERT' then a := 'comment_add'; d := coalesce((select body from vx_items where id = new.item_id), '') || ': ' || new.body;
    else return null; end if;
  else
    return null;
  end if;
  insert into vx_log(who, action, detail) values (w, a, left(d, 300));
  if random() < 0.02 then delete from vx_log where at < now() - interval '120 days'; end if;
  return null;
end $$;
revoke all on function vx_log_change() from public, anon, authenticated;

-- ---------- Уведомления: всем участникам, а не «второму из двух» ----------
create or replace function vx_notify_item() returns trigger
language plpgsql security definer set search_path = public as $$
declare what text;
begin
  if new.by_user is null or new.by_user = new.owner then return new; end if;
  what := case when new.kind = 'plan'
    then 'план: ' || new.body || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')'
    else 'задачу: ' || new.body end;
  perform vx_tg(new.owner, vx_title(new.by_user) || vx_g(new.by_user, ' добавил', ' добавила') || ' тебе ' || what, 'items');
  return new;
end $$;

create or replace function vx_notify_event() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform vx_tg_all(new.by_user, vx_title(new.by_user) || vx_g(new.by_user, ' предложил', ' предложила') || ' общий план: ' || new.title
    || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || '). Ответь на сайте: согласен или отказаться.', 'events');
  return new;
end $$;

create or replace function vx_notify_vote() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; v text;
begin
  for k in select name from vx_users where not disabled loop
    v := new.votes ->> k;
    if k <> new.by_user and v in ('yes', 'no') and v is distinct from (old.votes ->> k) then
      perform vx_tg(new.by_user, vx_title(k) || (case v when 'yes' then vx_g(k, ' согласился', ' согласилась') else vx_g(k, ' отказался', ' отказалась') end)
        || ': ' || new.title || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')', 'votes');
    end if;
  end loop;
  return new;
end $$;

-- ---------- Функции для сайта ----------
create or replace function vx_item_add(p_code text, p_kind text, p_body text, p_when text default '', p_owner text default null,
                                       p_day date default null, p_time text default null, p_priority text default 'mid', p_due date default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); o text;
begin
  if w is null then return; end if;
  o := coalesce(p_owner, w);
  if not vx_is_member(o) then return; end if;
  if p_kind = 'plan' and (p_day is null or p_time is null) then return; end if;
  insert into vx_items(kind, owner, body, when_text, by_user, day, at_time, priority, due)
  values (p_kind, o, btrim(p_body), btrim(coalesce(p_when, '')), w,
          case when p_kind = 'plan' then p_day end, case when p_kind = 'plan' then p_time end,
          case when p_priority in ('low', 'mid', 'high') then p_priority else 'mid' end,
          case when p_kind = 'task' then p_due end);
end $$;

create or replace function vx_task_update(p_code text, p_id uuid, p_body text default null, p_status text default null, p_priority text default null,
                                          p_due date default null, p_clear_due boolean default false, p_owner text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items;
begin
  if w is null then return; end if;
  select * into it from vx_items where id = p_id and (owner = w or by_user = w or w = 'maxim');
  if it.id is null then return; end if;
  if p_status is not null and p_status not in ('todo', 'doing', 'review', 'done') then return; end if;
  if p_priority is not null and p_priority not in ('low', 'mid', 'high') then return; end if;
  if p_owner is not null and not vx_is_member(p_owner) then return; end if;
  if p_body is not null and btrim(p_body) = '' then return; end if;
  update vx_items set body = coalesce(btrim(p_body), body), status = coalesce(p_status, status), priority = coalesce(p_priority, priority),
         due = case when it.kind <> 'task' then null when p_clear_due then null else coalesce(p_due, due) end,
         owner = coalesce(p_owner, owner)
   where id = p_id;
  if p_owner is not null and p_owner <> it.owner then
    perform vx_tg(p_owner, vx_title(w) || vx_g(w, ' передал', ' передала') || ' тебе задачу: ' || coalesce(nullif(btrim(p_body), ''), it.body), 'items');
  end if;
end $$;

create or replace function vx_comment_add(p_code text, p_item uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items; k text;
begin
  if w is null or btrim(coalesce(p_body, '')) = '' then return; end if;
  select * into it from vx_items where id = p_item;
  if it.id is null then return; end if;
  insert into vx_comments(item_id, by_user, body) values (p_item, w, left(btrim(p_body), 500));
  for k in select distinct x from unnest(array[it.owner, coalesce(it.by_user, it.owner)]) x loop
    if k <> w and vx_is_member(k) then
      perform vx_tg(k, vx_title(w) || vx_g(w, ' прокомментировал', ' прокомментировала') || ' «' || left(it.body, 60) || '»: ' || left(btrim(p_body), 200), 'comments');
    end if;
  end loop;
end $$;

create or replace function vx_event_edit(p_code text, p_id uuid, p_title text, p_day date, p_time text, p_cat text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); ev vx_events;
begin
  if w is null then return; end if;
  update vx_events set title = btrim(p_title), day = p_day, at_time = p_time, votes = jsonb_build_object(w, 'yes'),
         category = case when p_cat in ('work', 'study', 'personal', 'other') then p_cat else category end
   where id = p_id and (by_user = w or w = 'maxim') returning * into ev;
  if ev.id is null then return; end if;
  perform vx_tg_all(w, vx_title(w) || vx_g(w, ' изменил', ' изменила') || ' общий план: ' || ev.title
    || ' (' || to_char(ev.day, 'DD.MM') || ' в ' || ev.at_time || '). Ответь на сайте ещё раз.', 'edits');
end $$;

create or replace function vx_remind() returns void
language plpgsql security definer set search_path = public as $$
declare r record; nowm timestamp := (now() at time zone 'Europe/Moscow'); k text;
begin
  for r in select * from vx_events where not reminded and (day + at_time::time) > nowm and (day + at_time::time) <= nowm + interval '1 hour' loop
    for k in select name from vx_users where not disabled order by ord loop
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

create or replace function vx_digest(p_only text default null) returns void
language plpgsql security definer set search_path = public as $$
declare k text; today date := (now() at time zone 'Europe/Moscow')::date; msg text; part text; due_part text; n int; tg_kind text;
  dn text[] := array['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];
  pt text[] := array['08:30', '10:15', '12:30', '14:15', '16:00', '18:00'];
begin
  tg_kind := case when p_only is null then 'digest' else 'misc' end;
  for k in select name from vx_users where not disabled order by ord loop
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
    select string_agg('• ' || i.body || case when i.due < today then ' (просрочено, ' || to_char(i.due, 'DD.MM') || ')' else '' end, E'\n' order by i.due, i.created_at)
      into due_part from vx_items i where i.kind = 'task' and i.owner = k and not i.done and i.due is not null and i.due <= today;
    if due_part is not null then msg := msg || E'\n\nСрок сегодня и просрочено:\n' || due_part; end if;
    select count(*) into n from vx_items where kind = 'task' and owner = k and not done;
    if n > 0 then msg := msg || E'\n\nНевыполненных задач: ' || n; end if;
    if part is not null or due_part is not null or n > 0 or exists (select 1 from vx_schedule where owner = k and day = today) or p_only is not null then
      perform vx_tg(k, msg, tg_kind);
    end if;
  end loop;
end $$;
revoke all on function vx_digest(text) from public, anon, authenticated;

create or replace function vx_tg_flags() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('all', vx_flag('tg_all'), 'items', vx_flag('tg_items'), 'events', vx_flag('tg_events'), 'votes', vx_flag('tg_votes'),
                            'edits', vx_flag('tg_edits'), 'comments', vx_flag('tg_comments'), 'remind', vx_flag('tg_remind'), 'digest', vx_flag('tg_digest'),
                            'open_reg', vx_open_reg(),
                            'mute', coalesce((select jsonb_object_agg(name, vx_muted(name)) from vx_users), '{}'::jsonb),
                            'mute_ulya', vx_muted('ulya'), 'mute_maxim', vx_muted('maxim'))
$$;
revoke all on function vx_tg_flags() from public, anon, authenticated;

-- Загрузка данных: добавлен список участников.
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
    'users', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'title', title, 'fem', fem, 'off', disabled) order by ord, joined_at) from vx_users), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'date', day, 'time', at_time, 'by', by_user, 'votes', votes, 'cat', category, 'task', task_id) order by day, at_time, created_at) from vx_events), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'owner', owner, 'text', body, 'when', when_text, 'done', done, 'date', day, 'time', at_time, 'by', coalesce(by_user, owner),
                                                           'status', status, 'priority', priority, 'due', due, 'created', created_at) order by day nulls last, at_time nulls last, created_at) from vx_items), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'by', by_user, 'body', body, 'at', created_at) order by created_at)
                          from (select * from vx_comments order by created_at desc limit 400) c), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename) order by day, created_at) from vx_files), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'owner', owner, 'date', day, 'pair', pair, 'subject', subject, 'room', room) order by day, pair) from vx_schedule), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'who', who, 'action', action, 'detail', detail) order by id desc)
                        from (select * from vx_log where action not like 'admin%' and action not in ('tg_self', 'profile') order by id desc limit 12) r), '[]'::jsonb),
    'trash', case when w = 'maxim' then coalesce((select jsonb_agg(path) from vx_trash), '[]'::jsonb) else '[]'::jsonb end,
    'tg_muted', vx_muted(w)
  );
end $$;

-- ---------- Админ: участники ----------
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
      from vx_users u),
    'members', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'title', title, 'fem', fem, 'off', disabled, 'joined', joined_at) order by ord, joined_at) from vx_users), '[]'::jsonb),
    'reg', jsonb_build_object('open', vx_open_reg(),
      'pending', (select count(*) from vx_invites where kind = 'member' and used_at is null and expires_at > now()),
      'webhook', coalesce((select value from vx_settings where key = 'tg_webhook'), '0') = '1',
      'last', (select value from vx_settings where key = 'tg_wh_at'),
      'err', (select value from vx_settings where key = 'tg_wh_err')),
    'failed', jsonb_build_object('count_24h', (select count(*) from vx_attempts where at > now() - interval '1 day'), 'last', (select max(at) from vx_attempts)),
    'tg', jsonb_build_object('token', tokok,
      'chats', (select coalesce(jsonb_object_agg(name, true), '{}'::jsonb) from vx_notify),
      'ok', net_ok, 'fail', net_fail,
      'flags', vx_tg_flags()),
    'cron', cr
  );
end $$;

drop function if exists vx_admin_reset_code(text, text);
create or replace function vx_admin_reset_code(p_code text, p_new text, p_name text default 'ulya') returns text
language plpgsql security definer set search_path = public as $$
declare h text;
begin
  if not vx_is_admin(p_code) then return 'forbidden'; end if;
  if p_name = 'maxim' or not exists (select 1 from vx_users where name = p_name) then return 'bad_user'; end if;
  if p_new is null or p_new !~ '^[0-9]{6,12}$' then return 'bad_new'; end if;
  h := encode(sha256(convert_to('vexxo:' || p_new, 'utf8')), 'hex');
  if exists (select 1 from vx_users where name <> p_name and code_hash = h) then return 'taken'; end if;
  update vx_users set code_hash = h where name = p_name;
  delete from vx_sessions where name = p_name;
  insert into vx_logins(name, kind) values (p_name, 'code_reset');
  return 'ok';
end $$;

drop function if exists vx_admin_kick(text);
create or replace function vx_admin_kick(p_code text, p_name text default 'ulya') returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not vx_is_admin(p_code) then return null; end if;
  if p_name = 'maxim' or not exists (select 1 from vx_users where name = p_name) then return null; end if;
  with d as (delete from vx_sessions where name = p_name returning 1) select count(*) into n from d;
  insert into vx_logins(name, kind) values (p_name, 'kick');
  return n;
end $$;

create or replace function vx_admin_tg(p_code text, p_to text, p_text text) returns bigint
language plpgsql security definer set search_path = public as $$
declare rid bigint;
begin
  if not vx_is_admin(p_code) then return null; end if;
  if not vx_is_member(p_to) or btrim(coalesce(p_text, '')) = '' then return null; end if;
  rid := vx_tg(p_to, left(btrim(p_text), 1000), 'misc');
  insert into vx_log(who, action, detail) values ('maxim', 'admin_tg', left(p_to || ': ' || btrim(p_text), 300));
  return rid;
end $$;

create or replace function vx_admin_set(p_code text, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  if not (p_key in ('tg_all', 'tg_items', 'tg_events', 'tg_votes', 'tg_edits', 'tg_comments', 'tg_remind', 'tg_digest', 'open_reg')
          or (p_key like 'tg\_mute\_%' and exists (select 1 from vx_users where name = substr(p_key, 9)))) then
    return jsonb_build_object('error', 'bad_key');
  end if;
  -- для tg_mute_* значение p_on = true значит «отключить этому человеку»; для остальных true значит «включено»
  insert into vx_settings(key, value) values (p_key, case when p_on then '1' else '0' end)
  on conflict (key) do update set value = excluded.value;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_setting', p_key || ' = ' || case when p_on then 'вкл' else 'выкл' end);
  return vx_tg_flags();
end $$;

-- Ссылка-приглашение для нового участника (одноразовая, 7 дней). Возвращает код для t.me/<бот>?start=<код>.
create or replace function vx_admin_member_invite(p_code text, p_note text default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare tok text;
begin
  if not vx_is_admin(p_code) then return null; end if;
  if (select count(*) from vx_invites where kind = 'member' and used_at is null and expires_at > now()) >= 10 then return null; end if;
  tok := replace(gen_random_uuid()::text, '-', '');
  delete from vx_invites where created_at < now() - interval '30 days';
  insert into vx_invites(token_hash, name, kind, note, created_by, expires_at)
  values (encode(sha256(convert_to('vexxo-i:' || tok, 'utf8')), 'hex'), null, 'member', left(btrim(coalesce(p_note, '')), 40), 'maxim', now() + interval '7 days');
  insert into vx_log(who, action, detail) values ('maxim', 'admin_member_invite', 'создал приглашение для нового участника' || case when btrim(coalesce(p_note, '')) <> '' then ': ' || left(btrim(p_note), 40) else '' end);
  return tok;
end $$;

-- Отменить все неиспользованные приглашения новых участников.
create or replace function vx_admin_member_invites_clear(p_code text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not vx_is_admin(p_code) then return null; end if;
  with d as (delete from vx_invites where kind = 'member' and used_at is null returning 1) select count(*) into n from d;
  delete from vx_reg;
  return n;
end $$;

-- Отключить участника (он не сможет войти, сессии закрываются, данные остаются) или вернуть. Максима отключить нельзя.
create or replace function vx_admin_member_set(p_code text, p_name text, p_off boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return null; end if;
  if p_name = 'maxim' or not exists (select 1 from vx_users where name = p_name) then return null; end if;
  update vx_users set disabled = p_off where name = p_name;
  if p_off then delete from vx_sessions where name = p_name; end if;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_member', vx_title(p_name) || case when p_off then ': отключён' else ': возвращён' end);
  return p_off;
end $$;

create or replace function vx_admin_backup(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'exported_at', now(),
    'users', coalesce((select jsonb_agg(to_jsonb(u) - 'code_hash' order by u.ord) from vx_users u), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) - 'reminded' order by e.day, e.at_time) from vx_events e), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i) - 'reminded' order by i.created_at) from vx_items i), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from vx_comments c), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(to_jsonb(s) order by s.day, s.pair) from vx_schedule s), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(to_jsonb(f) order by f.day, f.created_at) from vx_files f), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from vx_settings where key not like 'tg\_%' or key like 'tg\_mute\_%' or key in ('tg_all', 'tg_items', 'tg_events', 'tg_votes', 'tg_edits', 'tg_comments', 'tg_remind', 'tg_digest')), '{}'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select * from vx_log order by id desc limit 500) l), '[]'::jsonb),
    'logins', coalesce((select jsonb_agg(to_jsonb(g) order by g.id desc) from (select * from vx_logins order by id desc limit 200) g), '[]'::jsonb)
  );
end $$;

-- ---------- Подключение Telegram существующему участнику ----------
create or replace function vx_invite_create(p_code text, p_name text default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare w text := vx_who(p_code); n text; tok text;
begin
  if w is null then return null; end if;
  n := coalesce(p_name, w);
  if not vx_is_member(n) or (n <> w and w <> 'maxim') then return null; end if;
  tok := replace(gen_random_uuid()::text, '-', '');
  delete from vx_invites where name = n and kind = 'link' and used_at is null;
  delete from vx_invites where created_at < now() - interval '30 days';
  insert into vx_invites(token_hash, name, kind, created_by, expires_at)
  values (encode(sha256(convert_to('vexxo-i:' || tok, 'utf8')), 'hex'), n, 'link', w, now() + interval '48 hours');
  insert into vx_log(who, action, detail) values (w, 'tg_invite', case when n = w then 'создал(а) ссылку для подключения Telegram' else 'создал ссылку для подключения Telegram: ' || vx_title(n) end);
  return tok;
end $$;

create or replace function vx_invite_status(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if vx_who(p_code) is null then return null; end if;
  return jsonb_build_object(
    'linked', coalesce((select jsonb_object_agg(u.name, exists (select 1 from vx_notify n where n.name = u.name)) from vx_users u where not u.disabled), '{}'::jsonb),
    'pending', coalesce((select jsonb_object_agg(u.name, exists (select 1 from vx_invites i where i.name = u.name and i.kind = 'link' and i.used_at is null and i.expires_at > now()))
                           from vx_users u where not u.disabled), '{}'::jsonb),
    'error', (select value from vx_settings where key = 'tg_poll_err'));
end $$;

create or replace function vx_tg_unlink(p_code text, p_name text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); n text;
begin
  if w is null then return null; end if;
  n := coalesce(p_name, w);
  if not exists (select 1 from vx_users where name = n) or (n <> w and w <> 'maxim') then return false; end if;
  delete from vx_notify where name = n;
  delete from vx_invites where name = n and used_at is null;
  insert into vx_log(who, action, detail) values (w, 'tg_unlink', case when n = w then 'отключил(а) Telegram' else 'отключил Telegram: ' || vx_title(n) end);
  return true;
end $$;

-- ---------- Бот ----------
-- Отправка сообщения в чат по номеру чата (человек может быть ещё не участником). Возвращает номер запроса.
create or replace function vx_tg_raw(p_chat bigint, p_text text, p_markup jsonb default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; rid bigint;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  if tok is null or p_chat is null then return null; end if;
  select net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', p_chat, 'text', p_text, 'disable_web_page_preview', true)
            || case when p_markup is not null then jsonb_build_object('reply_markup', p_markup) else '{}'::jsonb end
  ) into rid;
  return rid;
exception when others then
  return null;
end $$;

create or replace function vx_tg_delete(p_chat bigint, p_msg bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare tok text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  if tok is null or p_chat is null or p_msg is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/deleteMessage',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', p_chat, 'message_id', p_msg));
exception when others then
  return;
end $$;

revoke all on function vx_tg_raw(bigint, text, jsonb), vx_tg_delete(bigint, bigint) from public, anon, authenticated;

-- Разбор одного входящего сообщения: /start с ссылкой, диалог регистрации, /site.
create or replace function vx_tg_handle(msg jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  cid bigint; mid bigint; txt text; low text; param text; mem text; reg vx_reg; inv vx_invites; nm text; isf boolean; h text; slug text; link text;
  ih text; fresh jsonb := '{"remove_keyboard": true}'::jsonb;
begin
  if msg is null or (msg -> 'chat' ->> 'type') is distinct from 'private' then return; end if;
  cid := (msg -> 'chat' ->> 'id')::bigint;
  mid := (msg ->> 'message_id')::bigint;
  txt := btrim(coalesce(msg ->> 'text', ''));
  low := lower(txt);
  delete from vx_reg where updated_at < now() - interval '1 day';
  select n.name into mem from vx_notify n join vx_users u on u.name = n.name where n.chat_id = cid and not u.disabled limit 1;
  select * into reg from vx_reg where chat_id = cid;

  -- /start [код]
  if txt ~* '^/start(@[A-Za-z0-9_]+)?(\s|$)' then
    param := nullif(btrim(regexp_replace(txt, '^/start(@[A-Za-z0-9_]+)?', '', 'i')), '');
    delete from vx_reg where chat_id = cid;
    if param is not null and param ~ '^[A-Za-z0-9_-]{16,64}$' then
      ih := encode(sha256(convert_to('vexxo-i:' || param, 'utf8')), 'hex');
      select * into inv from vx_invites where token_hash = ih and used_at is null and expires_at > now() for update;
    end if;
    if inv.token_hash is not null and inv.kind = 'link' and vx_is_member(inv.name) then
      -- подключение уведомлений существующему участнику
      insert into vx_notify(name, chat_id) values (inv.name, cid) on conflict (name) do update set chat_id = excluded.chat_id;
      update vx_invites set used_at = now() where token_hash = inv.token_hash;
      insert into vx_log(who, action, detail) values (inv.name, 'tg_link', 'Telegram подключён');
      perform vx_tg_raw(cid, 'Готово, ' || vx_title(inv.name) || '! Теперь я буду присылать сюда напоминания и новости с сайта VEXXO. /site — ссылка для входа на сайт.');
      if inv.name <> 'maxim' then perform vx_tg('maxim', vx_title(inv.name) || vx_g(inv.name, ' подключил', ' подключила') || ' Telegram.', 'misc'); end if;
    elsif inv.token_hash is not null and inv.kind = 'member' then
      if mem is not null then
        perform vx_tg_raw(cid, 'Ты уже в VEXXO как ' || vx_title(mem) || ', уведомления подключены. /site — ссылка для входа на сайт.');
      else
        insert into vx_reg(chat_id, step, invite_hash) values (cid, 'name', inv.token_hash);
        perform vx_tg_raw(cid, 'Привет! Это бот сайта VEXXO. Давай создадим твой аккаунт, это займёт минуту.' || E'\n\n' || 'Как тебя зовут? Напиши имя, оно будет видно на сайте.', fresh);
      end if;
    elsif mem is not null then
      perform vx_tg_raw(cid, 'Привет, ' || vx_title(mem) || '! Ты уже в VEXXO, уведомления подключены. /site — ссылка для входа на сайт.');
    elsif param is null and vx_open_reg() then
      insert into vx_reg(chat_id, step) values (cid, 'name');
      perform vx_tg_raw(cid, 'Привет! Это бот сайта VEXXO. Давай создадим твой аккаунт, это займёт минуту.' || E'\n\n' || 'Как тебя зовут? Напиши имя, оно будет видно на сайте.', fresh);
    elsif param is null then
      perform vx_tg_raw(cid, 'Это закрытый сайт VEXXO. Чтобы присоединиться, попроси Максима прислать тебе ссылку-приглашение.');
    else
      perform vx_tg_raw(cid, 'Эта ссылка не подходит: она одноразовая или устарела. Попроси новую.');
    end if;
    return;
  end if;

  -- диалог регистрации
  if reg.chat_id is not null then
    if low in ('/cancel', '/отмена') then
      delete from vx_reg where chat_id = cid;
      perform vx_tg_raw(cid, 'Отменил. Нажми /start, чтобы начать заново.', fresh);
      return;
    end if;
    if reg.step = 'name' then
      nm := btrim(regexp_replace(txt, '\s+', ' ', 'g'));
      if char_length(nm) < 2 or char_length(nm) > 20 or nm !~ '^[A-Za-zА-Яа-яЁё0-9][A-Za-zА-Яа-яЁё0-9 .-]*$' then
        perform vx_tg_raw(cid, 'Напиши имя текстом: от 2 до 20 символов, буквы и цифры.');
        return;
      end if;
      nm := upper(left(nm, 1)) || substr(nm, 2);
      if exists (select 1 from vx_users where lower(title) = lower(nm)) then
        perform vx_tg_raw(cid, 'Участник с таким именем уже есть. Добавь фамилию или цифру, чтобы вас можно было различить.');
        return;
      end if;
      update vx_reg set name = nm, step = 'gender', updated_at = now() where chat_id = cid;
      perform vx_tg_raw(cid, 'Приятно познакомиться, ' || nm || '! Как к тебе обращаться на сайте? Это нужно только для окончаний («добавил» или «добавила»).',
        '{"keyboard": [[{"text": "Девушка"}, {"text": "Парень"}]], "resize_keyboard": true, "one_time_keyboard": true}'::jsonb);
      return;
    elsif reg.step = 'gender' then
      if low ~ '^(дев|жен|ж$|она|girl|f$)' then isf := true;
      elsif low ~ '^(пар|муж|м$|он$|boy|m$)' then isf := false;
      else
        perform vx_tg_raw(cid, 'Нажми одну из кнопок: «Девушка» или «Парень».');
        return;
      end if;
      update vx_reg set fem = isf, step = 'code', updated_at = now() where chat_id = cid;
      perform vx_tg_raw(cid, 'Теперь придумай пароль: от 6 до 12 цифр. Им ты будешь входить на сайт. Я сразу удалю твоё сообщение с паролем из чата. Не используй пароль от банка или других сервисов.', fresh);
      return;
    elsif reg.step = 'code' then
      perform vx_tg_delete(cid, mid);
      if txt !~ '^[0-9]{6,12}$' then
        update vx_reg set tries = tries + 1, updated_at = now() where chat_id = cid;
        if reg.tries >= 8 then
          delete from vx_reg where chat_id = cid;
          perform vx_tg_raw(cid, 'Слишком много неудачных попыток. Нажми /start, чтобы начать заново.');
        else
          perform vx_tg_raw(cid, 'Пароль — только цифры, от 6 до 12. Попробуй ещё раз.');
        end if;
        return;
      end if;
      if txt ~ '^(.)\1+$' or txt in ('123456', '1234567', '12345678', '123456789', '1234567890', '654321', '987654') then
        perform vx_tg_raw(cid, 'Слишком простой пароль. Придумай другой.');
        return;
      end if;
      if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then
        perform vx_tg_raw(cid, 'Слишком много попыток, попробуй через несколько минут.');
        return;
      end if;
      h := encode(sha256(convert_to('vexxo:' || txt, 'utf8')), 'hex');
      if exists (select 1 from vx_users where code_hash = h) then
        insert into vx_attempts default values;
        perform vx_tg_raw(cid, 'Такой пароль не подойдёт. Придумай другой.');
        return;
      end if;
      if (select count(*) from vx_users) >= 12 then
        delete from vx_reg where chat_id = cid;
        perform vx_tg_raw(cid, 'На сайте уже набралось максимальное число участников. Напиши Максиму.');
        return;
      end if;
      -- создаём участника
      loop
        slug := 'u' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
        exit when not exists (select 1 from vx_users where name = slug);
      end loop;
      insert into vx_users(name, code_hash, title, fem, ord)
      values (slug, h, reg.name, coalesce(reg.fem, false), (select coalesce(max(ord), 0) + 1 from vx_users));
      insert into vx_notify(name, chat_id) values (slug, cid) on conflict (name) do update set chat_id = excluded.chat_id;
      if reg.invite_hash is not null then
        update vx_invites set used_at = now() where token_hash = reg.invite_hash;
        delete from vx_reg where invite_hash = reg.invite_hash;
      end if;
      delete from vx_reg where chat_id = cid;
      link := vx_ticket_link(slug);
      insert into vx_log(who, action, detail) values (slug, 'member_join', 'новый участник: ' || reg.name);
      perform vx_tg_raw(cid, 'Готово, ' || reg.name || '! Аккаунт создан, уведомления подключены.' || E'\n\n' || 'Твоя ссылка на сайт (одноразовая, действует 24 часа):' || E'\n' || link
        || E'\n\n' || 'С другого устройства входи по паролю, который ты придумал. Я удалил его из чата. Если ссылка перестанет работать, напиши мне /site, и я пришлю новую.');
      perform vx_tg('maxim', reg.name || vx_g(slug, ' присоединился', ' присоединилась') || ' к VEXXO через бота.', 'misc');
      return;
    end if;
  end if;

  -- уже участник
  if mem is not null then
    if low ~ '^/(site|сайт|login|вход)(@[a-z0-9_]+)?$' then
      if mem <> 'maxim' and vx_locked() then
        perform vx_tg_raw(cid, 'Сайт сейчас закрыт Максимом. Попробуй позже.');
      else
        perform vx_tg_raw(cid, 'Ссылка для входа (одноразовая, действует 24 часа):' || E'\n' || vx_ticket_link(mem));
      end if;
    else
      perform vx_tg_raw(cid, 'Я присылаю напоминания и новости с сайта VEXXO. /site — ссылка для входа на сайт.');
    end if;
    return;
  end if;

  -- незнакомый человек
  if vx_open_reg() then
    perform vx_tg_raw(cid, 'Нажми /start, чтобы создать аккаунт на сайте VEXXO.');
  else
    perform vx_tg_raw(cid, 'Это закрытый сайт VEXXO. Чтобы присоединиться, попроси Максима прислать тебе ссылку-приглашение.');
  end if;
end $$;
revoke all on function vx_tg_handle(jsonb) from public, anon, authenticated;

-- Точка входа для Telegram (webhook). Telegram присылает JSON {update_id, message}; подпись проверяется секретом из Vault.
-- Всегда отвечает «успешно», чтобы Telegram не пересылал одно и то же сообщение снова и снова; ошибка запоминается в настройках.
create or replace function vx_tg_webhook(update_id bigint default null, message jsonb default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare hdr text; sec text; lastid bigint;
begin
  begin
    hdr := (current_setting('request.headers', true)::json) ->> 'x-telegram-bot-api-secret-token';
  exception when others then hdr := null;
  end;
  select decrypted_secret into sec from vault.decrypted_secrets where name = 'tg_webhook_secret' limit 1;
  if sec is null or hdr is null or hdr <> sec then return; end if;
  perform pg_advisory_xact_lock(7340001);
  select value::bigint into lastid from vx_settings where key = 'tg_last_update';
  if update_id is not null and lastid is not null and update_id <= lastid then return; end if;
  if update_id is not null then
    insert into vx_settings(key, value) values ('tg_last_update', update_id::text) on conflict (key) do update set value = excluded.value;
  end if;
  insert into vx_settings(key, value) values ('tg_wh_at', now()::text) on conflict (key) do update set value = excluded.value;
  begin
    perform vx_tg_handle(message);
    delete from vx_settings where key = 'tg_wh_err';
  exception when others then
    insert into vx_settings(key, value) values ('tg_wh_err', left(sqlerrm, 200)) on conflict (key) do update set value = excluded.value;
  end;
end $$;

-- Включить webhook: Telegram будет сам присылать сообщения боту. Старый опрос getUpdates отключается (одновременно они не работают).
create or replace function vx_tg_setup_webhook() returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; sec text; rid bigint;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  if tok is null then raise exception 'нет токена бота в Vault'; end if;
  select decrypted_secret into sec from vault.decrypted_secrets where name = 'tg_webhook_secret' limit 1;
  if sec is null then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'tg_webhook_secret', 'secret_token для webhook Telegram');
    select decrypted_secret into sec from vault.decrypted_secrets where name = 'tg_webhook_secret' limit 1;
  end if;
  select net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/setWebhook',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object(
      'url', 'https://cnkergfsrmvvvbsubqnv.supabase.co/rest/v1/rpc/vx_tg_webhook?apikey=sb_publishable_y_PN61X0Fnrupm3tuKU5sQ_uStCwgok',
      'secret_token', sec, 'allowed_updates', jsonb_build_array('message'), 'max_connections', 3)
  ) into rid;
  insert into vx_settings(key, value) values ('tg_webhook', '1') on conflict (key) do update set value = excluded.value;
  insert into vx_settings(key, value) values ('tg_webhook_req', rid::text) on conflict (key) do update set value = excluded.value;
  begin perform cron.unschedule('vexxo-tgpoll'); exception when others then null; end;
  return rid;
end $$;

-- Выключить webhook и вернуться к опросу (регистрация новых участников тогда не работает, подключение уведомлений по ссылке работает).
create or replace function vx_tg_unset_webhook() returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; rid bigint;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  if tok is null then raise exception 'нет токена бота в Vault'; end if;
  select net.http_post(url := 'https://api.telegram.org/bot' || tok || '/deleteWebhook', headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb) into rid;
  insert into vx_settings(key, value) values ('tg_webhook', '0') on conflict (key) do update set value = excluded.value;
  begin perform cron.schedule('vexxo-tgpoll', '* * * * *', 'select vx_tg_poll()'); exception when others then null; end;
  return rid;
end $$;

-- Опрос (запасной путь, пока webhook выключен): обрабатывает только ссылки подключения Telegram.
create or replace function vx_tg_poll() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; prev bigint; r record; upd jsonb; msg jsonb; txt text; inv vx_invites; cid bigint; maxid bigint; off bigint; rid bigint; n int := 0;
        body jsonb; fired boolean := true; pat timestamptz;
begin
  if coalesce((select value from vx_settings where key = 'tg_webhook'), '0') = '1' then return 0; end if;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'tg_token' limit 1;
  if tok is null then return 0; end if;
  select value::bigint into prev from vx_settings where key = 'tg_poll_req';
  if prev is not null then
    select status_code, content into r from net._http_response where id = prev;
    if found then
      delete from vx_settings where key in ('tg_poll_req', 'tg_poll_at');
      if r.status_code = 200 then
        delete from vx_settings where key = 'tg_poll_err';
        begin body := r.content::jsonb; exception when others then body := null; end;
        for upd in select * from jsonb_array_elements(coalesce(body -> 'result', '[]'::jsonb)) loop
          maxid := greatest(coalesce(maxid, 0), (upd ->> 'update_id')::bigint);
          msg := upd -> 'message'; txt := msg ->> 'text';
          if txt like '/start%' and msg -> 'chat' ->> 'type' = 'private' then
            cid := (msg -> 'chat' ->> 'id')::bigint;
            inv := null;
            if txt ~ '^/start [A-Za-z0-9_-]{16,64}$' then
              select * into inv from vx_invites
               where token_hash = encode(sha256(convert_to('vexxo-i:' || substr(txt, 8), 'utf8')), 'hex') and kind = 'link' and used_at is null and expires_at > now() for update;
            end if;
            if inv.token_hash is not null and vx_is_member(inv.name) then
              insert into vx_notify(name, chat_id) values (inv.name, cid) on conflict (name) do update set chat_id = excluded.chat_id;
              update vx_invites set used_at = now() where token_hash = inv.token_hash;
              insert into vx_log(who, action, detail) values (inv.name, 'tg_link', 'Telegram подключён');
              perform vx_tg(inv.name, 'Готово, ' || vx_title(inv.name) || '! Теперь я буду присылать сюда напоминания и новости с сайта VEXXO.', 'misc');
              if inv.name <> 'maxim' then perform vx_tg('maxim', vx_title(inv.name) || vx_g(inv.name, ' подключил', ' подключила') || ' Telegram.', 'misc'); end if;
              n := n + 1;
            else
              perform vx_tg_raw(cid, 'Чтобы подключить уведомления, открой ссылку подключения из сайта VEXXO. Она одноразовая: если не сработала, попроси новую.');
            end if;
          end if;
        end loop;
        if maxid is not null then
          insert into vx_settings(key, value) values ('tg_offset', (maxid + 1)::text) on conflict (key) do update set value = excluded.value;
        end if;
      else
        insert into vx_settings(key, value) values ('tg_poll_err', coalesce(r.status_code::text, 'нет ответа')) on conflict (key) do update set value = excluded.value;
      end if;
    else
      select value::timestamptz into pat from vx_settings where key = 'tg_poll_at';
      if pat is not null and pat > now() - interval '2 minutes' then fired := false;
      else delete from vx_settings where key in ('tg_poll_req', 'tg_poll_at'); end if;
    end if;
  end if;
  if fired and exists (select 1 from vx_invites where kind = 'link' and used_at is null and expires_at > now()) then
    select coalesce((select value::bigint from vx_settings where key = 'tg_offset'), 0) into off;
    select net.http_get(url := 'https://api.telegram.org/bot' || tok || '/getUpdates?timeout=0&allowed_updates=%5B%22message%22%5D' || case when off > 0 then '&offset=' || off else '' end) into rid;
    insert into vx_settings(key, value) values ('tg_poll_req', rid::text) on conflict (key) do update set value = excluded.value;
    insert into vx_settings(key, value) values ('tg_poll_at', now()::text) on conflict (key) do update set value = excluded.value;
  end if;
  return n;
exception when others then
  return 0;
end $$;

-- ---------- Права ----------
revoke all on function vx_ticket_use(text, text), vx_me_profile(text, text, boolean), vx_admin_member_invite(text, text), vx_admin_member_invites_clear(text),
  vx_admin_member_set(text, text, boolean), vx_admin_reset_code(text, text, text), vx_admin_kick(text, text), vx_tg_webhook(bigint, jsonb),
  vx_tg_setup_webhook(), vx_tg_unset_webhook(), vx_tg_poll() from public, anon, authenticated;
grant execute on function vx_ticket_use(text, text), vx_me_profile(text, text, boolean), vx_admin_member_invite(text, text), vx_admin_member_invites_clear(text),
  vx_admin_member_set(text, text, boolean), vx_admin_reset_code(text, text, text), vx_admin_kick(text, text), vx_tg_webhook(bigint, jsonb) to anon;
revoke all on function vx_item_add(text, text, text, text, text, date, text, text, date), vx_task_update(text, uuid, text, text, text, date, boolean, text),
  vx_comment_add(text, uuid, text), vx_event_edit(text, uuid, text, date, text, text), vx_load(text), vx_admin_overview(text), vx_admin_tg(text, text, text),
  vx_admin_set(text, text, boolean), vx_admin_backup(text), vx_invite_create(text, text), vx_invite_status(text), vx_tg_unlink(text, text), vx_change_code(text, text, text) from public;
grant execute on function vx_item_add(text, text, text, text, text, date, text, text, date), vx_task_update(text, uuid, text, text, text, date, boolean, text),
  vx_comment_add(text, uuid, text), vx_event_edit(text, uuid, text, date, text, text), vx_load(text), vx_admin_overview(text), vx_admin_tg(text, text, text),
  vx_admin_set(text, text, boolean), vx_admin_backup(text), vx_invite_create(text, text), vx_invite_status(text), vx_tg_unlink(text, text), vx_change_code(text, text, text) to anon;

notify pgrst, 'reload schema';

-- ======== migration-9.sql ========
-- Миграция 9: «Карта сайта» и «Путь участника».
-- Друзья (запрос, ответ, удаление, блокировка), доступ к записям (только мне / друзьям / всем), колокольчик, общие списки,
-- реакции, комментарии к событиям и чертежам, @упоминания, объявление на «Сегодня», приём задач исполнителем,
-- чек-лист, корзина задач на 7 дней, статус и срок сдачи чертежа, события с местом, длительностью и гостями,
-- расписание «никому / друзьям / всем», статус «на связи», правка события только автором и Максимом.
-- Запускать после migration-8.sql. Идемпотентна.

-- ---------- Профиль ----------
alter table vx_users add column if not exists sched_group text not null default '';
alter table vx_users drop constraint if exists vx_users_sched_group_len;
alter table vx_users add constraint vx_users_sched_group_len check (char_length(sched_group) <= 20);
alter table vx_users add column if not exists show_sched text not null default 'friends';
alter table vx_users drop constraint if exists vx_users_show_sched_chk;
alter table vx_users add constraint vx_users_show_sched_chk check (show_sched in ('none', 'friends', 'all'));
alter table vx_users add column if not exists show_online text not null default 'friends';
alter table vx_users drop constraint if exists vx_users_show_online_chk;
alter table vx_users add constraint vx_users_show_online_chk check (show_online in ('none', 'friends'));
alter table vx_users add column if not exists tour_done boolean not null default false;
alter table vx_users add column if not exists last_seen timestamptz;

-- ---------- Дружба ----------
-- Одна строка на пару. a: кто отправил запрос (или кто заблокировал). status: pending / friend / declined / blocked.
create table if not exists vx_friends (
  a text not null references vx_users(name) on delete cascade,
  b text not null references vx_users(name) on delete cascade,
  status text not null check (status in ('pending', 'friend', 'declined', 'blocked')),
  created_at timestamptz not null default now(),
  changed_at timestamptz not null default now(),
  primary key (a, b),
  check (a <> b)
);
create unique index if not exists vx_friends_pair on vx_friends (least(a, b), greatest(a, b));
alter table vx_friends enable row level security;
revoke all on vx_friends from anon, authenticated;

-- Те, кто уже был на сайте до этой миграции, остаются друзьями друг друга.
insert into vx_friends(a, b, status)
select x.name, y.name, 'friend' from vx_users x join vx_users y on x.name < y.name where not x.disabled and not y.disabled
on conflict do nothing;

create or replace function vx_are_friends(p_x text, p_y text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_x is not null and p_y is not null and exists (select 1 from vx_friends where status = 'friend' and least(a, b) = least(p_x, p_y) and greatest(a, b) = greatest(p_x, p_y))
$$;
create or replace function vx_friends_of(p_n text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(case when a = p_n then b else a end), '{}'::text[]) from vx_friends where status = 'friend' and p_n in (a, b)
$$;
create or replace function vx_blocked_pair(p_x text, p_y text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_friends where status = 'blocked' and least(a, b) = least(p_x, p_y) and greatest(a, b) = greatest(p_x, p_y))
$$;

-- ---------- Записи: доступ, приём, чек-лист, дата выполнения ----------
alter table vx_items add column if not exists access text not null default 'friends';
alter table vx_items drop constraint if exists vx_items_access_chk;
alter table vx_items add constraint vx_items_access_chk check (access in ('me', 'friends', 'all'));
alter table vx_items add column if not exists accept text not null default 'ok';
alter table vx_items drop constraint if exists vx_items_accept_chk;
alter table vx_items add constraint vx_items_accept_chk check (accept in ('new', 'ok', 'declined'));
alter table vx_items add column if not exists decline_reason text not null default '';
alter table vx_items add column if not exists checklist jsonb not null default '[]'::jsonb;
alter table vx_items add column if not exists done_at timestamptz;
update vx_items set done_at = created_at where done and done_at is null;

create or replace function vx_items_done_at() returns trigger
language plpgsql as $$
begin
  if new.done and (TG_OP = 'INSERT' or not old.done) then new.done_at := now();
  elsif not new.done then new.done_at := null; end if;
  return new;
end $$;
drop trigger if exists vx_items_z_done_at_t on vx_items;
create trigger vx_items_z_done_at_t before insert or update on vx_items for each row execute function vx_items_done_at();

-- ---------- События: место, длительность, гости, правило согласия ----------
alter table vx_events add column if not exists place text not null default '';
alter table vx_events drop constraint if exists vx_events_place_len;
alter table vx_events add constraint vx_events_place_len check (char_length(place) <= 100);
alter table vx_events add column if not exists dur int;
alter table vx_events drop constraint if exists vx_events_dur_chk;
alter table vx_events add constraint vx_events_dur_chk check (dur is null or dur between 5 and 1440);
alter table vx_events add column if not exists guests text[] not null default '{}';
alter table vx_events add column if not exists rule text not null default 'all';
alter table vx_events drop constraint if exists vx_events_rule_chk;
alter table vx_events add constraint vx_events_rule_chk check (rule in ('all', 'majority'));

-- ---------- Чертежи: статус и срок сдачи ----------
alter table vx_files add column if not exists status text not null default 'draft';
alter table vx_files drop constraint if exists vx_files_status_chk;
alter table vx_files add constraint vx_files_status_chk check (status in ('draft', 'review', 'done'));
alter table vx_files add column if not exists due date;

-- ---------- Комментарии: к задаче, событию или версии чертежа ----------
alter table vx_comments alter column item_id drop not null;
alter table vx_comments add column if not exists event_id uuid references vx_events(id) on delete cascade;
alter table vx_comments add column if not exists file_id uuid references vx_files(id) on delete cascade;
alter table vx_comments add column if not exists edited_at timestamptz;
alter table vx_comments drop constraint if exists vx_comments_one_target;
alter table vx_comments add constraint vx_comments_one_target check (num_nonnulls(item_id, event_id, file_id) = 1);
create index if not exists vx_comments_event on vx_comments(event_id);
create index if not exists vx_comments_file on vx_comments(file_id);

-- ---------- Реакции ----------
create table if not exists vx_reactions (
  kind text not null check (kind in ('item', 'event', 'file', 'comment')),
  target uuid not null,
  who text not null references vx_users(name) on delete cascade,
  react text not null check (react in ('ok', 'doing', 'no')),
  at timestamptz not null default now(),
  primary key (kind, target, who)
);
alter table vx_reactions enable row level security;
revoke all on vx_reactions from anon, authenticated;

-- ---------- Колокольчик ----------
create table if not exists vx_bell (
  id bigint generated always as identity primary key,
  to_name text not null references vx_users(name) on delete cascade,
  from_name text,
  kind text not null,
  body text not null,
  ref_kind text,
  ref_id uuid,
  read boolean not null default false,
  at timestamptz not null default now()
);
create index if not exists vx_bell_to on vx_bell(to_name, id desc);
alter table vx_bell enable row level security;
revoke all on vx_bell from anon, authenticated;

create or replace function vx_bell(p_to text, p_from text, p_kind text, p_body text, p_ref text default null, p_id uuid default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_to is null or p_to is not distinct from p_from or not vx_is_member(p_to) then return; end if;
  insert into vx_bell(to_name, from_name, kind, body, ref_kind, ref_id) values (p_to, p_from, p_kind, left(p_body, 300), p_ref, p_id);
  if random() < 0.02 then delete from vx_bell where at < now() - interval '60 days'; end if;
end $$;
revoke all on function vx_bell(text, text, text, text, text, uuid) from public, anon, authenticated;

-- ---------- Общие списки ----------
create table if not exists vx_lists (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 60),
  by_user text not null references vx_users(name) on delete cascade,
  members text[] not null default '{}',
  created_at timestamptz not null default now()
);
create table if not exists vx_list_items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references vx_lists(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 200),
  by_user text not null,
  done boolean not null default false,
  done_by text,
  created_at timestamptz not null default now()
);
create index if not exists vx_list_items_list on vx_list_items(list_id);
alter table vx_lists enable row level security;
alter table vx_list_items enable row level security;
revoke all on vx_lists, vx_list_items from anon, authenticated;

-- Корзина задач: 7 дней.
create table if not exists vx_item_trash (
  id uuid primary key,
  owner text not null,
  by_user text,
  snapshot jsonb not null,
  comments jsonb not null default '[]'::jsonb,
  deleted_at timestamptz not null default now()
);
alter table vx_item_trash enable row level security;
revoke all on vx_item_trash from anon, authenticated;

-- ---------- Видимость ----------
create or replace function vx_it_vis(p_who text, i vx_items) returns boolean
language sql stable security definer set search_path = public as $$
  select p_who = i.owner or p_who = coalesce(i.by_user, i.owner) or (i.access = 'all')
      or (i.access = 'friends' and (vx_are_friends(p_who, i.owner) or vx_are_friends(p_who, coalesce(i.by_user, i.owner))))
$$;
create or replace function vx_it_vis_id(p_who text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_items i where i.id = p_id and vx_it_vis(p_who, i))
$$;
create or replace function vx_ev_vis(p_who text, e vx_events) returns boolean
language sql stable security definer set search_path = public as $$
  select p_who = e.by_user or p_who = any(e.guests) or (cardinality(e.guests) = 0 and vx_are_friends(p_who, e.by_user))
$$;
create or replace function vx_ev_vis_id(p_who text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_events e where e.id = p_id and vx_ev_vis(p_who, e))
$$;
-- Кого касается событие (без автора).
create or replace function vx_ev_aud(e vx_events) returns text[]
language sql stable security definer set search_path = public as $$
  select case when cardinality(e.guests) > 0 then array_remove(e.guests, e.by_user) else array_remove(vx_friends_of(e.by_user), e.by_user) end
$$;
create or replace function vx_it_aud(i vx_items) returns text[]
language sql stable security definer set search_path = public as $$
  select case when i.access = 'all' then null
    else (select array_agg(distinct x) from unnest(array[i.owner, coalesce(i.by_user, i.owner)] || vx_friends_of(i.owner) || vx_friends_of(coalesce(i.by_user, i.owner))) x) end
$$;
revoke all on function vx_are_friends(text, text), vx_friends_of(text), vx_blocked_pair(text, text), vx_it_vis(text, vx_items), vx_it_vis_id(text, uuid),
  vx_ev_vis(text, vx_events), vx_ev_vis_id(text, uuid), vx_ev_aud(vx_events), vx_it_aud(vx_items) from public, anon, authenticated;

-- ---------- Журнал: кому виден пункт ----------
alter table vx_log add column if not exists aud text[];

create or replace function vx_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text := nullif(current_setting('vexxo.who', true), ''); a text; d text; au text[] := null; it vx_items; ev vx_events;
begin
  if w is null then return null; end if;
  if TG_TABLE_NAME = 'vx_events' then
    ev := case when TG_OP = 'DELETE' then old else new end;
    au := array_cat(vx_ev_aud(ev), array[ev.by_user]);
    if TG_OP = 'INSERT' then a := 'event_add'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif TG_OP = 'DELETE' then a := 'event_del'; d := old.title;
    elsif new.title is distinct from old.title or new.day is distinct from old.day or new.at_time is distinct from old.at_time or new.category is distinct from old.category then
      a := 'event_edit'; d := new.title || ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')';
    elsif new.votes is distinct from old.votes then
      a := 'event_vote'; d := new.title || ': ' || coalesce(nullif(new.votes ->> w, ''), 'сброшен ответ');
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_items' then
    it := case when TG_OP = 'DELETE' then old else new end;
    if it.access = 'me' then return null; end if;
    au := vx_it_aud(it);
    if TG_OP = 'INSERT' then a := new.kind || '_add'; d := 'для ' || vx_gen(new.owner) || ': ' || new.body
      || case when new.day is not null then ' (' || to_char(new.day, 'DD.MM') || ' ' || new.at_time || ')' else '' end;
    elsif TG_OP = 'DELETE' then a := old.kind || '_del'; d := old.body;
    elsif new.done is distinct from old.done then a := 'item_done'; d := new.body || case when new.done then ' (выполнено)' else ' (вернули в работу)' end;
    elsif new.status is distinct from old.status then
      a := 'item_status'; d := new.body || ' → ' || case new.status when 'todo' then 'К выполнению' when 'doing' then 'В работе' when 'review' then 'На проверке' else 'Готово' end;
    elsif new.owner is distinct from old.owner then
      a := 'item_owner'; d := new.body || ' → ' || vx_title(new.owner);
    elsif new.accept is distinct from old.accept then
      a := 'item_accept'; d := new.body || case when new.accept = 'ok' then ' (принята)' else ' (отклонена)' end;
    elsif new.body is distinct from old.body or new.day is distinct from old.day or new.at_time is distinct from old.at_time
          or new.priority is distinct from old.priority or new.due is distinct from old.due then
      a := 'item_edit'; d := new.body;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_files' then
    if TG_OP = 'INSERT' then a := 'file_add'; d := new.title || ' / ' || new.filename;
    elsif TG_OP = 'DELETE' then a := 'file_del'; d := old.title || ' / ' || old.filename;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_schedule' then
    au := array[new.owner] || vx_friends_of(new.owner);
    if TG_OP = 'INSERT' then a := 'sched_add'; d := vx_title(new.owner) || ': ' || to_char(new.day, 'DD.MM') || ' ' || new.pair || '-я ' || new.subject;
    elsif TG_OP = 'DELETE' then au := array[old.owner] || vx_friends_of(old.owner); a := 'sched_del'; d := vx_title(old.owner) || ': ' || to_char(old.day, 'DD.MM') || ' ' || old.pair || '-я ' || old.subject;
    else return null; end if;
  elsif TG_TABLE_NAME = 'vx_comments' then
    if TG_OP <> 'INSERT' then return null; end if;
    a := 'comment_add';
    if new.item_id is not null then
      select * into it from vx_items where id = new.item_id;
      if it.access = 'me' then return null; end if;
      au := vx_it_aud(it); d := coalesce(it.body, '') || ': ' || new.body;
    elsif new.event_id is not null then
      select * into ev from vx_events where id = new.event_id;
      au := array_cat(vx_ev_aud(ev), array[ev.by_user]); d := coalesce(ev.title, '') || ': ' || new.body;
    else
      d := coalesce((select title from vx_files where id = new.file_id), '') || ': ' || new.body;
    end if;
  else
    return null;
  end if;
  insert into vx_log(who, action, detail, aud) values (w, a, left(d, 300), au);
  if random() < 0.02 then delete from vx_log where at < now() - interval '120 days'; end if;
  return null;
end $$;
revoke all on function vx_log_change() from public, anon, authenticated;

-- ---------- Уведомления: только тем, кого касается ----------
create or replace function vx_notify_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  for k in select unnest(vx_ev_aud(new)) loop
    perform vx_tg(k, vx_title(new.by_user) || vx_g(new.by_user, ' позвал', ' позвала') || ' на событие: ' || new.title
      || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || '). Ответь на сайте.', 'events');
    perform vx_bell(k, new.by_user, 'event', vx_title(new.by_user) || vx_g(new.by_user, ' позвал', ' позвала') || ' на событие: ' || new.title
      || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')', 'event', new.id);
  end loop;
  return new;
end $$;
revoke all on function vx_notify_event() from public, anon, authenticated;

create or replace function vx_bell_item() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.by_user is null or new.by_user = new.owner then return new; end if;
  perform vx_bell(new.owner, new.by_user, new.kind, vx_title(new.by_user) || vx_g(new.by_user, ' поставил', ' поставила') || ' тебе '
    || case when new.kind = 'plan' then 'план: ' || new.body || ' (' || to_char(new.day, 'DD.MM') || ' в ' || new.at_time || ')' else 'задачу: ' || new.body end, 'item', new.id);
  return new;
end $$;
drop trigger if exists vx_items_bell on vx_items;
create trigger vx_items_bell after insert on vx_items for each row execute function vx_bell_item();

create or replace function vx_bell_item_upd() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text := nullif(current_setting('vexxo.who', true), '');
begin
  if new.owner is distinct from old.owner then
    perform vx_bell(new.owner, w, 'task', vx_title(w) || vx_g(w, ' передал', ' передала') || ' тебе задачу: ' || new.body, 'item', new.id);
  end if;
  if new.status is distinct from old.status and coalesce(new.by_user, new.owner) <> new.owner then
    if new.status = 'review' then
      perform vx_bell(new.by_user, new.owner, 'review', vx_title(new.owner) || vx_g(new.owner, ' отдал', ' отдала') || ' на проверку: ' || new.body, 'item', new.id);
    elsif new.status in ('doing', 'done') then
      perform vx_bell(new.by_user, new.owner, 'status', vx_title(new.owner) || ': «' || left(new.body, 60) || '» → ' || case new.status when 'doing' then 'в работе' else 'готово' end, 'item', new.id);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists vx_items_bell_upd on vx_items;
create trigger vx_items_bell_upd after update on vx_items for each row execute function vx_bell_item_upd();

create or replace function vx_bell_vote() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; v text;
begin
  for k in select name from vx_users where not disabled loop
    v := new.votes ->> k;
    if k <> new.by_user and v in ('yes', 'no') and v is distinct from (old.votes ->> k) then
      perform vx_bell(new.by_user, k, 'vote', vx_title(k) || (case v when 'yes' then vx_g(k, ' согласился', ' согласилась') else vx_g(k, ' отказался', ' отказалась') end) || ': ' || new.title, 'event', new.id);
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists vx_events_bell_vote on vx_events;
create trigger vx_events_bell_vote after update of votes on vx_events for each row execute function vx_bell_vote();

-- ---------- Функции: задачи ----------
drop function if exists vx_item_add(text, text, text, text, text, date, text, text, date);
create or replace function vx_item_add(p_code text, p_kind text, p_body text, p_when text default '', p_owner text default null,
                                       p_day date default null, p_time text default null, p_priority text default 'mid', p_due date default null,
                                       p_access text default 'friends') returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); o text; acc text;
begin
  if w is null then return; end if;
  o := coalesce(p_owner, w);
  if not vx_is_member(o) then return; end if;
  if o <> w and not vx_are_friends(w, o) then raise exception 'not_friend'; end if;
  if p_kind not in ('plan', 'task') or char_length(btrim(coalesce(p_body, ''))) not between 1 and 200 then return; end if;
  if p_kind = 'plan' and (p_day is null or p_time is null) then return; end if;
  acc := case when p_access in ('me', 'friends', 'all') then p_access else 'friends' end;
  if o <> w and acc = 'me' then acc := 'friends'; end if;
  insert into vx_items(kind, owner, body, when_text, by_user, day, at_time, priority, due, access, accept)
  values (p_kind, o, btrim(p_body), btrim(coalesce(p_when, '')), w,
          case when p_kind = 'plan' then p_day end, case when p_kind = 'plan' then p_time end,
          case when p_priority in ('low', 'mid', 'high') then p_priority else 'mid' end,
          case when p_kind = 'task' then p_due end, acc, case when p_kind = 'task' and o <> w then 'new' else 'ok' end);
end $$;

-- Исполнитель отдаёт задачу автору на проверку, а не закрывает сам.
create or replace function vx_item_set(p_code text, p_id uuid, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items;
begin
  if w is null then return; end if;
  select * into it from vx_items where id = p_id and (owner = w or by_user = w or w = 'maxim');
  if it.id is null then return; end if;
  if p_done and it.kind = 'task' and coalesce(it.by_user, it.owner) <> it.owner and w = it.owner then
    update vx_items set status = 'review' where id = p_id;
  else
    update vx_items set done = p_done where id = p_id;
  end if;
end $$;

drop function if exists vx_task_update(text, uuid, text, text, text, date, boolean, text);
create or replace function vx_task_update(p_code text, p_id uuid, p_body text default null, p_status text default null, p_priority text default null,
                                          p_due date default null, p_clear_due boolean default false, p_owner text default null,
                                          p_access text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items; st text := p_status;
begin
  if w is null then return; end if;
  select * into it from vx_items where id = p_id and (owner = w or by_user = w or w = 'maxim');
  if it.id is null then return; end if;
  if st is not null and st not in ('todo', 'doing', 'review', 'done') then return; end if;
  if p_priority is not null and p_priority not in ('low', 'mid', 'high') then return; end if;
  if p_access is not null and p_access not in ('me', 'friends', 'all') then return; end if;
  if p_owner is not null and (not vx_is_member(p_owner) or (p_owner <> w and not vx_are_friends(w, p_owner) and p_owner <> it.owner)) then raise exception 'not_friend'; end if;
  if p_body is not null and btrim(p_body) = '' then return; end if;
  if st = 'done' and it.kind = 'task' and coalesce(it.by_user, it.owner) <> it.owner and w = it.owner then st := 'review'; end if;
  update vx_items set body = coalesce(btrim(p_body), body), status = coalesce(st, status), priority = coalesce(p_priority, priority),
         due = case when it.kind <> 'task' then null when p_clear_due then null else coalesce(p_due, due) end,
         owner = coalesce(p_owner, owner),
         access = case when p_access = 'me' and coalesce(p_owner, owner) <> coalesce(by_user, owner) then access else coalesce(p_access, access) end,
         accept = case when p_owner is not null and p_owner <> it.owner and p_owner <> w then 'new' else accept end
   where id = p_id;
  if p_owner is not null and p_owner <> it.owner then
    perform vx_tg(p_owner, vx_title(w) || vx_g(w, ' передал', ' передала') || ' тебе задачу: ' || coalesce(nullif(btrim(p_body), ''), it.body), 'items');
  end if;
end $$;

-- Исполнитель принимает задачу или отклоняет её с причиной.
create or replace function vx_task_answer(p_code text, p_id uuid, p_accept boolean, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items;
begin
  if w is null then return; end if;
  select * into it from vx_items where id = p_id and owner = w and accept = 'new';
  if it.id is null then return; end if;
  if p_accept then
    update vx_items set accept = 'ok' where id = p_id;
    perform vx_bell(it.by_user, w, 'accept', vx_title(w) || vx_g(w, ' принял', ' приняла') || ' задачу: ' || it.body, 'item', it.id);
    perform vx_tg(it.by_user, vx_title(w) || vx_g(w, ' принял', ' приняла') || ' задачу: ' || it.body, 'items');
  else
    update vx_items set accept = 'declined', decline_reason = left(btrim(coalesce(p_reason, '')), 200) where id = p_id;
    perform vx_bell(it.by_user, w, 'decline', vx_title(w) || vx_g(w, ' отклонил', ' отклонила') || ' задачу «' || left(it.body, 60) || '»' || case when btrim(coalesce(p_reason, '')) <> '' then ': ' || left(btrim(p_reason), 200) else '' end, 'item', it.id);
    perform vx_tg(it.by_user, vx_title(w) || vx_g(w, ' отклонил', ' отклонила') || ' задачу «' || left(it.body, 60) || '»' || case when btrim(coalesce(p_reason, '')) <> '' then ': ' || left(btrim(p_reason), 200) else '' end, 'items');
  end if;
end $$;

-- Автор забирает задачу обратно.
create or replace function vx_task_take_back(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_items set owner = w, accept = 'ok', decline_reason = '' where id = p_id and by_user = w and owner <> w;
end $$;

-- Чек-лист: массив пунктов {t: текст, d: сделано}.
create or replace function vx_task_checklist(p_code text, p_id uuid, p_list jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); cl jsonb;
begin
  if w is null or jsonb_typeof(p_list) <> 'array' or jsonb_array_length(p_list) > 30 then return; end if;
  select coalesce(jsonb_agg(jsonb_build_object('t', left(btrim(x ->> 't'), 100), 'd', coalesce((x ->> 'd')::boolean, false))), '[]'::jsonb)
    into cl from jsonb_array_elements(p_list) x where btrim(coalesce(x ->> 't', '')) <> '';
  update vx_items set checklist = cl where id = p_id and (owner = w or by_user = w);
end $$;

-- Удалить может автор (или исполнитель собственной записи) и Максим. Задача уходит в корзину на 7 дней.
create or replace function vx_item_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items;
begin
  if w is null then return; end if;
  select * into it from vx_items where id = p_id
     and (by_user = w or (owner = w and coalesce(by_user, owner) = owner) or w = 'maxim');
  if it.id is null then return; end if;
  begin
    insert into vx_item_trash(id, owner, by_user, snapshot, comments)
    values (it.id, it.owner, it.by_user, to_jsonb(it),
            coalesce((select jsonb_agg(to_jsonb(c)) from vx_comments c where c.item_id = it.id), '[]'::jsonb))
    on conflict (id) do update set snapshot = excluded.snapshot, comments = excluded.comments, deleted_at = now();
  end;
  delete from vx_items where id = p_id;
  perform vx_bell(it.owner, w, 'del', vx_title(w) || vx_g(w, ' удалил', ' удалила') || ' задачу: ' || it.body, null, null);
end $$;

create or replace function vx_item_restore(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); t vx_item_trash; it vx_items; c jsonb;
begin
  if w is null then return; end if;
  select * into t from vx_item_trash where id = p_id and (owner = w or by_user = w) and deleted_at > now() - interval '7 days';
  if t.id is null then return; end if;
  it := jsonb_populate_record(null::vx_items, t.snapshot);
  insert into vx_items select (it).*;
  for c in select * from jsonb_array_elements(t.comments) loop
    insert into vx_comments select (jsonb_populate_record(null::vx_comments, c)).* on conflict do nothing;
  end loop;
  delete from vx_item_trash where id = p_id;
end $$;

-- ---------- Функции: события ----------
drop function if exists vx_event_add(text, text, date, text, text, uuid);
create or replace function vx_event_add(p_code text, p_title text, p_date date, p_time text, p_cat text default 'personal', p_task uuid default null,
                                        p_place text default '', p_dur int default null, p_guests text[] default '{}', p_rule text default 'all') returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); g text[];
begin
  if w is null then return; end if;
  select coalesce(array_agg(x), '{}') into g from (select distinct x from unnest(coalesce(p_guests, '{}')) x where x <> w and vx_are_friends(w, x)) s;
  insert into vx_events(title, day, at_time, by_user, votes, category, task_id, place, dur, guests, rule)
  values (btrim(p_title), p_date, p_time, w, jsonb_build_object(w, 'yes'),
          case when p_cat in ('work', 'study', 'personal', 'other') then p_cat else 'personal' end,
          (select id from vx_items where id = p_task and kind = 'task'),
          left(btrim(coalesce(p_place, '')), 100), case when p_dur between 5 and 1440 then p_dur end, g,
          case when p_rule = 'majority' then 'majority' else 'all' end);
end $$;

create or replace function vx_event_vote(p_code text, p_id uuid, p_vote text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  if p_vote not in ('yes', 'no', '') then raise exception 'bad vote'; end if;
  if not vx_ev_vis_id(w, p_id) then return; end if;
  update vx_events set votes = votes || jsonb_build_object(w, p_vote) where id = p_id;
end $$;

-- Удалить событие может только автор или Максим.
create or replace function vx_event_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_events where id = p_id and (by_user = w or w = 'maxim');
end $$;

drop function if exists vx_event_edit(text, uuid, text, date, text, text);
create or replace function vx_event_edit(p_code text, p_id uuid, p_title text, p_day date, p_time text, p_cat text default null,
                                         p_place text default null, p_dur int default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); ev vx_events;
begin
  if w is null then return; end if;
  update vx_events set title = btrim(p_title), day = p_day, at_time = p_time, votes = jsonb_build_object(w, 'yes'),
         category = case when p_cat in ('work', 'study', 'personal', 'other') then p_cat else category end,
         place = case when p_place is null then place else left(btrim(p_place), 100) end,
         dur = case when p_dur between 5 and 1440 then p_dur when p_dur = 0 then null else dur end,
         reminded = false
   where id = p_id and (by_user = w or w = 'maxim') returning * into ev;
  if ev.id is null then return; end if;
  perform vx_tg(k, vx_title(w) || vx_g(w, ' изменил', ' изменила') || ' событие: ' || ev.title
    || ' (' || to_char(ev.day, 'DD.MM') || ' в ' || ev.at_time || '). Ответь на сайте ещё раз.', 'edits')
    from unnest(vx_ev_aud(ev)) k;
  perform vx_bell(k, w, 'event', vx_title(w) || vx_g(w, ' изменил', ' изменила') || ' событие: ' || ev.title || '. Ответь ещё раз.', 'event', ev.id)
    from unnest(vx_ev_aud(ev)) k;
end $$;

-- ---------- Функции: комментарии, реакции ----------
drop function if exists vx_comment_add(text, uuid, text);
create or replace function vx_comment_add(p_code text, p_body text, p_item uuid default null, p_event uuid default null, p_file uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); it vx_items; ev vx_events; b text; k text; txt text; head text; seen boolean; tos text[] := '{}';
begin
  if w is null or btrim(coalesce(p_body, '')) = '' then return; end if;
  b := left(btrim(p_body), 500);
  if p_item is not null then
    select * into it from vx_items where id = p_item;
    if it.id is null or not vx_it_vis(w, it) then return; end if;
    insert into vx_comments(item_id, by_user, body) values (p_item, w, b);
    head := it.body; tos := array[it.owner, coalesce(it.by_user, it.owner)];
  elsif p_event is not null then
    select * into ev from vx_events where id = p_event;
    if ev.id is null or not vx_ev_vis(w, ev) then return; end if;
    insert into vx_comments(event_id, by_user, body) values (p_event, w, b);
    head := ev.title; tos := array[ev.by_user];
  elsif p_file is not null then
    select title into head from vx_files where id = p_file;
    if head is null then return; end if;
    insert into vx_comments(file_id, by_user, body) values (p_file, w, b);
    tos := array['maxim'];
  else
    return;
  end if;
  txt := vx_title(w) || vx_g(w, ' прокомментировал', ' прокомментировала') || ' «' || left(head, 60) || '»: ' || left(b, 200);
  for k in select distinct x from unnest(tos) x loop
    if k <> w and vx_is_member(k) then
      perform vx_tg(k, txt, 'comments');
      perform vx_bell(k, w, 'comment', txt, case when p_item is not null then 'item' when p_event is not null then 'event' else 'file' end, coalesce(p_item, p_event, p_file));
    end if;
  end loop;
  -- @упоминания
  for k in select u.name from vx_users u
            where not u.disabled and u.name <> w and not (u.name = any(tos))
              and exists (select 1 from regexp_matches(b, '@([A-Za-zА-Яа-яЁё0-9_-]+)', 'g') m where lower(m[1]) = lower(u.title) or lower(m[1]) = u.name) loop
    seen := case when p_item is not null then vx_it_vis(k, it) when p_event is not null then vx_ev_vis(k, ev) else true end;
    if seen then
      perform vx_tg(k, vx_title(w) || vx_g(w, ' упомянул', ' упомянула') || ' тебя в «' || left(head, 60) || '»: ' || left(b, 200), 'comments');
      perform vx_bell(k, w, 'mention', vx_title(w) || vx_g(w, ' упомянул', ' упомянула') || ' тебя в «' || left(head, 60) || '»: ' || left(b, 200),
                      case when p_item is not null then 'item' when p_event is not null then 'event' else 'file' end, coalesce(p_item, p_event, p_file));
    end if;
  end loop;
end $$;

-- Удалить комментарий: автор комментария, автор записи и Максим.
create or replace function vx_comment_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_comments c where c.id = p_id and (c.by_user = w or w = 'maxim'
    or exists (select 1 from vx_items i where i.id = c.item_id and i.by_user = w)
    or exists (select 1 from vx_events e where e.id = c.event_id and e.by_user = w));
end $$;

-- Свой комментарий можно изменить в течение 15 минут.
create or replace function vx_comment_edit(p_code text, p_id uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null or btrim(coalesce(p_body, '')) = '' then return; end if;
  update vx_comments set body = left(btrim(p_body), 500), edited_at = now()
   where id = p_id and by_user = w and created_at > now() - interval '15 minutes';
end $$;

-- Реакция на запись: «принято», «сделаю», «не согласен». Пустая реакция снимает прежнюю.
create or replace function vx_react(p_code text, p_kind text, p_target uuid, p_react text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); ok boolean;
begin
  if w is null or p_kind not in ('item', 'event', 'file', 'comment') then return; end if;
  ok := case p_kind when 'item' then vx_it_vis_id(w, p_target) when 'event' then vx_ev_vis_id(w, p_target) else true end;
  if not ok then return; end if;
  if coalesce(p_react, '') = '' then
    delete from vx_reactions where kind = p_kind and target = p_target and who = w;
  elsif p_react in ('ok', 'doing', 'no') then
    insert into vx_reactions(kind, target, who, react) values (p_kind, p_target, w, p_react)
    on conflict (kind, target, who) do update set react = excluded.react, at = now();
    if p_kind = 'item' then
      perform vx_bell(i.by_user, w, 'react', vx_title(w) || ': ' || case p_react when 'ok' then 'принято' when 'doing' then 'сделаю' else 'не согласен' end || ' — «' || left(i.body, 60) || '»', 'item', i.id)
        from vx_items i where i.id = p_target;
    end if;
  end if;
end $$;

-- ---------- Функции: друзья ----------
create or replace function vx_friend_request(p_code text, p_to text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); r vx_friends;
begin
  if w is null then return jsonb_build_object('error', 'forbidden'); end if;
  if p_to = w or not vx_is_member(p_to) then return jsonb_build_object('error', 'bad'); end if;
  if vx_blocked_pair(w, p_to) then return jsonb_build_object('error', 'blocked'); end if;
  delete from vx_friends where least(a, b) = least(w, p_to) and greatest(a, b) = greatest(w, p_to)
     and ((status = 'pending' and created_at < now() - interval '14 days') or (status = 'declined' and changed_at < now() - interval '30 days'));
  select * into r from vx_friends where least(a, b) = least(w, p_to) and greatest(a, b) = greatest(w, p_to);
  if r.a is not null then
    if r.status = 'friend' then return jsonb_build_object('error', 'already'); end if;
    if r.status = 'pending' and r.a = p_to then
      update vx_friends set status = 'friend', changed_at = now() where a = r.a and b = r.b;
      perform vx_bell(p_to, w, 'friend', vx_title(w) || ': теперь вы друзья', null, null);
      return jsonb_build_object('ok', true, 'friends', true);
    end if;
    if r.status = 'pending' then return jsonb_build_object('error', 'already'); end if;
    return jsonb_build_object('error', 'pause');
  end if;
  insert into vx_friends(a, b, status) values (w, p_to, 'pending');
  perform vx_bell(p_to, w, 'friend_req', vx_title(w) || vx_g(w, ' хочет', ' хочет') || ' добавить вас в друзья', null, null);
  perform vx_tg(p_to, vx_title(w) || ' хочет добавить вас в друзья. Ответ на сайте: колокольчик.', 'friends');
  return jsonb_build_object('ok', true);
end $$;

create or replace function vx_friend_cancel(p_code text, p_to text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_friends where a = w and b = p_to and status = 'pending';
end $$;

-- Ответ на запрос: принять, отклонить молча или отклонить и заблокировать.
create or replace function vx_friend_answer(p_code text, p_from text, p_accept boolean, p_block boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); r vx_friends;
begin
  if w is null then return jsonb_build_object('error', 'forbidden'); end if;
  select * into r from vx_friends where a = p_from and b = w and status = 'pending';
  if r.a is null then return jsonb_build_object('error', 'gone'); end if;
  if r.created_at < now() - interval '14 days' then
    delete from vx_friends where a = p_from and b = w;
    return jsonb_build_object('error', 'expired');
  end if;
  if p_accept then
    update vx_friends set status = 'friend', changed_at = now() where a = p_from and b = w;
    perform vx_bell(p_from, w, 'friend', vx_title(w) || vx_g(w, ' принял', ' приняла') || ' запрос: теперь вы друзья', null, null);
    perform vx_tg(p_from, vx_title(w) || vx_g(w, ' принял', ' приняла') || ' запрос: теперь вы друзья.', 'friends');
  elsif p_block then
    delete from vx_friends where a = p_from and b = w;
    insert into vx_friends(a, b, status) values (w, p_from, 'blocked');
  else
    update vx_friends set status = 'declined', changed_at = now() where a = p_from and b = w;
    perform vx_bell(p_from, w, 'friend_no', 'Запрос закрыт: ' || vx_title(w), null, null);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Убрать из друзей. p_tasks: 'keep' (оставить исполнителю) или 'back' (вернуть мне то, что я поставил).
create or replace function vx_friend_remove(p_code text, p_who text, p_tasks text default 'keep') returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  if not vx_are_friends(w, p_who) then return; end if;
  if p_tasks = 'back' then
    update vx_items set owner = w, accept = 'ok' where kind = 'task' and by_user = w and owner = p_who and not done;
  end if;
  delete from vx_friends where least(a, b) = least(w, p_who) and greatest(a, b) = greatest(w, p_who) and status = 'friend';
  insert into vx_log(who, action, detail, aud) values (w, 'friend_del', 'убрал(а) из друзей: ' || vx_title(p_who), array[w]);
end $$;

create or replace function vx_block(p_code text, p_who text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null or p_who = w or not vx_is_member(p_who) then return; end if;
  delete from vx_friends where least(a, b) = least(w, p_who) and greatest(a, b) = greatest(w, p_who);
  insert into vx_friends(a, b, status) values (w, p_who, 'blocked');
end $$;

create or replace function vx_unblock(p_code text, p_who text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_friends where a = w and b = p_who and status = 'blocked';
end $$;

-- ---------- Функции: колокольчик, профиль, тур ----------
create or replace function vx_bell_read(p_code text, p_id bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_bell set read = true where to_name = w and not read and (p_id is null or id = p_id);
end $$;

create or replace function vx_me_settings(p_code text, p_group text default null, p_show_sched text default null, p_show_online text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return null; end if;
  if p_group is not null then
    if char_length(btrim(p_group)) > 20 or btrim(p_group) !~ '^[A-Za-zА-Яа-яЁё0-9 ._-]*$' then return jsonb_build_object('error', 'bad_group'); end if;
    update vx_users set sched_group = btrim(p_group) where name = w;
  end if;
  if p_show_sched in ('none', 'friends', 'all') then update vx_users set show_sched = p_show_sched where name = w; end if;
  if p_show_online in ('none', 'friends') then update vx_users set show_online = p_show_online where name = w; end if;
  return (select jsonb_build_object('group', sched_group, 'show_sched', show_sched, 'show_online', show_online) from vx_users where name = w);
end $$;

create or replace function vx_tour_done(p_code text, p_done boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_users set tour_done = p_done where name = w;
end $$;

-- ---------- Функции: общие списки ----------
create or replace function vx_list_vis(p_who text, l vx_lists) returns boolean
language sql stable security definer set search_path = public as $$
  select p_who = l.by_user or p_who = any(l.members) or (cardinality(l.members) = 0 and vx_are_friends(p_who, l.by_user))
$$;
create or replace function vx_list_vis_id(p_who text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vx_lists l where l.id = p_id and vx_list_vis(p_who, l))
$$;
revoke all on function vx_list_vis(text, vx_lists), vx_list_vis_id(text, uuid) from public, anon, authenticated;

create or replace function vx_list_add(p_code text, p_title text, p_members text[] default '{}') returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); m text[];
begin
  if w is null or char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then return; end if;
  select coalesce(array_agg(x), '{}') into m from (select distinct x from unnest(coalesce(p_members, '{}')) x where x <> w and vx_are_friends(w, x)) s;
  insert into vx_lists(title, by_user, members) values (btrim(p_title), w, m);
end $$;

create or replace function vx_list_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_lists where id = p_id and (by_user = w or w = 'maxim');
end $$;

create or replace function vx_list_members(p_code text, p_id uuid, p_members text[]) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); m text[];
begin
  if w is null then return; end if;
  select coalesce(array_agg(x), '{}') into m from (select distinct x from unnest(coalesce(p_members, '{}')) x where x <> w and vx_are_friends(w, x)) s;
  update vx_lists set members = m where id = p_id and by_user = w;
end $$;

create or replace function vx_list_item_add(p_code text, p_list uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); l vx_lists; k text;
begin
  if w is null or char_length(btrim(coalesce(p_body, ''))) not between 1 and 200 then return; end if;
  select * into l from vx_lists where id = p_list;
  if l.id is null or not vx_list_vis(w, l) then return; end if;
  insert into vx_list_items(list_id, body, by_user) values (p_list, btrim(p_body), w);
  for k in select distinct x from unnest(array[l.by_user] || case when cardinality(l.members) > 0 then l.members else vx_friends_of(l.by_user) end) x loop
    if k <> w then perform vx_bell(k, w, 'list', vx_title(w) || vx_g(w, ' добавил', ' добавила') || ' в список «' || left(l.title, 40) || '»: ' || left(btrim(p_body), 100), 'list', l.id); end if;
  end loop;
end $$;

create or replace function vx_list_item_set(p_code text, p_id uuid, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  update vx_list_items i set done = p_done, done_by = case when p_done then w end
   where i.id = p_id and vx_list_vis_id(w, i.list_id);
end $$;

create or replace function vx_list_item_del(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null then return; end if;
  delete from vx_list_items i where i.id = p_id and (i.by_user = w or w = 'maxim' or exists (select 1 from vx_lists l where l.id = i.list_id and l.by_user = w));
end $$;

-- ---------- Функции: чертежи и объявление (Максим) ----------
create or replace function vx_file_meta(p_code text, p_id uuid, p_status text default null, p_due date default null, p_clear_due boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code);
begin
  if w is null or w <> 'maxim' then return; end if;
  if p_status is not null and p_status not in ('draft', 'review', 'done') then return; end if;
  update vx_files set status = coalesce(p_status, status), due = case when p_clear_due then null else coalesce(p_due, due) end where id = p_id;
end $$;

create or replace function vx_notice_set(p_code text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare w text := vx_who(p_code); k text; b text := left(btrim(coalesce(p_body, '')), 300);
begin
  if w is null or w <> 'maxim' then return; end if;
  if b = '' then
    delete from vx_settings where key in ('notice', 'notice_at');
    return;
  end if;
  insert into vx_settings(key, value) values ('notice', b) on conflict (key) do update set value = excluded.value;
  insert into vx_settings(key, value) values ('notice_at', now()::text) on conflict (key) do update set value = excluded.value;
  for k in select name from vx_users where not disabled and name <> w loop
    perform vx_bell(k, w, 'notice', 'Объявление: ' || b, null, null);
  end loop;
end $$;

-- ---------- Напоминания и сводка: только то, что видит человек ----------
create or replace function vx_remind() returns void
language plpgsql security definer set search_path = public as $$
declare r record; nowm timestamp := (now() at time zone 'Europe/Moscow'); k text;
begin
  for r in select * from vx_events where not reminded and (day + at_time::time) > nowm and (day + at_time::time) <= nowm + interval '1 hour' loop
    for k in select name from vx_users where not disabled order by ord loop
      if coalesce(r.votes ->> k, '') <> 'no' and vx_ev_vis_id(k, r.id) then
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

create or replace function vx_digest(p_only text default null) returns void
language plpgsql security definer set search_path = public as $$
declare k text; today date := (now() at time zone 'Europe/Moscow')::date; msg text; part text; due_part text; n int; tg_kind text;
  dn text[] := array['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];
  pt text[] := array['08:30', '10:15', '12:30', '14:15', '16:00', '18:00'];
begin
  tg_kind := case when p_only is null then 'digest' else 'misc' end;
  for k in select name from vx_users where not disabled order by ord loop
    if p_only is not null and k <> p_only then continue; end if;
    msg := 'Доброе утро! Сегодня ' || dn[extract(dow from today)::int + 1] || ', ' || to_char(today, 'DD.MM') || '.';
    select string_agg('• ' || s.pair || '-я (' || pt[s.pair] || ') ' || s.subject || case when s.room <> '' then ' ' || s.room else '' end, E'\n' order by s.pair)
      into part from vx_schedule s where s.owner = k and s.day = today;
    if part is not null then msg := msg || E'\n\nПары:\n' || part; end if;
    select string_agg('• ' || x.t || ' ' || x.title, E'\n' order by x.t) into part from (
      select at_time as t, body as title from vx_items where kind = 'plan' and owner = k and day = today and not done
      union all
      select at_time, title from vx_events where day = today and coalesce(votes ->> k, '') <> 'no' and vx_ev_vis_id(k, id)) x;
    if part is not null then msg := msg || E'\n\nПланы:\n' || part; end if;
    select string_agg('• ' || i.body || case when i.due < today then ' (просрочено, ' || to_char(i.due, 'DD.MM') || ')' else '' end, E'\n' order by i.due, i.created_at)
      into due_part from vx_items i where i.kind = 'task' and i.owner = k and not i.done and i.due is not null and i.due <= today;
    if due_part is not null then msg := msg || E'\n\nСрок сегодня и просрочено:\n' || due_part; end if;
    select count(*) into n from vx_items where kind = 'task' and owner = k and not done;
    if n > 0 then msg := msg || E'\n\nНевыполненных задач: ' || n; end if;
    if part is not null or due_part is not null or n > 0 or exists (select 1 from vx_schedule where owner = k and day = today) or p_only is not null then
      perform vx_tg(k, msg, tg_kind);
    end if;
  end loop;
end $$;
revoke all on function vx_digest(text) from public, anon, authenticated;

-- ---------- Загрузка данных ----------
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
  update vx_users set last_seen = now() where name = w and (last_seen is null or last_seen < now() - interval '1 minute');
  return jsonb_build_object(
    'me', w,
    'users', coalesce((
      select jsonb_agg(jsonb_build_object(
          'name', u.name, 'title', u.title, 'fem', u.fem, 'off', u.disabled,
          'rel', case when u.name = w then 'me'
                      when f.status = 'friend' then 'friend'
                      when f.status = 'pending' and f.created_at > now() - interval '14 days' then case when f.a = w then 'out' else 'in' end
                      when f.status = 'blocked' and f.a = w then 'blocked'
                      else 'none' end,
          'rel_at', case when f.status = 'pending' then f.created_at end,
          'paused', f.status = 'declined' and f.a = w and f.changed_at > now() - interval '30 days',
          'online', u.name <> w and f.status = 'friend' and u.show_online = 'friends' and u.last_seen > now() - interval '10 minutes',
          'group', case when u.name = w or f.status = 'friend' then u.sched_group else '' end
        ) order by u.ord, u.joined_at)
      from vx_users u
      left join vx_friends f on least(f.a, f.b) = least(u.name, w) and greatest(f.a, f.b) = greatest(u.name, w)), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'date', e.day, 'time', e.at_time, 'by', e.by_user, 'votes', e.votes,
                                                          'cat', e.category, 'task', e.task_id, 'place', e.place, 'dur', e.dur, 'guests', e.guests, 'rule', e.rule)
                                 order by e.day, e.at_time, e.created_at) from vx_events e where vx_ev_vis(w, e)), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'owner', i.owner, 'text', i.body, 'when', i.when_text, 'done', i.done, 'date', i.day, 'time', i.at_time,
                                                          'by', coalesce(i.by_user, i.owner), 'status', i.status, 'priority', i.priority, 'due', i.due, 'created', i.created_at,
                                                          'access', i.access, 'accept', i.accept, 'reason', i.decline_reason, 'check', i.checklist, 'done_at', i.done_at)
                                 order by i.day nulls last, i.at_time nulls last, i.created_at) from vx_items i where vx_it_vis(w, i)), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'item', c.item_id, 'event', c.event_id, 'file', c.file_id, 'by', c.by_user, 'body', c.body, 'at', c.created_at, 'edited', c.edited_at)
                                 order by c.created_at)
                          from (select * from vx_comments order by created_at desc limit 600) c
                          where (c.item_id is not null and vx_it_vis_id(w, c.item_id)) or (c.event_id is not null and vx_ev_vis_id(w, c.event_id)) or c.file_id is not null), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'project', project, 'title', title, 'date', day, 'note', note, 'path', path, 'filename', filename, 'status', status, 'due', due) order by day, created_at) from vx_files), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'owner', s.owner, 'date', s.day, 'pair', s.pair, 'subject', s.subject, 'room', s.room) order by s.day, s.pair)
                          from vx_schedule s join vx_users o on o.name = s.owner
                          where s.owner = w or o.show_sched = 'all' or (o.show_sched = 'friends' and vx_are_friends(w, s.owner))), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'who', who, 'action', action, 'detail', detail) order by id desc)
                        from (select * from vx_log where action not like 'admin%' and action not in ('tg_self', 'profile', 'friend_del')
                                and (aud is null or w = any(aud) or who = w) order by id desc limit 12) r), '[]'::jsonb),
    'trash', case when w = 'maxim' then coalesce((select jsonb_agg(path) from vx_trash), '[]'::jsonb) else '[]'::jsonb end,
    'tg_muted', vx_muted(w),
    'bell', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'body', body, 'from', from_name, 'ref', ref_kind, 'ref_id', ref_id, 'read', read, 'at', at) order by id desc)
                      from (select * from vx_bell where to_name = w order by id desc limit 60) b), '[]'::jsonb),
    'reactions', coalesce((select jsonb_agg(jsonb_build_object('k', r.kind, 't', r.target, 'w', r.who, 'r', r.react))
                           from vx_reactions r
                           where (r.kind = 'item' and vx_it_vis_id(w, r.target)) or (r.kind = 'event' and vx_ev_vis_id(w, r.target)) or r.kind = 'file'
                              or (r.kind = 'comment' and exists (select 1 from vx_comments c where c.id = r.target and ((c.item_id is not null and vx_it_vis_id(w, c.item_id)) or (c.event_id is not null and vx_ev_vis_id(w, c.event_id)) or c.file_id is not null)))), '[]'::jsonb),
    'lists', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'by', l.by_user, 'members', l.members, 'at', l.created_at,
                         'items', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'text', x.body, 'by', x.by_user, 'done', x.done, 'done_by', x.done_by) order by x.created_at)
                                            from vx_list_items x where x.list_id = l.id), '[]'::jsonb)) order by l.created_at desc)
                       from vx_lists l where vx_list_vis(w, l)), '[]'::jsonb),
    'deleted', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'text', t.snapshot ->> 'body', 'at', t.deleted_at) order by t.deleted_at desc)
                         from vx_item_trash t where (t.owner = w or t.by_user = w) and t.deleted_at > now() - interval '7 days'), '[]'::jsonb),
    'notice', (select jsonb_build_object('body', n.value, 'at', (select value from vx_settings where key = 'notice_at')) from vx_settings n where n.key = 'notice'),
    'profile', (select jsonb_build_object('group', sched_group, 'show_sched', show_sched, 'show_online', show_online, 'tour', tour_done) from vx_users where name = w)
  );
end $$;

-- ---------- Резервная копия: без записей «только мне» ----------
create or replace function vx_admin_backup(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'exported_at', now(),
    'users', coalesce((select jsonb_agg(to_jsonb(u) - 'code_hash' order by u.ord) from vx_users u), '[]'::jsonb),
    'friends', coalesce((select jsonb_agg(to_jsonb(f)) from vx_friends f), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) - 'reminded' order by e.day, e.at_time) from vx_events e), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i) - 'reminded' order by i.created_at) from vx_items i where i.access <> 'me'), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from vx_comments c
                           where c.item_id is null or exists (select 1 from vx_items i where i.id = c.item_id and i.access <> 'me')), '[]'::jsonb),
    'lists', coalesce((select jsonb_agg(to_jsonb(l)) from vx_lists l where cardinality(l.members) = 0), '[]'::jsonb),
    'schedule', coalesce((select jsonb_agg(to_jsonb(s) order by s.day, s.pair) from vx_schedule s), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(to_jsonb(f) order by f.day, f.created_at) from vx_files f), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from vx_settings where key not like 'tg\_%' or key like 'tg\_mute\_%' or key in ('tg_all', 'tg_items', 'tg_events', 'tg_votes', 'tg_edits', 'tg_comments', 'tg_remind', 'tg_digest', 'tg_friends')), '{}'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) - 'aud' order by l.id desc) from (select * from vx_log order by id desc limit 500) l), '[]'::jsonb),
    'logins', coalesce((select jsonb_agg(to_jsonb(g) order by g.id desc) from (select * from vx_logins order by id desc limit 200) g), '[]'::jsonb)
  );
end $$;

-- Корзина задач: чистим старше 7 дней раз в сутки.
do $$ begin
  begin perform cron.unschedule('vexxo-trash-items'); exception when others then null; end;
  perform cron.schedule('vexxo-trash-items', '15 3 * * *', $c$delete from vx_item_trash where deleted_at < now() - interval '7 days'$c$);
exception when others then null; end $$;

-- ---------- Настройки Telegram: добавлен тип «друзья» ----------
create or replace function vx_admin_set(p_code text, p_key text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return jsonb_build_object('error', 'forbidden'); end if;
  if not (p_key in ('tg_all', 'tg_items', 'tg_events', 'tg_votes', 'tg_edits', 'tg_comments', 'tg_remind', 'tg_digest', 'tg_friends', 'open_reg')
          or (p_key like 'tg\_mute\_%' and exists (select 1 from vx_users where name = substr(p_key, 9)))) then
    return jsonb_build_object('error', 'bad_key');
  end if;
  -- для tg_mute_* значение p_on = true значит «отключить этому человеку»; для остальных true значит «включено»
  insert into vx_settings(key, value) values (p_key, case when p_on then '1' else '0' end)
  on conflict (key) do update set value = excluded.value;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_setting', p_key || ' = ' || case when p_on then 'вкл' else 'выкл' end);
  return vx_tg_flags();
end $$;

create or replace function vx_tg_flags() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('all', vx_flag('tg_all'), 'items', vx_flag('tg_items'), 'events', vx_flag('tg_events'), 'votes', vx_flag('tg_votes'),
                            'edits', vx_flag('tg_edits'), 'comments', vx_flag('tg_comments'), 'remind', vx_flag('tg_remind'), 'digest', vx_flag('tg_digest'),
                            'friends', vx_flag('tg_friends'), 'open_reg', vx_open_reg(),
                            'mute', coalesce((select jsonb_object_agg(name, vx_muted(name)) from vx_users), '{}'::jsonb),
                            'mute_ulya', vx_muted('ulya'), 'mute_maxim', vx_muted('maxim'))
$$;
revoke all on function vx_tg_flags() from public, anon, authenticated;

-- ---------- Права ----------
revoke all on function
  vx_item_add(text, text, text, text, text, date, text, text, date, text), vx_item_set(text, uuid, boolean),
  vx_task_update(text, uuid, text, text, text, date, boolean, text, text), vx_task_answer(text, uuid, boolean, text), vx_task_take_back(text, uuid),
  vx_task_checklist(text, uuid, jsonb), vx_item_del(text, uuid), vx_item_restore(text, uuid),
  vx_event_add(text, text, date, text, text, uuid, text, int, text[], text), vx_event_vote(text, uuid, text), vx_event_del(text, uuid),
  vx_event_edit(text, uuid, text, date, text, text, text, int),
  vx_comment_add(text, text, uuid, uuid, uuid), vx_comment_del(text, uuid), vx_comment_edit(text, uuid, text), vx_react(text, text, uuid, text),
  vx_friend_request(text, text), vx_friend_cancel(text, text), vx_friend_answer(text, text, boolean, boolean), vx_friend_remove(text, text, text),
  vx_block(text, text), vx_unblock(text, text), vx_bell_read(text, bigint), vx_me_settings(text, text, text, text), vx_tour_done(text, boolean),
  vx_list_add(text, text, text[]), vx_list_del(text, uuid), vx_list_members(text, uuid, text[]), vx_list_item_add(text, uuid, text),
  vx_list_item_set(text, uuid, boolean), vx_list_item_del(text, uuid), vx_file_meta(text, uuid, text, date, boolean), vx_notice_set(text, text),
  vx_load(text), vx_admin_backup(text), vx_remind(), vx_digest(text) from public, anon, authenticated;
grant execute on function
  vx_item_add(text, text, text, text, text, date, text, text, date, text), vx_item_set(text, uuid, boolean),
  vx_task_update(text, uuid, text, text, text, date, boolean, text, text), vx_task_answer(text, uuid, boolean, text), vx_task_take_back(text, uuid),
  vx_task_checklist(text, uuid, jsonb), vx_item_del(text, uuid), vx_item_restore(text, uuid),
  vx_event_add(text, text, date, text, text, uuid, text, int, text[], text), vx_event_vote(text, uuid, text), vx_event_del(text, uuid),
  vx_event_edit(text, uuid, text, date, text, text, text, int),
  vx_comment_add(text, text, uuid, uuid, uuid), vx_comment_del(text, uuid), vx_comment_edit(text, uuid, text), vx_react(text, text, uuid, text),
  vx_friend_request(text, text), vx_friend_cancel(text, text), vx_friend_answer(text, text, boolean, boolean), vx_friend_remove(text, text, text),
  vx_block(text, text), vx_unblock(text, text), vx_bell_read(text, bigint), vx_me_settings(text, text, text, text), vx_tour_done(text, boolean),
  vx_list_add(text, text, text[]), vx_list_del(text, uuid), vx_list_members(text, uuid, text[]), vx_list_item_add(text, uuid, text),
  vx_list_item_set(text, uuid, boolean), vx_list_item_del(text, uuid), vx_file_meta(text, uuid, text, date, boolean), vx_notice_set(text, text),
  vx_load(text), vx_admin_backup(text) to anon;
revoke all on function vx_remind(), vx_digest(text) from public, anon, authenticated;

-- ======== migration-10.sql ========
-- Миграция 10: Максим может удалить участника с сайта.
-- Удалённый не входит (код и сессии перестают работать), а при попытке входа видит сообщение
-- «вас удалили по техническим причинам» и предложение зарегистрироваться заново через Telegram.
-- Данные человека (задачи, комментарии) остаются в базе, Максим может вернуть доступ кнопкой «Вернуть доступ».

alter table vx_users add column if not exists removed boolean not null default false;
alter table vx_users add column if not exists removed_at timestamptz;

create or replace function vx_admin_member_remove(p_code text, p_name text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return null; end if;
  if p_name = 'maxim' or not exists (select 1 from vx_users where name = p_name) then return null; end if;
  update vx_users set disabled = true, removed = true, removed_at = now() where name = p_name;
  -- Сессии не стираем: по ним сайт узнаёт, что человека удалили, и показывает сообщение. Войти по ним уже нельзя.
  delete from vx_notify where name = p_name;      -- чат в Telegram освобождается для новой регистрации
  delete from vx_friends where a = p_name or b = p_name;
  delete from vx_bell where to_name = p_name;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_member', vx_title(p_name) || ': удалён с сайта');
  return true;
end $$;

-- «Вернуть доступ» снимает и отключение, и удаление.
create or replace function vx_admin_member_set(p_code text, p_name text, p_off boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not vx_is_admin(p_code) then return null; end if;
  if p_name = 'maxim' or not exists (select 1 from vx_users where name = p_name) then return null; end if;
  update vx_users set disabled = p_off, removed = case when p_off then removed else false end, removed_at = case when p_off then removed_at else null end where name = p_name;
  if p_off then delete from vx_sessions where name = p_name; end if;
  insert into vx_log(who, action, detail) values ('maxim', 'admin_member', vx_title(p_name) || case when p_off then ': отключён' else ': возвращён' end);
  return p_off;
end $$;

-- Что с этим кодом или сессией: 'removed' (участника удалили) или 'none'. Неверные коды считаются как попытки входа.
create or replace function vx_state(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare r boolean;
begin
  if p_code is null then return 'none'; end if;
  if p_code ~ '^[0-9a-f]{64}$' then
    select u.removed into r from vx_sessions s join vx_users u on u.name = s.name
     where s.token_hash = encode(sha256(convert_to('vexxo-s:' || p_code, 'utf8')), 'hex') limit 1;
  elsif p_code ~ '^[0-9]{4,12}$' then
    if (select count(*) from vx_attempts where at > now() - interval '5 minutes') >= 30 then raise exception 'too_many_attempts'; end if;
    select u.removed into r from vx_users u where u.code_hash = encode(sha256(convert_to('vexxo:' || p_code, 'utf8')), 'hex');
    if r is null then insert into vx_attempts default values; end if;
  end if;
  return case when coalesce(r, false) then 'removed' else 'none' end;
end $$;

revoke all on function vx_admin_member_remove(text, text), vx_state(text) from public, anon, authenticated;
grant execute on function vx_admin_member_remove(text, text), vx_state(text) to anon;

-- ======== Стартовые коды ========
select x.name as "участник", x.code as "код входа (запиши)"
  from (select n as name, lpad((floor(random() * 900000) + 100000)::int::text, 6, '0') as code from unnest(array['maxim', 'ulya']) n) x,
       lateral (select vx_set_code(x.name, x.code)) s
 order by x.name;

-- Уля и Максим сразу друзья (остальные добавляются запросами на сайте).
insert into vx_friends(a, b, status) select 'maxim', 'ulya', 'friend'
 where exists (select 1 from vx_users where name = 'maxim') and exists (select 1 from vx_users where name = 'ulya')
on conflict do nothing;
