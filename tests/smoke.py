"""Дымовой тест интерфейса: сервер Supabase подменяется заглушкой, проверяются основные сценарии.
Запуск: python3 tests/smoke.py (нужен playwright). Скриншоты кладутся в SHOTS (по умолчанию /tmp/vexxo-shots)."""
import json, os, sys
from playwright.sync_api import sync_playwright

SHOTS = os.environ.get('SHOTS', '/tmp/vexxo-shots'); os.makedirs(SHOTS, exist_ok=True)
INDEX = 'file://' + os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'index.html'))
TOKEN = 'a' * 64
data = {
  "me": "maxim",
  "events": [{"id": "e1", "title": "Прогулка", "date": "2026-10-21", "time": "18:00:00", "by": "maxim", "votes": {"maxim": "yes"}}],
  "items": [
    {"id": "p1", "kind": "plan", "owner": "maxim", "text": "Кино", "when": "", "done": False, "date": "2026-10-20", "time": "19:30:00", "by": "ulya"},
    {"id": "t1", "kind": "task", "owner": "maxim", "text": "Купить краску", "when": "", "done": False, "date": None, "time": None, "by": "maxim"}],
  "files": [
    {"id": "f1", "project": "sapr", "title": "План 1 этажа", "date": "2026-10-10", "note": "первая", "path": "11111111-1111-1111-1111-111111111111/plan.pdf", "filename": "plan.pdf"},
    {"id": "f2", "project": "sapr", "title": "План 1 этажа", "date": "2026-10-14", "note": "правка 2", "path": "22222222-2222-2222-2222-222222222222/plan2.pdf", "filename": "plan2.pdf"},
    {"id": "f3", "project": "arch", "title": "Фасад", "date": "2026-10-12", "note": "", "path": "33333333-3333-3333-3333-333333333333/facade.png", "filename": "facade.png"}],
  "schedule": [{"id": "s1", "owner": "maxim", "date": "2026-10-14", "pair": 2, "subject": "САПР", "room": "1-28"}],
  "trash": []
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

with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page(viewport={'width': 390, 'height': 844})
    errors = []; pg.on('pageerror', lambda e: errors.append(str(e)))
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
    # вход: 6-значный код, кнопка ОК
    for k in '654321': pg.click(f'[data-k="{k}"]')
    check('точки растут по мере ввода', pg.locator('#dots i.on').count() == 6)
    pg.click('[data-k="ok"]'); pg.wait_for_selector('#app:not([hidden])')
    check('вход по коду выдаёт сессию', any(c[0] == 'vx_session_start' and '654321' in c[1] for c in calls))
    check('дальше сайт ходит с токеном, а не с кодом', all('654321' not in (c[1] or '') for c in calls if c[0] != 'vx_session_start') and any(TOKEN in (c[1] or '') for c in calls if c[0] == 'vx_load'))
    check('при входе передаётся название устройства', any(c[0] == 'vx_session_start' and '"p_device":"' in c[1] and 'p_device":""' not in c[1] for c in calls))
    check('токен сохранён на устройстве', pg.evaluate("localStorage.getItem('vexxo:session')") == TOKEN)
    check('кнопки Claude про идеи нет', pg.locator('#ask-idea').count() == 0)
    check('в календаре есть план с личной страницы', 'кино' in pg.inner_text('#view').lower())
    pg.screenshot(path=f'{SHOTS}/cal.png', full_page=True)
    # правка события
    pg.click('[data-edit="e1"]'); pg.fill('[data-edit-form="event"] input[name="t"]', 'Прогулка в парке'); pg.click('[data-edit-form="event"] button[type=submit]')
    pg.wait_for_timeout(300)
    check('правка события уходит на сервер', any(c[0] == 'vx_event_edit' and 'в парке' in c[1] for c in calls))
    # личная страница: расписание
    pg.click('[data-v="maxim"]'); pg.click('[data-s="sched"]')
    pg.fill('#sc-subj', 'Архитектура'); pg.select_option('#sc-pair', '3'); pg.fill('#sc-room', '2-31'); pg.click('#sched-form button[type=submit]'); pg.wait_for_timeout(300)
    check('пара добавляется', any(c[0] == 'vx_sched_add' and 'Архитектура' in c[1] and '"p_pair":3' in c[1] for c in calls))
    check('расписание берётся из базы', 'САПР' in pg.inner_text('#view'))
    pg.screenshot(path=f'{SHOTS}/sched.png', full_page=True)
    pg.click('[data-del-sc="s1"]'); pg.wait_for_timeout(200)
    check('пара удаляется', any(c[0] == 'vx_sched_del' for c in calls))
    # доска: правка задачи
    pg.click('[data-s="tasks"]'); pg.click('[data-edit="t1"]'); pg.fill('[data-edit-form="item"] input[name="t"]', 'Купить краску и бумагу'); pg.click('[data-edit-form="item"] button[type=submit]'); pg.wait_for_timeout(200)
    check('правка задачи', any(c[0] == 'vx_item_edit' and 'бумагу' in c[1] and '"p_day":null' in c[1] for c in calls))
    # чертежи
    pg.click('[data-s="draw"]')
    check('версии одного чертежа в одной карточке', pg.locator('.dgroup').count() == 2 and 'Предыдущие версии (1)' in pg.inner_text('#view'))
    pg.fill('#dr-q', 'фасад'); check('поиск прячет лишнее', pg.locator('.dgroup:visible').count() == 1)
    pg.fill('#dr-q', '')
    with pg.expect_download(timeout=5000) as dl_info: pg.click('[data-dl]')
    check('скачивание сохраняет файл под своим именем', dl_info.value.suggested_filename == 'plan2.pdf')
    pg.click('[data-prev]'); check('просмотр PDF открывает iframe', pg.locator('.pdfbox iframe').count() == 1)
    pg.screenshot(path=f'{SHOTS}/draw.png', full_page=True)
    pg.set_input_files('[data-dr-form="sapr"] input[type=file]', {'name': 'новый.pdf', 'mimeType': 'application/pdf', 'buffer': b'%PDF-1.4 test'})
    pg.fill('[data-dr-form="sapr"] input[name=title]', 'План 2 этажа')
    sb = pg.locator('[data-dr-form="sapr"] button[type=submit]'); sb.scroll_into_view_if_needed(); pg.wait_for_timeout(200); sb.click(); pg.wait_for_timeout(600)
    check('загрузка идёт через vx_file_prepare, затем vx_file_add', [c[0] for c in calls if c[0] in ('vx_file_prepare', 'vx_file_add')] == ['vx_file_prepare', 'vx_file_add'])
    # кабинет
    pg.click('[data-v="me"]')
    pg.fill('#cc-cur', '654321'); pg.fill('#cc-new', '123456'); pg.fill('#cc-rep', '123457'); pg.click('#code-form button[type=submit]')
    check('разные новые коды не отправляются', 'не совпадают' in pg.inner_text('#cc-msg'))
    pg.fill('#cc-rep', '123456'); pg.click('#code-form button[type=submit]'); pg.wait_for_timeout(300)
    check('смена кода отправляется с токеном', any(c[0] == 'vx_change_code' and TOKEN in c[1] and '"p_new":"123456"' in c[1] for c in calls))
    check('сообщение об успехе', 'Код изменён' in pg.inner_text('#cc-msg'))
    pg.click('#tg-self'); pg.wait_for_timeout(300)
    check('личный выключатель Telegram в кабинете', any(c[0] == 'vx_me_tg' and '"p_on":false' in c[1] and TOKEN in c[1] for c in calls))
    pg.screenshot(path=f'{SHOTS}/me.png', full_page=True)
    # админка (Максим)
    check('вкладка «Админ» видна Максиму', pg.locator('[data-v="admin"]').is_visible())
    pg.click('[data-v="admin"]'); pg.wait_for_selector('.stats')
    t = pg.inner_text('#view').lower()
    check('сводка: счётчики, Telegram и задания', 'задачи' in t and 'бот' in t and 'подключён' in t and 'напоминания' in t)
    pg.screenshot(path=f'{SHOTS}/admin-sum.png', full_page=True)
    pg.click('[data-as="acc"]'); pg.wait_for_selector('#rc-form')
    check('доступ: устройства и журнал входов', 'iPhone Safari' in pg.inner_text('#view') and 'Windows Chrome' in pg.inner_text('#view'))
    btn = pg.locator('[data-a="lock"]'); btn.click()
    check('закрыть сайт требует второго нажатия', not any(c[0] == 'vx_admin_lock' for c in calls) and 'точно' in btn.inner_text().lower())
    btn.click(); pg.wait_for_timeout(400)
    check('закрытие сайта отправляется', any(c[0] == 'vx_admin_lock' and '"p_on":true' in c[1] and TOKEN in c[1] for c in calls))
    pg.fill('#rc-new', '12345'); pg.click('#rc-form button[type=submit]')
    check('короткий код Ули не уходит', not any(c[0] == 'vx_admin_reset_code' for c in calls))
    pg.fill('#rc-new', '246810'); pg.click('#rc-form button[type=submit]'); pg.wait_for_timeout(300)
    check('сброс кода Ули', any(c[0] == 'vx_admin_reset_code' and '"p_new":"246810"' in c[1] for c in calls) and 'Готово' in pg.inner_text('#rc-msg'))
    k = pg.locator('[data-a="kick"]'); k.click(); k.click(); pg.wait_for_timeout(300)
    check('выход за Улю', any(c[0] == 'vx_admin_kick' for c in calls))
    pg.screenshot(path=f'{SHOTS}/admin-acc.png', full_page=True)
    pg.click('[data-as="data"]'); pg.wait_for_selector('#dsub')
    check('данные: событие обоих людей и кнопки чистки', 'прогулка' in pg.inner_text('#view').lower() and 'скачать полную копию' in pg.inner_text('#view').lower())
    pg.click('[data-ds="tasks"]'); pg.click('[data-adm-chk="t1"]'); pg.wait_for_timeout(300)
    check('отметка чужой задачи из админки', any(c[0] == 'vx_item_set' for c in calls))
    pg.click('[data-ds="plans"]'); pg.click('[data-edit="p1"]'); pg.fill('[data-edit-form="item"] input[name="t"]', 'Кино в 3D'); pg.click('[data-edit-form="item"] button[type=submit]'); pg.wait_for_timeout(300)
    check('правка чужого плана из админки', any(c[0] == 'vx_item_edit' and 'в 3D' in c[1] for c in calls))
    pg.click('[data-ds="tasks"]'); pg.click('[data-adm-del="t1"]'); pg.wait_for_timeout(300)
    check('удаление записи из админки', any(c[0] == 'vx_item_del' and 't1' in c[1] for c in calls))
    with pg.expect_download(timeout=5000) as bk: pg.click('[data-a="backup"]')
    check('резервная копия скачивается файлом', bk.value.suggested_filename.startswith('vexxo-backup-') and any(c[0] == 'vx_admin_backup' for c in calls))
    pg.screenshot(path=f'{SHOTS}/admin-data.png', full_page=True)
    pg.click('[data-as="files"]'); pg.wait_for_selector('.bar')
    check('чертежи: занято места и лишние файлы', '3,0 МБ' in pg.inner_text('#view') and 'old.pdf' in pg.inner_text('#view'))
    c = pg.locator('[data-a="clean"]'); c.click(); c.click(); pg.wait_for_timeout(400)
    check('чистка лишних файлов', any(x[0] == 'vx_admin_clean_orphans' for x in calls))
    pg.screenshot(path=f'{SHOTS}/admin-files.png', full_page=True)
    pg.click('[data-as="tg"]'); pg.wait_for_selector('#tg-form')
    pg.click('[data-flag="all"]'); pg.wait_for_timeout(200)
    check('главный выключатель Telegram', any(c[0] == 'vx_admin_set' and 'tg_all' in c[1] and '"p_on":false' in c[1] for c in calls))
    pg.click('[data-mute="ulya"]'); pg.wait_for_timeout(200)
    check('отключить сообщения Уле', any(c[0] == 'vx_admin_set' and 'tg_mute_ulya' in c[1] and '"p_on":true' in c[1] for c in calls))
    pg.click('[data-flag="events"]'); pg.wait_for_timeout(200)
    check('переключатель уведомлений', any(c[0] == 'vx_admin_set' and 'tg_events' in c[1] and '"p_on":false' in c[1] for c in calls))
    pg.click('[data-a="tg-test"]'); pg.wait_for_timeout(2500)
    check('проверка связи с Telegram', any(c[0] == 'vx_admin_tg' and '"p_to":"maxim"' in c[1] for c in calls) and 'принял' in pg.inner_text('#adm-msg'))
    pg.click('[data-a="run"][data-arg="digest"]'); pg.wait_for_timeout(300)
    check('сводка по кнопке', any(c[0] == 'vx_admin_run' and 'digest' in c[1] for c in calls))
    pg.fill('#tg-text', 'Привет'); pg.click('#tg-form button[type=submit]'); pg.wait_for_timeout(300)
    check('сообщение Уле от сайта', any(c[0] == 'vx_admin_tg' and '"p_to":"ulya"' in c[1] for c in calls))
    pg.screenshot(path=f'{SHOTS}/admin-tg.png', full_page=True)
    pg.click('[data-as="log"]'); pg.wait_for_selector('#lsub')
    check('журнал: действия людей', 'добавлена задача' in pg.inner_text('#view').lower() and 'предложено событие' in pg.inner_text('#view').lower())
    pg.click('[data-lw="ulya"]'); check('журнал: фильтр по человеку', 'предложено событие' not in pg.inner_text('#view').lower() and 'добавлена задача' in pg.inner_text('#view').lower())
    pg.screenshot(path=f'{SHOTS}/admin-log.png', full_page=True)
    # перезагрузка: автовход без кода
    calls.clear(); pg.reload(); pg.wait_for_selector('#app:not([hidden])')
    check('после перезагрузки вход по токену без ввода кода', calls and calls[0][0] == 'vx_load')
    # выход
    pg.click('#exit'); pg.wait_for_selector('#lock:not([hidden])')
    check('выход стирает токен и закрывает сессию', pg.evaluate("localStorage.getItem('vexxo:session')") is None and any(c[0] == 'vx_logout' for c in calls))
    pg.screenshot(path=f'{SHOTS}/lock.png')
    # Уля: вкладки «Админ» нет, даже по прямой ссылке
    data['me'] = 'ulya'; MOCK['vx_load'] = json.dumps(data)
    pg.goto(INDEX + '#admin'); pg.evaluate("localStorage.removeItem('vexxo:session')"); pg.reload(); pg.wait_for_selector('#lock:not([hidden])')
    for k in '111111': pg.click(f'[data-k="{k}"]')
    pg.click('[data-k="ok"]'); pg.wait_for_selector('#app:not([hidden])')
    check('у Ули вкладки «Админ» нет', not pg.locator('[data-v="admin"]').is_visible())
    check('по ссылке #admin Уля попадает в календарь', 'общий календарь' in pg.inner_text('#view').lower())
    # сайт закрыт: сервер отвечает site_locked
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
