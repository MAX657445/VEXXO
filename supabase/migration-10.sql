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
