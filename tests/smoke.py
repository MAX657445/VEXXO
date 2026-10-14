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
            res = {'vx_session_start': json.dumps(TOKEN), 'vx_load': json.dumps(data), 'vx_change_code': '"ok"', 'vx_file_prepare': '"44444444-4444-4444-4444-444444444444/new.pdf"'}.get(fn)
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
    pg.screenshot(path=f'{SHOTS}/me.png', full_page=True)
    # перезагрузка: автовход без кода
    calls.clear(); pg.reload(); pg.wait_for_selector('#app:not([hidden])')
    check('после перезагрузки вход по токену без ввода кода', calls and calls[0][0] == 'vx_load')
    # выход
    pg.click('#exit'); pg.wait_for_selector('#lock:not([hidden])')
    check('выход стирает токен и закрывает сессию', pg.evaluate("localStorage.getItem('vexxo:session')") is None and any(c[0] == 'vx_logout' for c in calls))
    pg.screenshot(path=f'{SHOTS}/lock.png')
    check('нет ошибок в консоли страницы', not errors)
    if errors: print(errors)
    b.close()
print('\nИТОГ:', 'всё прошло' if not fails else 'провалено: ' + ', '.join(fails))
sys.exit(1 if fails else 0)
