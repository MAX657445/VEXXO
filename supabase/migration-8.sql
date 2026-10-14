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
