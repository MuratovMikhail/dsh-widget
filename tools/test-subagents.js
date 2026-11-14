// Проверка логики «субагенты ещё работают»: собирает синтетический DSH_HOME,
// поднимает движок и смотрит, что карточка не объявляет работу готовой раньше времени.
// Запуск: node tools/test-subagents.js
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const zlib = require('node:zlib')
const http = require('node:http')
const { spawn } = require('node:child_process')

const here = __dirname
const enginePath = path.join(here, '..', 'widget-engine.js')
const home = path.join(here, '..', '.test-home')
const projectDir = path.join(home, 'sessions', '--test-project--')
const PORT = 45901

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function appendRecords(sessionDir, records) {
  const dir = path.join(projectDir, sessionDir)
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, 'session.v4.jsonl.zstd')
  const chunks = records.map((r) => zlib.zstdCompressSync(Buffer.from(JSON.stringify(r) + '\n', 'utf8')))
  fs.appendFileSync(file, Buffer.concat(chunks))
}

function getStatus() {
  return new Promise((resolve, reject) => {
    http
      .get(`http://127.0.0.1:${PORT}/status`, (res) => {
        let body = ''
        res.on('data', (c) => (body += c))
        res.on('end', () => {
          try { resolve(JSON.parse(body)) } catch (e) { reject(e) }
        })
      })
      .on('error', reject)
  })
}

async function waitFor(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs
  let last = null
  while (Date.now() < deadline) {
    try {
      last = await getStatus()
      if (predicate(last)) return last
    } catch { /* движок ещё поднимается */ }
    await sleep(250)
  }
  throw new Error(`таймаут: ${label}; последний статус: ${JSON.stringify(last && last.primary)}`)
}

let failures = 0
function check(ok, label) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${label}`)
  if (!ok) failures += 1
}

async function main() {
  fs.rmSync(home, { recursive: true, force: true })
  const now = Date.now()

  const parentId = 'session-parent-test'
  const childId = 'child-test-1'

  appendRecords('session-parent-test', [
    { type: 'session', version: 4, id: parentId, createdAt: now - 60000, cwd: 'C:\\test', delegationDepth: 0 },
    { type: 'session/title', seq: 1, time: now - 59000, data: { title: 'Сборка интерфейса' } },
    { type: 'turn/start', seq: 2, time: now - 58000, data: { turn: 1 } },
    { type: 'step/start', seq: 3, time: now - 57000, data: { turn: 1, step: 1 } },
    { type: 'tool/call', seq: 4, time: now - 56000, data: { turn: 1, step: 1, callId: 'c1', name: 'subagent', arguments: '{"description":"Проверка формы"}' } },
    { type: 'tool/result', seq: 5, time: now - 55000, data: { turn: 1, step: 1, message: { role: 'tool', toolCallId: 'c1' }, meta: {} } },
    { type: 'step/start', seq: 6, time: now - 54000, data: { turn: 1, step: 2 } },
    { type: 'assistant/message', seq: 7, time: now - 53000, data: { turn: 1, step: 2, message: { role: 'assistant', content: [{ type: 'text', text: 'Запустил два прохода, жду результаты.' }] } } },
    { type: 'turn/end', seq: 8, time: now - 52000, data: { turn: 1, reason: { kind: 'completed' } } },
  ])

  // Старая сессия из истории: её завершение не должно превращаться в «только что готово».
  appendRecords('session-old-test', [
    { type: 'session', version: 4, id: 'session-old-test', createdAt: now - 3600000, cwd: 'C:\\test', delegationDepth: 0 },
    { type: 'session/title', seq: 1, time: now - 3500000, data: { title: 'Старая сессия' } },
    { type: 'turn/start', seq: 2, time: now - 1900000, data: { turn: 1 } },
    { type: 'assistant/message', seq: 3, time: now - 1800000, data: { turn: 1, step: 1, message: { role: 'assistant', content: [{ type: 'text', text: 'Давно законченная работа.' }] } } },
    { type: 'turn/end', seq: 4, time: now - 1800000, data: { turn: 1, reason: { kind: 'completed' } } },
  ])

  // Субагент ещё работает: своего turn/end у него нет.
  appendRecords('child-test-1', [
    { type: 'session', version: 4, id: childId, createdAt: now - 50000, cwd: 'C:\\test', parentSession: parentId, origin: 'subagent', delegationDepth: 1 },
    { type: 'turn/start', seq: 1, time: now - 49000, data: { turn: 1 } },
    { type: 'step/start', seq: 2, time: now - 2000, data: { turn: 1, step: 3 } },
    { type: 'tool/call', seq: 3, time: now - 1000, data: { turn: 1, step: 3, callId: 'c9', name: 'pwsh', arguments: '{"description":"Прогоняет сценарии формы"}' } },
  ])

  const engine = spawn(process.execPath, [enginePath, '--port', String(PORT)], {
    env: { ...process.env, DSH_HOME: home },
    stdio: 'ignore',
    windowsHide: true,
  })

  try {
    await waitFor((s) => s.ok === true, 8000, 'движок не поднялся')

    const running = await waitFor((s) => s.primary && s.primary.status === 'subagents', 8000, 'ожидался статус subagents')
    check(running.primary.status === 'subagents', 'пока субагент работает — статус subagents, а не done')
    check(running.primary.subagents.active === 1, `активных субагентов = 1 (получено ${running.primary.subagents.active})`)
    check(running.lastCompletion === null, 'завершение не объявлено, пока субагент жив')

    // Субагент закончил работу.
    appendRecords('child-test-1', [
      { type: 'assistant/message', seq: 4, time: Date.now() - 500, data: { turn: 1, step: 3, message: { role: 'assistant', content: [{ type: 'text', text: 'Форма проверена, 14 сценариев.' }] } } },
      { type: 'turn/end', seq: 5, time: Date.now(), data: { turn: 1, reason: { kind: 'completed' } } },
    ])

    const finished = await waitFor((s) => s.primary && s.primary.status === 'done', 8000, 'ожидался статус done')
    check(finished.primary.status === 'done', 'после завершения субагента — статус done')
    check(finished.primary.subagents.active === 0, 'активных субагентов больше нет')
    check(!!finished.lastCompletion && finished.lastCompletion.ok === true, 'завершение объявлено')
    check(
      !!finished.lastCompletion && finished.lastCompletion.emittedAt >= finished.lastCompletion.at - 1000,
      'завершение отправлено после окончания хода'
    )
    check(
      !!finished.lastCompletion && /Запустил два прохода/.test(finished.lastCompletion.preview),
      'в превью — ответ родительской сессии'
    )
  } finally {
    engine.kill()
    await sleep(300)
    fs.rmSync(home, { recursive: true, force: true })
  }

  console.log(failures === 0 ? '\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' : `\nПРОВАЛЕНО: ${failures}`)
  process.exit(failures === 0 ? 0 : 1)
}

main().catch((err) => {
  console.error('Ошибка теста:', err.message)
  process.exit(1)
})
