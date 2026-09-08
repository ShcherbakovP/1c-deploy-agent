# -*- coding: utf-8 -*-
"""mcpq.py — вызов инструмента файлового MCP-транспорта (mcp-daemon.vbs) с рабочей станции.

Кладёт JSON-RPC в <папка обмена>/in, ждёт ответ из <папка обмена>/out, распаковывает
вложенный JSON и печатает результат. Полный ответ пишется в файл (консоль Windows
кириллицу часто бьёт — читайте файл).

  python mcpq.py <инструмент> <args.json> [таймаут, с]
  python mcpq.py execute_query q.json 180

args.json — UTF-8 с аргументами инструмента, например {"query": "ВЫБРАТЬ ..."}.
Папка обмена — переменная окружения MCP_EXCHANGE (та же, что mcpExchange в конфиге агента,
но глазами рабочей станции). Файл результата — MCP_LAST (по умолчанию mcp-last.json в текущем каталоге).
"""
import io, json, os, sys, time, uuid

ex = os.environ.get('MCP_EXCHANGE', '')
if not ex:
    print('Задайте MCP_EXCHANGE — путь к папке обмена MCP на рабочей станции.'); sys.exit(2)
if len(sys.argv) < 3:
    print(__doc__); sys.exit(2)
tool = sys.argv[1]
args = json.loads(io.open(sys.argv[2], encoding='utf-8-sig').read())
timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 90
last = os.environ.get('MCP_LAST', 'mcp-last.json')

body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}
name = uuid.uuid4().hex + '.json'
tmp = os.path.join(ex, 'in', name + '.tmp'); dst = os.path.join(ex, 'in', name)
io.open(tmp, 'w', encoding='utf-8').write(json.dumps(body, ensure_ascii=False))
os.rename(tmp, dst)

resp = os.path.join(ex, 'out', name)
deadline = time.time() + timeout
while time.time() < deadline and not os.path.exists(resp):
    time.sleep(0.3)
if not os.path.exists(resp):
    print('TIMEOUT'); sys.exit(2)
time.sleep(0.3)
txt = io.open(resp, encoding='utf-8-sig').read()
os.remove(resp)
d = json.loads(txt)
if 'error' in d:
    print('ERROR:', json.dumps(d['error'], ensure_ascii=False)); sys.exit(1)
inner = d['result']['content'][0]['text']
try:
    obj = json.loads(inner)
    if isinstance(obj, dict) and 'data' in obj and isinstance(obj['data'], str):
        obj['data'] = json.loads(obj['data'])
    out = json.dumps(obj, ensure_ascii=False, indent=1)
except Exception:
    out = inner
io.open(last, 'w', encoding='utf-8').write(out)
print(out[:6000])
