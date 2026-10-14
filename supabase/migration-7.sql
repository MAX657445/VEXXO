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
