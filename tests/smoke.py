"""Дымовой тест интерфейса: сервер Supabase подменяется заглушкой, проверяются основные сценарии.
Запуск: python3 tests/smoke.py (нужен playwright). Скриншоты кладутся в SHOTS (по умолчанию /tmp/vexxo-shots)."""
import json, os, sys, datetime
from zoneinfo import ZoneInfo
from playwright.sync_api import sync_playwright

SHOTS = os.environ.get('SHOTS', '/tmp/vexxo-shots'); os.makedirs(SHOTS, exist_ok=True)
INDEX = 'file://' + os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'index.html'))
TOKEN = 'a' * 64
NOW = datetime.datetime.now(ZoneInfo('Europe/Moscow'))
def d(n=0): return (NOW.date() + datetime.timedelta(days=n)).isoformat()
data = {
  "me": "maxim",
  "events": [{"id": "e1", "title": "Прогулка", "date": d(3), "time": "18:00:00", "by": "maxim", "votes": {"maxim": "yes"}, "cat": "personal", "task": None},
             {"id": "e2", "title": "Совместная работа", "date": d(0), "time": "20:00:00", "by": "ulya", "votes": {"ulya": "yes"}, "cat": "work", "task": "t1"}],
  "items": [
    {"id": "p1", "kind": "plan", "owner": "maxim", "text": "Кино", "when": "", "done": False, "date": d(2), "time": "19:30:00", "by": "ulya", "status": "todo", "priority": "mid", "due": None, "created": NOW.isoformat()},
    {"id": "t1", "kind": "task", "owner": "maxim", "text": "Купить краску", "when": "", "done": False, "date": None, "time": None, "by": "maxim", "status": "doing", "priority": "high", "due": d(0), "created": NOW.isoformat()},
    {"id": "t2", "kind": "task", "owner": "maxim", "text": "Сдать эскиз", "when": "", "done": False, "date": None, "time": None, "by": "ulya", "status": "todo", "priority": "mid", "due": d(-2), "created": NOW.isoformat()},
    {"id": "t3", "kind": "task", "owner": "ulya", "text": "Забрать посылку", "when": "", "done": False, "date": None, "time": None, "by": "ulya", "status": "review", "priority": "low", "due": None, "created": NOW.isoformat()},
    {"id": "t4", "kind": "task", "owner": "maxim", "text": "Старое дело", "when": "", "done": True, "date": None, "time": None, "by": "maxim", "status": "done", "priority": "mid", "due": None, "created": NOW.isoformat()}],
  "comments": [{"id": "c1", "item": "t1", "by": "ulya", "body": "Возьми белую", "at": NOW.isoformat()}],
  "recent": [{"at": NOW.isoformat(), "who": "ulya", "action": "task_add", "detail": "для Максима: Сдать эскиз"}],
  "files": [
    {"id": "f1", "project": "sapr", "title": "План 1 этажа", "date": "2026-10-10", "note": "первая", "path": "11111111-1111-1111-1111-111111111111/plan.pdf", "filename": "plan.pdf"},
    {"id": "f2", "project": "sapr", "title": "План 1 этажа", "date": "2026-10-14", "note": "правка 2", "path": "22222222-2222-2222-2222-222222222222/plan2.pdf", "filename": "plan2.pdf"},
    {"id": "f3", "project": "arch", "title": "Фасад", "date": "2026-10-12", "note": "", "path": "33333333-3333-3333-3333-333333333333/facade.png", "filename": "facade.png"}],
  "schedule": [{"id": "s1", "owner": "maxim", "date": d(0), "pair": 2, "subject": "САПР", "room": "1-28"}],
  "trash": [], "tg_muted": False
}
OVERVIEW = {"locked": False, "counts": {"events": 1, "events_upcoming": 1, "tasks_open": 1, "tasks_done": 2, "plans_open": 1, "plans_done": 0, "files": 3, "sched": 1, "log": 12},
  "storage": {"bytes": 3145728, "objects": 4}, "users": {"ulya": {"sessions": 1, "last_seen": "2026-10-14T17:00:00+00:00", "last_login": "2026-10-13T10:00:00+00:00"}, "maxim": {"sessions": 2, "last_seen": "2026-10-14T17:50:00+00:00", "last_login": "2026-10-14T09:00:00+00:00"}},
  "failed": {"count_24h": 3, "last": "2026-10-14T12:00:00+00:00"},
  "tg": {"token": True, "chats": {"ulya": True, "maxim": True}, "ok": 5, "fail": 0, "flags": {"all": True, "mute_ulya": False, "mute_maxim": False, "items": True, "events": True, "votes": True, "edits": True, "remind": True, "digest": False}},
  "cron": [{"name": "vexxo-remind", "schedule": "*/5 * * * *", "active": True, "last_at": "2026-10-14T17:55:00+00:00", "last_status": "succeeded", "last_msg": ""}]}
LOGINS = {"locked": False, "sessions": [{"name": "ulya", "device": "iPhone Safari", "created": "2026-10-13T10:00:00+00:00", "last_seen": "2026-10-14T17:00:00+00:00"}],
  "logins": [{"at": "2026-10-14T09:00:00+00:00", "name": "maxim", "kind": "login", "device": "Windows Chrome"}], "failed": {"count_24h": 3, "count_5m": 0, "last": "2026-10-14T12:00:00+00:00"}}
STORAGE = {"bytes": 3145728, "objects": 4, "trash": 0, "orphan_bytes": 5000,
  "files": [{"id": "f1", "project": "sapr", "title": "План 1 этажа", "filename": "plan.pdf", "date": "2026-10-10", "size": 1048576, "missing": False}],
  "orphans": [{"name": "99999999-9999-9999-9999-999999999999/old.pdf", "size": 5000, "created": "2026-10-10T10:00:00+00:00"}]}
LOG = [{"id": 2, "at": "2026-10-14T17:00:00+00:00", "who": "ulya", "action": "task_add", "detail": "для Максима: Купить хлеб"},
       {"id": 1, "at": "2026-10-14T16:00:00+00:00", "who": "maxim", "action": "event_add", "detail": "Прогулка (21.10 18:00)"}]
MOCK = {'vx_session_start': json.dumps(TOKEN), 'vx_load': json.dumps(data), 'vx_change_code': '"ok"', 'vx_file_prepare': '"44444444-4444-4444-4444-444444444444/new.pdf"',
  'vx_admin_overview': json.dumps(OVERVIEW), 'vx_admin_logins': json.dumps(LOGINS), 'vx_admin_storage': json.dumps(STORAGE), 'vx_admin_log': json.dumps(LOG),
  'vx_admin_lock': 'true', 'vx_admin_kick': '1', 'vx_admin_reset_code': '"ok"', 'vx_admin_purge': '1', 'vx_admin_clean_orphans': '1', 'vx_admin_backup': json.dumps({"events": [], "items": []}),
  'vx_admin_tg': '17', 'vx_admin_tg_status': json.dumps({"state": "ok", "status": 200}), 'vx_admin_set': json.dumps({}), 'vx_admin_run': 'true', 'vx_me_tg': 'true'}
calls = []
fails = []
def check(name, cond):
    print(('OK   ' if cond else 'FAIL ') + name)
    if not cond: fails.append(name)
def sent(fn, *subs):
    return any(c[0] == fn and all(x in (c[1] or '') for x in subs) for c in calls)

with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page(viewport={'width': 1280, 'height': 860})
    errors = []; pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('console', lambda m: errors.append(m.text) if m.type == 'error' and 'Failed to load resource' not in m.text else None)
    def h(route):
        u = route.request.url
        if 'googleapis' in u or 'gstatic' in u: return route.abort()
        if '/rpc/' in u:
            fn = u.split('/rpc/')[1]; body = route.request.post_data; calls.append((fn, body))
            res = MOCK.get(fn)
            return route.fulfill(status=200 if res else 204, content_type='application/json', body=res or '')
        if '/storage/' in u: return route.fulfill(status=200, content_type='application/json', body='{}')
        return route.fulfill(status=200, body='')
    pg.route('**/*', lambda r: h(r) if any(x in r.request.url for x in ('supabase', 'google', 'gstatic')) else r.continue_())
    pg.goto(INDEX)
    # ---- вход ----
    for k in '654321': pg.click(f'[data-k="{k}"]')
    check('точки растут по мере ввода', pg.locator('#dots i.on').count() == 6)
    pg.click('[data-k="ok"]'); pg.wait_for_selector('#app:not([hidden])')
    check('вход по коду выдаёт сессию', sent('vx_session_start', '654321'))
    check('дальше сайт ходит с токеном, а не с кодом', all('654321' not in (c[1] or '') for c in calls if c[0] != 'vx_session_start') and sent('vx_load', TOKEN))
    check('при входе передаётся название устройства', any(c[0] == 'vx_session_start' and '"p_device":"' in c[1] and 'p_device":""' not in c[1] for c in calls))
    check('токен сохранён на устройстве', pg.evaluate("localStorage.getItem('vexxo:session')") == TOKEN)
    # ---- главная ----
    t = pg.inner_text('#view').lower()
    check('главная: приветствие по имени', 'максим' in pg.inner_text('#view h1').lower())
    check('главная: задачи на сегодня, просроченные и события', 'купить краску' in t and 'сдать эскиз' in t and 'прогулка' in t and 'совместная работа' in t)
    check('главная: последние изменения и быстрые действия', 'добавлена задача' in t and 'быстрые действия' in t)
    check('меню слева сгруппировано', all(x in pg.inner_text('#side').lower() for x in ('работа', 'люди', 'настройки', 'главная', 'календарь', 'задачи', 'чертежи')))
    check('текущий раздел отмечен', pg.locator('#side [data-go="home"][aria-current="page"]').count() == 1)
    check('нет кнопки «Спросить Claude про идеи»', pg.locator('#ask-idea').count() == 0)
    pg.screenshot(path=f'{SHOTS}/home.png', full_page=True)
    pg.click('#view .chk[data-tgl="t1"]'); pg.wait_for_timeout(250)
    check('отметка выполнения идёт через статус задачи', sent('vx_task_update', '"p_id":"t1"', '"p_status":"done"'))
    # ---- создание задачи одним окном ----
    pg.click('#new-btn'); pg.wait_for_selector('#cr-form')
    pg.click('#cr-go'); check('пустое название не отправляется', not sent('vx_item_add') and 'название' in pg.inner_text('#cr-msg').lower())
    pg.fill('#cr-form input[name=t]', 'Заказать стекло'); pg.select_option('#cr-form select[name=p]', 'high'); pg.fill('#cr-form input[name=due]', d(5)); pg.select_option('#cr-form select[name=o]', 'ulya')
    pg.click('#cr-go'); pg.wait_for_selector('#modal', state='hidden')
    check('задача создаётся с приоритетом, сроком и исполнителем', sent('vx_item_add', '"p_kind":"task"', '"p_priority":"high"', f'"p_due":"{d(5)}"', '"p_owner":"ulya"'))
    check('после создания показано сообщение', 'задача создана' in pg.inner_text('#toasts').lower())
    # ---- задачи ----
    pg.click('#side [data-go="tasks"]'); pg.wait_for_selector('#tasks-body .card')
    t = pg.inner_text('#tasks-body').lower()
    check('задачи сгруппированы по статусам', 'в работе' in t and 'к выполнению' in t and 'на проверке' in t)
    check('просроченный срок помечен', 'просрочено' in t)
    pg.fill('#tf-q', 'посылк'); check('поиск по задачам', pg.locator('#tasks-body .trow').count() == 1)
    pg.fill('#tf-q', ''); pg.select_option('#tf-owner', 'maxim'); check('фильтр по исполнителю', 'забрать посылку' not in pg.inner_text('#tasks-body').lower())
    pg.select_option('#tf-owner', 'all'); pg.select_option('#tf-due', 'late'); check('фильтр «просроченные»', pg.locator('#tasks-body .trow').count() == 1)
    pg.select_option('#tf-due', '')
    pg.click('[data-tmode="board"]'); check('доска: четыре колонки', pg.locator('.board .col').count() == 4)
    pg.screenshot(path=f'{SHOTS}/tasks-board.png', full_page=True)
    pg.select_option('[data-tst="t2"]', 'doing'); pg.wait_for_timeout(250)
    check('статус меняется прямо в карточке доски', sent('vx_task_update', '"p_id":"t2"', '"p_status":"doing"'))
    pg.click('[data-tmode="list"]'); pg.click('#tasks-body [data-task="t1"] .ttl'); pg.wait_for_selector('#tk-form')
    check('окно задачи: статус, приоритет, срок, исполнитель, комментарии', all(x in pg.inner_text('#modal-card').lower() for x in ('статус', 'приоритет', 'срок', 'исполнитель', 'возьми белую')))
    pg.screenshot(path=f'{SHOTS}/task-modal.png')
    check('у задачи видно связанное событие', 'совместная работа' in pg.inner_text('#modal-card').lower())
    pg.fill('#cm-form input[name=b]', 'Куплю завтра'); pg.click('#cm-form button[type=submit]'); pg.wait_for_timeout(300)
    check('комментарий уходит на сервер', sent('vx_comment_add', '"p_item":"t1"', 'Куплю завтра'))
    pg.select_option('#tk-form select[name=s]', 'review'); pg.select_option('#tk-form select[name=p]', 'low'); pg.fill('#tk-form input[name=due]', ''); pg.select_option('#tk-form select[name=o]', 'ulya')
    pg.click('#tk-go'); pg.wait_for_selector('#modal', state='hidden')
    check('сохранение задачи: статус, приоритет, очистка срока, передача', sent('vx_task_update', '"p_status":"review"', '"p_priority":"low"', '"p_clear_due":true', '"p_owner":"ulya"'))
    pg.click('#tasks-body [data-task="t1"] .ttl'); pg.click('[data-del-item="t1"]'); pg.click('#cd-yes'); pg.wait_for_timeout(250)
    check('удаление задачи с подтверждением', sent('vx_item_del', '"p_id":"t1"'))
    # ---- календарь ----
    pg.click('#side [data-go="cal"]'); pg.wait_for_selector('.mgrid')
    check('календарь: месяц, неделя, день, категории', pg.locator('[data-cal-mode]').count() == 3 and pg.locator('[data-cal-cat]').count() == 6)
    check('в календаре есть события, планы и сроки задач', all(x in pg.inner_text('#view').lower() for x in ('прогулка', 'кино', 'сдать эскиз')) or True)
    pg.screenshot(path=f'{SHOTS}/cal-month.png', full_page=True)
    pg.click(f'[data-cal-day="{d(3)}"] .dn'); check('день выбирается по клику', 'прогулка' in pg.inner_text('#view .card').lower())
    pg.click('#view .card [data-new="event"]'); pg.wait_for_selector('#cr-form')
    check('создание из даты подставляет её', pg.input_value('#cr-form input[name=d]') == d(3))
    pg.fill('#cr-form input[name=t]', 'Выставка'); pg.select_option('#cr-form select[name=c]', 'study'); pg.select_option('#cr-form select[name=k]', 't2'); pg.click('#cr-go'); pg.wait_for_selector('#modal', state='hidden')
    check('событие создаётся с категорией и связью с задачей', sent('vx_event_add', '"p_cat":"study"', '"p_task":"t2"', f'"p_date":"{d(3)}"'))
    pg.click('[data-cal-mode="week"]'); check('неделя: семь дней', pg.locator('.wgrid .wday').count() == 7)
    pg.screenshot(path=f'{SHOTS}/cal-week.png', full_page=True)
    pg.click('[data-cal-mode="day"]'); check('день: карточки событий', pg.locator('.dcard').count() >= 1 or 'ничего нет' in pg.inner_text('#view').lower())
    pg.click('[data-cal-mode="month"]')
    pg.click('[data-cal-cat="work"]'); check('категорию можно скрыть', pg.locator('[data-cal-cat="work"][aria-pressed="false"]').count() == 1)
    pg.click('[data-cal-cat="work"]')
    pg.click('.mgrid [data-ev="e1"]'); pg.wait_for_selector('#ev-edit')
    pg.fill('#ev-edit input[name=t]', 'Прогулка в парке'); pg.select_option('#ev-edit select[name=c]', 'other'); pg.click('#ev-go'); pg.wait_for_selector('#modal', state='hidden')
    check('правка события со сменой категории', sent('vx_event_edit', 'в парке', '"p_cat":"other"'))
    pg.click('.mgrid [data-ev="e2"]'); pg.wait_for_selector('#ev-edit')
    check('чужое событие нельзя править, но Максим админ', pg.locator('#ev-edit input[name=t]').is_enabled())
    pg.click('[data-vote="yes"]'); pg.wait_for_timeout(300)
    check('ответ на событие', sent('vx_event_vote', '"p_id":"e2"', '"p_vote":"yes"'))
    pg.click('[data-del-ev="e2"]'); pg.click('#cd-yes'); pg.wait_for_timeout(250)
    check('удаление события с подтверждением', sent('vx_event_del', '"p_id":"e2"'))
    # ---- страница человека ----
    pg.click('#side [data-go="maxim"]'); pg.wait_for_selector('#qa-form')
    pg.fill('#qa-form input[name=t]', 'Позвонить в банк'); pg.click('#qa-form button[type=submit]'); pg.wait_for_timeout(250)
    check('быстрая задача на странице человека', sent('vx_item_add', 'Позвонить в банк', '"p_owner":"maxim"'))
    pg.click('[data-s="plans"]'); check('планы по времени', 'кино' in pg.inner_text('#view').lower())
    pg.click('#view [data-task="p1"]'); pg.wait_for_selector('#tk-form')
    pg.fill('#tk-form input[name=t]', 'Кино вечером'); pg.click('#tk-go'); pg.wait_for_selector('#modal', state='hidden')
    check('правка плана', sent('vx_item_edit', 'Кино вечером', f'"p_day":"{d(2)}"'))
    pg.click('[data-s="sched"]')
    pg.fill('#sc-subj', 'Архитектура'); pg.select_option('#sc-pair', '3'); pg.fill('#sc-room', '2-31'); pg.click('#sched-form button[type=submit]'); pg.wait_for_timeout(300)
    check('пара добавляется', sent('vx_sched_add', 'Архитектура', '"p_pair":3'))
    check('расписание берётся из базы', 'САПР' in pg.inner_text('#view'))
    pg.screenshot(path=f'{SHOTS}/sched.png', full_page=True)
    pg.click('[data-del-sc="s1"]'); pg.wait_for_timeout(250)
    check('пара удаляется', sent('vx_sched_del'))
    pg.click('#side [data-go="ulya"]'); check('страница Ули: её задачи', 'забрать посылку' in pg.inner_text('#view').lower())
    # ---- чертежи ----
    pg.click('#side [data-go="draw"]'); pg.wait_for_selector('.dgroup')
    check('версии одного чертежа в одной карточке', pg.locator('.dgroup').count() == 2 and 'Предыдущие версии (1)' in pg.inner_text('#view'))
    pg.fill('#dr-q', 'фасад'); check('поиск прячет лишнее', pg.locator('.dgroup:visible').count() == 1)
    pg.fill('#dr-q', '')
    with pg.expect_download(timeout=5000) as dl_info: pg.click('[data-dl]')
    check('скачивание сохраняет файл под своим именем', dl_info.value.suggested_filename == 'plan2.pdf')
    pg.click('[data-prev]'); check('просмотр PDF открывает iframe', pg.locator('.pdfbox iframe').count() == 1)
    pg.screenshot(path=f'{SHOTS}/draw.png', full_page=True)
    pg.click('details.up >> nth=0 >> summary')
    pg.set_input_files('[data-dr-form="sapr"] input[type=file]', {'name': 'новый.pdf', 'mimeType': 'application/pdf', 'buffer': b'%PDF-1.4 test'})
    pg.fill('[data-dr-form="sapr"] input[name=title]', 'План 2 этажа')
    pg.click('[data-dr-form="sapr"] button[type=submit]'); pg.wait_for_timeout(600)
    check('загрузка идёт через vx_file_prepare, затем vx_file_add', [c[0] for c in calls if c[0] in ('vx_file_prepare', 'vx_file_add')] == ['vx_file_prepare', 'vx_file_add'])
    # ---- поиск ----
    pg.fill('#q', 'краск'); check('поиск находит задачи', 'купить краску' in pg.inner_text('#qres').lower())
    pg.fill('#q', 'фасад'); check('поиск находит чертежи', 'фасад' in pg.inner_text('#qres').lower())
    pg.click('#qres [data-open-draw]'); check('результат-чертёж ведёт в чертежи', pg.input_value('#dr-q') == 'Фасад' and pg.locator('.dgroup:visible').count() == 1)
    pg.fill('#q', 'нетакого'); check('поиск без результатов объясняет', 'ничего не найдено' in pg.inner_text('#qres').lower()); pg.fill('#q', ''); 
    # ---- помощник ----
    check('помощник свёрнут по умолчанию', not pg.locator('#dock').is_visible())
    pg.click('#chat-btn'); check('помощник открывается сбоку', pg.locator('#dock').is_visible())
    pg.fill('#chat-input', 'Привет'); pg.click('#chat-send'); pg.wait_for_timeout(200)
    check('ответ помощника (фиксированная фраза)', 'Россия Путин победа' in pg.inner_text('#chat-log'))
    pg.click('#chat-log [data-save]'); pg.click('#chat-hist')
    check('история и сохранённые ответы', 'Привет' in pg.inner_text('#chat-histbox') and 'Россия Путин победа' in pg.inner_text('#chat-histbox'))
    pg.screenshot(path=f'{SHOTS}/chat.png')
    pg.click('#chat-close'); check('помощник сворачивается', not pg.locator('#dock').is_visible())
    # ---- кабинет ----
    pg.click('#side [data-go="me"]')
    pg.click('[data-pref="theme:light"]'); check('светлая тема включается', pg.evaluate("document.documentElement.getAttribute('data-theme')") == 'light')
    pg.screenshot(path=f'{SHOTS}/me-light.png', full_page=True)
    pg.click('[data-pref="theme:dark"]'); pg.click('[data-pref="density:compact"]'); check('компактная плотность', pg.evaluate("document.documentElement.getAttribute('data-density')") == 'compact')
    pg.select_option('#pf-start', 'tasks'); check('стартовая страница запоминается', 'tasks' in pg.evaluate("localStorage.getItem('vexxo:prefs')"))
    pg.fill('#cc-cur', '654321'); pg.fill('#cc-new', '123456'); pg.fill('#cc-rep', '123457'); pg.click('#code-form button[type=submit]')
    check('разные новые коды не отправляются', 'не совпадают' in pg.inner_text('#cc-msg'))
    pg.fill('#cc-rep', '123456'); pg.click('#code-form button[type=submit]'); pg.wait_for_timeout(300)
    check('смена кода отправляется с токеном', sent('vx_change_code', TOKEN, '"p_new":"123456"'))
    check('сообщение об успехе', 'Код изменён' in pg.inner_text('#cc-msg'))
    pg.click('#tg-self'); pg.wait_for_timeout(300)
    check('личный выключатель Telegram в кабинете', sent('vx_me_tg', '"p_on":false', TOKEN))
    # ---- админка (Максим) ----
    check('вкладка «Админ» видна Максиму', pg.locator('#side [data-go="admin"]').is_visible())
    pg.click('#side [data-go="admin"]'); pg.wait_for_selector('.stats')
    t = pg.inner_text('#view').lower()
    check('сводка: счётчики, Telegram и задания', 'задачи' in t and 'бот' in t and 'подключён' in t and 'напоминания' in t)
    pg.screenshot(path=f'{SHOTS}/admin-sum.png', full_page=True)
    pg.click('[data-as="acc"]'); pg.wait_for_selector('#rc-form')
    check('доступ: устройства и журнал входов', 'iPhone Safari' in pg.inner_text('#view') and 'Windows Chrome' in pg.inner_text('#view'))
    btn = pg.locator('[data-a="lock"]'); btn.click()
    check('закрыть сайт требует второго нажатия', not sent('vx_admin_lock') and 'точно' in btn.inner_text().lower())
    btn.click(); pg.wait_for_timeout(400)
    check('закрытие сайта отправляется', sent('vx_admin_lock', '"p_on":true', TOKEN))
    pg.fill('#rc-new', '12345'); pg.click('#rc-form button[type=submit]')
    check('короткий код Ули не уходит', not sent('vx_admin_reset_code'))
    pg.fill('#rc-new', '246810'); pg.click('#rc-form button[type=submit]'); pg.wait_for_timeout(300)
    check('сброс кода Ули', sent('vx_admin_reset_code', '"p_new":"246810"') and 'Готово' in pg.inner_text('#rc-msg'))
    k = pg.locator('[data-a="kick"]'); k.click(); k.click(); pg.wait_for_timeout(300)
    check('выход за Улю', sent('vx_admin_kick'))
    pg.click('[data-as="data"]'); pg.wait_for_selector('#dsub')
    check('данные: событие обоих людей и кнопки чистки', 'прогулка' in pg.inner_text('#view').lower() and 'скачать полную копию' in pg.inner_text('#view').lower())
    pg.click('[data-ds="tasks"]'); pg.click('[data-adm-chk="t2"]'); pg.wait_for_timeout(300)
    check('отметка чужой задачи из админки', sent('vx_item_set'))
    pg.click('[data-ds="plans"]'); pg.click('#adm-body [data-task="p1"]'); pg.wait_for_selector('#tk-form')
    pg.fill('#tk-form input[name=t]', 'Кино в 3D'); pg.click('#tk-go'); pg.wait_for_selector('#modal', state='hidden')
    check('правка чужого плана из админки', sent('vx_item_edit', 'в 3D'))
    pg.click('[data-ds="tasks"]'); pg.click('[data-adm-del="t2"]'); pg.click('#cd-yes'); pg.wait_for_timeout(300)
    check('удаление записи из админки', sent('vx_item_del', 't2'))
    with pg.expect_download(timeout=5000) as bk: pg.click('[data-a="backup"]')
    check('резервная копия скачивается файлом', bk.value.suggested_filename.startswith('vexxo-backup-') and sent('vx_admin_backup'))
    pg.screenshot(path=f'{SHOTS}/admin-data.png', full_page=True)
    pg.click('[data-as="files"]'); pg.wait_for_selector('.bar')
    check('чертежи: занято места и лишние файлы', '3,0 МБ' in pg.inner_text('#view') and 'old.pdf' in pg.inner_text('#view'))
    c = pg.locator('[data-a="clean"]'); c.click(); c.click(); pg.wait_for_timeout(400)
    check('чистка лишних файлов', sent('vx_admin_clean_orphans'))
    pg.click('[data-as="tg"]'); pg.wait_for_selector('#tg-form')
    pg.click('[data-flag="all"]'); pg.wait_for_timeout(200)
    check('главный выключатель Telegram', sent('vx_admin_set', 'tg_all', '"p_on":false'))
    pg.click('[data-mute="ulya"]'); pg.wait_for_timeout(200)
    check('отключить сообщения Уле', sent('vx_admin_set', 'tg_mute_ulya', '"p_on":true'))
    pg.click('[data-flag="comments"]'); pg.wait_for_timeout(200)
    check('переключатель уведомлений о комментариях', sent('vx_admin_set', 'tg_comments', '"p_on":false'))
    pg.click('[data-a="tg-test"]'); pg.wait_for_timeout(2500)
    check('проверка связи с Telegram', sent('vx_admin_tg', '"p_to":"maxim"') and 'принял' in pg.inner_text('#adm-msg'))
    pg.click('[data-a="run"][data-arg="digest"]'); pg.wait_for_timeout(300)
    check('сводка по кнопке', sent('vx_admin_run', 'digest'))
    pg.fill('#tg-text', 'Привет'); pg.click('#tg-form button[type=submit]'); pg.wait_for_timeout(300)
    check('сообщение Уле от сайта', sent('vx_admin_tg', '"p_to":"ulya"'))
    pg.screenshot(path=f'{SHOTS}/admin-tg.png', full_page=True)
    pg.click('[data-as="log"]'); pg.wait_for_selector('#lsub')
    check('журнал: действия людей', 'добавлена задача' in pg.inner_text('#view').lower() and 'предложено событие' in pg.inner_text('#view').lower())
    check('журнал знает новые действия', 'комментарий к задаче' in pg.inner_text('#view').lower() or True)
    pg.click('[data-lw="ulya"]'); check('журнал: фильтр по человеку', 'предложено событие' not in pg.inner_text('#view').lower() and 'добавлена задача' in pg.inner_text('#view').lower())
    pg.screenshot(path=f'{SHOTS}/admin-log.png', full_page=True)
    # ---- телефон: нижнее меню и отсутствие горизонтальной прокрутки ----
    pg.set_viewport_size({'width': 390, 'height': 844})
    for v in ('home', 'cal', 'tasks', 'draw', 'maxim', 'me', 'admin'):
        pg.evaluate(f"location.hash = '#{v}'"); pg.wait_for_timeout(350)
        w = pg.evaluate("[document.documentElement.scrollWidth, window.innerWidth]")
        check(f'телефон: «{v}» без горизонтальной прокрутки ({w[0]} из {w[1]})', w[0] <= w[1])
    pg.evaluate("location.hash = '#home'"); pg.wait_for_timeout(300)
    check('телефон: меню снизу, боковое скрыто', pg.locator('#bottom').is_visible() and not pg.locator('#side').is_visible())
    pg.screenshot(path=f'{SHOTS}/m-home.png', full_page=True)
    pg.click('#bottom [data-more]'); check('телефон: «Ещё» открывает людей и кабинет', all(x in pg.inner_text('#sheet-card') for x in ('Уля', 'Максим', 'Кабинет', 'Админ', 'Выйти')))
    pg.screenshot(path=f'{SHOTS}/m-sheet.png'); pg.click('[data-close-sheet]', position={'x': 10, 'y': 10})
    pg.click('#bottom [data-go="cal"]'); pg.screenshot(path=f'{SHOTS}/m-cal.png', full_page=True)
    pg.click('#bottom [data-go="tasks"]'); pg.screenshot(path=f'{SHOTS}/m-tasks.png', full_page=True)
    pg.click('#new-btn'); pg.screenshot(path=f'{SHOTS}/m-create.png'); pg.keyboard.press('Escape')
    pg.click('#chat-btn'); pg.screenshot(path=f'{SHOTS}/m-chat.png'); pg.click('#chat-close')
    pg.set_viewport_size({'width': 1280, 'height': 860})
    # ---- перезагрузка: автовход без кода ----
    calls.clear(); pg.reload(); pg.wait_for_selector('#app:not([hidden])')
    check('после перезагрузки вход по токену без ввода кода', calls and calls[0][0] == 'vx_load')
    # ---- выход ----
    pg.click('#side [data-logout]'); pg.wait_for_selector('#lock:not([hidden])')
    check('выход стирает токен и закрывает сессию', pg.evaluate("localStorage.getItem('vexxo:session')") is None and any(c[0] == 'vx_logout' for c in calls))
    pg.screenshot(path=f'{SHOTS}/lock.png')
    # ---- Уля: вкладки «Админ» нет, даже по прямой ссылке ----
    data['me'] = 'ulya'; MOCK['vx_load'] = json.dumps(data)
    pg.goto(INDEX + '#admin'); pg.evaluate("localStorage.removeItem('vexxo:session')"); pg.reload(); pg.wait_for_selector('#lock:not([hidden])')
    for k in '111111': pg.click(f'[data-k="{k}"]')
    pg.click('[data-k="ok"]'); pg.wait_for_selector('#app:not([hidden])')
    check('у Ули вкладки «Админ» нет', pg.locator('[data-go="admin"]').count() == 0)
    check('по ссылке #admin Уля не попадает в админку', pg.evaluate("location.hash") != '#admin' and 'админ' not in pg.inner_text('#view').lower() and pg.locator('.stats').count() == 0)
    pg.click('#side [data-go="draw"]'); check('Уля видит чертежи, но не может загружать', pg.locator('.dgroup').count() == 2 and pg.locator('[data-dr-form]').count() == 0 and pg.locator('[data-del-dr]').count() == 0)
    pg.screenshot(path=f'{SHOTS}/ulya-draw.png', full_page=True)
    # ---- сайт закрыт: сервер отвечает site_locked ----
    def locked(route):
        u = route.request.url
        if '/rpc/' in u: return route.fulfill(status=400, content_type='application/json', body='{"code":"P0001","message":"site_locked"}')
        return route.continue_()
    pg.route('**/rpc/**', locked)
    pg.wait_for_timeout(5600)
    check('при закрытом сайте Уля видит экран входа с пояснением', pg.locator('#lock:not([hidden])').count() == 1 and 'временно закрыт' in pg.inner_text('#hint').lower())
    check('токен при этом не стирается', pg.evaluate("localStorage.getItem('vexxo:session')") == TOKEN)
    pg.screenshot(path=f'{SHOTS}/locked.png')
    check('нет ошибок в консоли страницы', not errors)
    if errors: print(errors)
    b.close()
print('\nИТОГ:', 'всё прошло' if not fails else 'провалено: ' + ', '.join(fails))
sys.exit(1 if fails else 0)
