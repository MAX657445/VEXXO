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
