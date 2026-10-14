// Cloudflare Worker: прокси между сайтом и Claude API.
// Ключ хранится только здесь, как секрет ANTHROPIC_API_KEY, и никогда не попадает на сайт.
//
// Переменные окружения Worker:
//   ANTHROPIC_API_KEY  (секрет)  ключ из console.anthropic.com
//   ALLOWED_ORIGIN     (текст)   адрес сайта, например https://max657445.github.io

const MODEL = 'claude-sonnet-5-5';
const MAX_MESSAGES = 20;
const MAX_CHARS = 2000;
const SYSTEM = 'Ты Claude, помощник на сайте VEXXO. Отвечай по-русски (или на языке вопроса), коротко и по делу. Пиши простым текстом, без markdown-заголовков.';

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const allowed = env.ALLOWED_ORIGIN || '';
    const cors = {
      'Access-Control-Allow-Origin': allowed,
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Vary': 'Origin'
    };
    const json = (obj, status = 200) =>
      new Response(JSON.stringify(obj), { status, headers: { ...cors, 'Content-Type': 'application/json; charset=utf-8' } });

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
    if (!allowed || origin !== allowed) return json({ error: 'forbidden' }, 403);

    let body;
    try { body = await request.json(); } catch (e) { return json({ error: 'bad_json' }, 400); }

    const msgs = body && body.messages;
    const ok = Array.isArray(msgs) && msgs.length > 0 && msgs.length <= MAX_MESSAGES &&
      msgs.every(m => m && (m.role === 'user' || m.role === 'assistant') &&
        typeof m.content === 'string' && m.content.length > 0 && m.content.length <= MAX_CHARS) &&
      msgs[msgs.length - 1].role === 'user';
    if (!ok) return json({ error: 'bad_messages' }, 400);

    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': env.ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 700,
        system: SYSTEM,
        messages: msgs.map(m => ({ role: m.role, content: m.content }))
      })
    });
    if (!r.ok) return json({ error: 'upstream_' + r.status }, 502);
    const data = await r.json();
    const reply = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('');
    return json({ reply });
  }
};
