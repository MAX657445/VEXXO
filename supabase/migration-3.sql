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
