# VEXXO

Сайт на GitHub Pages (`index.html`).

## Чат с Claude

Кнопка «Спросить Claude» появляется на сайте, когда в `index.html` заполнена переменная `CHAT_API_URL`.
Ключ Claude API нельзя класть в код сайта, поэтому запросы идут через маленький Cloudflare Worker (`worker/worker.js`).

1. Получи ключ на console.anthropic.com (нужна оплата за запросы, обычно копейки за вопрос).
2. На dash.cloudflare.com создай Worker, вставь код из `worker/worker.js`.
3. В настройках Worker добавь:
   - секрет `ANTHROPIC_API_KEY` с ключом;
   - переменную `ALLOWED_ORIGIN` с адресом сайта, например `https://max657445.github.io`.
4. Скопируй адрес Worker (вида `https://vexxo-chat.<имя>.workers.dev`) в `CHAT_API_URL` в `index.html`.
