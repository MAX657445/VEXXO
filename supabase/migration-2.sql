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
