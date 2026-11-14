// Проверка «просмотрено»: после подтверждения завершённая сессия уходит с карточки,
// а новый ход в ней снова делает её видимой.
// Запуск: node tools/test-ack.js
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const zlib = require('node:zlib')
const http = require('node:http')
const { spawn } = require('node:child_process')

const here = __dirname
const enginePath = path.join(here, '..', 'widget-engine.js')
const home = path.join(here, '..', '.test-ack')
const projectDir = path.join(home, 'sessions', '--test--')
const PORT = 45970

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function append(dir, records) {
  const d = path.join(projectDir, dir)
  fs.mkdirSync(d, { recursive: true })
  const file = path.join(d, 'session.v4.jsonl.zstd')
  fs.appendFileSync(file, Buffer.concat(records.map((r) => zlib.zstdCompressSync(Buffer.from(JSON.stringify(r) + '\n', 'utf8')))))
}

function req(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null
    const r = http.request(
      { host: '127.0.0.1', port: PORT, path: urlPath, method, headers: payload ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } : {} },
      (res) => {
        let s = ''
        res.on('data', (c) => (s += c))
        res.on('end', () => { try { resolve(JSON.parse(s)) } catch (e) { reject(e) } })
      }
    )
    r.on('error', reject)
    if (payload) r.write(payload)
    r.end()
  })
}

const status = () => req('GET', '/status')

async function waitFor(pred, ms, label) {
  const until = Date.now() + ms
  let last = null
  while (Date.now() < until) {
    try {
      last = await status()
      if (pred(last)) return last
    } catch { /* старт */ }
    await sleep(200)
  }
  throw new Error('таймаут: ' + label + '; ' + JSON.stringify(last && last.primary && last.primary.status))
}

let fails = 0
function check(ok, label) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${label}`)
  if (!ok) fails++
}

async function main() {
  fs.rmSync(home, { recursive: true, force: true })
  const now = Date.now()

  append('session-ack', [
    { type: 'session', version: 4, id: 'ack-test', createdAt: now - 60000, cwd: 'C:\\t', delegationDepth: 0 },
    { type: 'session/title', seq: 1, time: now - 59000, data: { title: 'Задача для проверки' } },
    { type: 'turn/start', seq: 2, time: now - 8000, data: { turn: 1 } },
    { type: 'assistant/message', seq: 3, time: now - 2000, data: { turn: 1, step: 1, message: { role: 'assistant', content: [{ type: 'text', text: 'Готово.' }] } } },
    { type: 'turn/end', seq: 4, time: now - 1000, data: { turn: 1, reason: { kind: 'completed' } } },
  ])

  const engine = spawn(process.execPath, [enginePath, '--port', String(PORT)], {
    env: { ...process.env, DSH_HOME: home },
    stdio: 'ignore',
    windowsHide: true,
  })

  try {
    const done = await waitFor((s) => s.primary && s.primary.status === 'done', 8000, 'ожидалось done')
    check(done.primary.status === 'done', 'сразу после завершения сессия показана как «Готово»')

    await req('POST', '/ack', { id: 'ack-test' })
    const acked = await waitFor((s) => !s.primary || s.primary.status !== 'done', 8000, 'после ack не должно быть done')
    check(!acked.primary || acked.primary.status === 'idle', 'после просмотра сессия ушла с карточки (idle)')

    // новый ход в той же сессии — снова видима
    append('session-ack', [
      { type: 'turn/start', seq: 5, time: Date.now(), data: { turn: 2 } },
      { type: 'step/start', seq: 6, time: Date.now(), data: { turn: 2, step: 1 } },
    ])
    const working = await waitFor((s) => s.primary && s.primary.id === 'ack-test' && s.primary.status === 'working', 8000, 'новый ход должен вернуть сессию')
    check(working.primary.status === 'working', 'новый ход снова показывает сессию в работе')

    append('session-ack', [
      { type: 'turn/end', seq: 7, time: Date.now(), data: { turn: 2, reason: { kind: 'completed' } } },
    ])
    const doneAgain = await waitFor((s) => s.primary && s.primary.status === 'done', 8000, 'второе завершение')
    check(doneAgain.primary.status === 'done', 'новое завершение снова показывается как «Готово» (ack сброшен)')
  } finally {
    engine.kill()
    await sleep(300)
    fs.rmSync(home, { recursive: true, force: true })
  }

  console.log(fails === 0 ? '\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' : `\nПРОВАЛЕНО: ${fails}`)
  process.exit(fails === 0 ? 0 : 1)
}

main().catch((e) => {
  console.error('Ошибка теста:', e.message)
  process.exit(1)
})
