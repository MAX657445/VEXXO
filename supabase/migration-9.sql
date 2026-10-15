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
