// Проверка выбора сессии: карточка не должна дёргаться между двумя работающими окнами.
// Поднимает движок на синтетическом DSH_HOME и проверяет «липкость» выбора и закрепление.
// Запуск: node tools/test-selection.js
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const zlib = require('node:zlib')
const http = require('node:http')
const { spawn } = require('node:child_process')

const here = __dirname
const enginePath = path.join(here, '..', 'widget-engine.js')
const home = path.join(here, '..', '.test-selection')
const projectDir = path.join(home, 'sessions', '--test--')
const PORT = 45903

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function append(dir, name, records) {
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
  throw new Error('таймаут: ' + label)
}

let fails = 0
function check(ok, label) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${label}`)
  if (!ok) fails++
}

async function main() {
  fs.rmSync(home, { recursive: true, force: true })
  const now = Date.now()

  append('session-A', 'A', [
    { type: 'session', version: 4, id: 'A', createdAt: now - 60000, cwd: 'C:\\a', delegationDepth: 0 },
    { type: 'session/title', seq: 1, time: now - 58000, data: { title: 'Окно A' } },
    { type: 'turn/start', seq: 2, time: now - 5000, data: { turn: 1 } },
    { type: 'step/start', seq: 3, time: now - 1000, data: { turn: 1, step: 1 } },
  ])
  append('session-B', 'B', [
    { type: 'session', version: 4, id: 'B', createdAt: now - 60000, cwd: 'C:\\b', delegationDepth: 0 },
    { type: 'session/title', seq: 1, time: now - 58000, data: { title: 'Окно B' } },
    { type: 'turn/start', seq: 2, time: now - 6000, data: { turn: 1 } },
  ])

  const engine = spawn(process.execPath, [enginePath, '--port', String(PORT)], {
    env: { ...process.env, DSH_HOME: home },
    stdio: 'ignore',
    windowsHide: true,
  })

  try {
    const first = await waitFor((s) => s.primary && s.primary.id === 'A', 8000, 'первичным должно быть окно A')
    check(first.primary.id === 'A', 'первичная сессия — самая свежая (A)')

    // Соседнее окно шумит: шлём события в B. Карточка не должна прыгнуть.
    for (let i = 0; i < 4; i++) {
      append('session-B', 'B', [{ type: 'step/start', seq: 10 + i, time: Date.now(), data: { turn: 1, step: 2 + i } }])
      await sleep(350)
      const s = await status()
      if (s.primary.id !== 'A') break
    }
    const stable = await status()
    check(stable.primary.id === 'A', 'пока A работает — выбор не прыгает на B, хотя B активнее')

    // A закончил ход — карточка обязана перейти на работающий B.
    append('session-A', 'A', [{ type: 'turn/end', seq: 20, time: Date.now(), data: { turn: 1, reason: { kind: 'completed' } } }])
    const switched = await waitFor((s) => s.primary && s.primary.id === 'B', 8000, 'после конца A должен быть B')
    check(switched.primary.id === 'B', 'после завершения A карточка перешла на B')

    // Ручное закрепление возвращает A даже неактивным.
    await req('POST', '/primary', { id: 'A' })
    const pinned = await status()
    check(pinned.primary.id === 'A' && pinned.pinnedId === 'A', 'закрепление перекрывает автоматику')
    check(!!pinned.primary.pinned, 'в снимке отмечено, что сессия закреплена')

    // Снятие закрепления возвращает автоматический выбор.
    await req('POST', '/primary', { id: null })
    const auto = await status()
    check(auto.primary.id === 'B' && auto.pinnedId === null, 'после снятия закрепления — снова авторежим')

    // Вопрос пользователю в третьем окне перебивает текущее.
    append('session-C', 'C', [
      { type: 'session', version: 4, id: 'C', createdAt: now - 30000, cwd: 'C:\\c', delegationDepth: 0 },
      { type: 'session/title', seq: 1, time: now - 29000, data: { title: 'Окно C' } },
      { type: 'turn/start', seq: 2, time: now - 20000, data: { turn: 1 } },
      { type: 'tool/call', seq: 3, time: Date.now(), data: { turn: 1, step: 1, callId: 'q1', name: 'ask_user_question', arguments: '{}' } },
    ])
    const asked = await waitFor((s) => s.primary && s.primary.id === 'C', 8000, 'вопрос должен перебить текущую сессию')
    check(asked.primary.status === 'waiting', 'сессия с вопросом показана как waiting')
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
