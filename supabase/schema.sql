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
