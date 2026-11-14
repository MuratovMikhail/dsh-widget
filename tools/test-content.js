// Проверка наполнения карточки: вопрос, подтверждение, ошибка, план,
// разрезанная запись, инкрементальное чтение и защита локального HTTP.
// Запуск: node tools/test-content.js
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const zlib = require('node:zlib')
const http = require('node:http')
const { spawn } = require('node:child_process')

const here = __dirname
const enginePath = path.join(here, '..', 'widget-engine.js')
const home = path.join(here, '..', '.test-content')
const projectDir = path.join(home, 'sessions', '--test--')
const PORT = 45921

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function appendRecords(sessionDir, records) {
  const dir = path.join(projectDir, sessionDir)
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, 'session.v4.jsonl.zstd')
  const chunks = records.map((r) => zlib.zstdCompressSync(Buffer.from(JSON.stringify(r) + '\n', 'utf8')))
  fs.appendFileSync(file, Buffer.concat(chunks))
}

/** Дописывает произвольный текст как один zstd-фрейм (для разрезанной записи). */
function appendRaw(sessionDir, text) {
  const dir = path.join(projectDir, sessionDir)
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, 'session.v4.jsonl.zstd')
  fs.appendFileSync(file, zlib.zstdCompressSync(Buffer.from(text, 'utf8')))
}

function request(method, urlPath, headers) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path: urlPath, method, headers: headers || {} }, (res) => {
      let body = ''
      res.on('data', (c) => (body += c))
      res.on('end', () => {
        let json = null
        try { json = JSON.parse(body) } catch { }
        resolve({ status: res.statusCode, headers: res.headers, body, json })
      })
    })
    r.on('error', reject)
    r.end()
  })
}

const status = async () => (await request('GET', '/status')).json

async function waitFor(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs
  let last = null
  while (Date.now() < deadline) {
    try {
      last = await status()
      if (predicate(last)) return last
    } catch { /* движок ещё поднимается */ }
    await sleep(200)
  }
  throw new Error(`таймаут: ${label}; последний статус: ${JSON.stringify(last && last.primary)}`)
}

let failures = 0
function check(ok, label) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${label}`)
  if (!ok) failures += 1
}

function session(id, title, extra) {
  const now = Date.now()
  return [
    { type: 'session', version: 4, id, createdAt: now, cwd: 'C:\\test\\billing-service', delegationDepth: 0 },
    { type: 'session/title', seq: 1, time: now, data: { title } },
    ...(extra || []),
  ]
}

async function main() {
  fs.rmSync(home, { recursive: true, force: true })
  const now = Date.now()

  appendRecords('session-q', session('session-q', 'Вопрос', [
    { type: 'turn/start', seq: 2, time: now, data: { turn: 1 } },
    {
      type: 'tool/call', seq: 3, time: now, data: {
        turn: 1, step: 1, callId: 'call-q', name: 'ask_user_question',
        arguments: JSON.stringify({ questions: [{ id: 'q1', header: 'Куда коммитить?', question: 'Куда коммитить изменения?', options: [{ label: 'main' }] }] }),
      },
    },
  ]))

  const env = Object.assign({}, process.env, { DSH_HOME: home })
  const engine = spawn(process.execPath, [enginePath, '--port', String(PORT)], {
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  })
  let stderr = ''
  engine.stderr.on('data', (c) => { stderr += c })
  engine.stdout.on('data', () => { })

  try {
    // 1. Вопрос виден текстом.
    let snap = await waitFor((s) => s.primary && s.primary.status === 'waiting', 8000, 'ожидание вопроса')
    check(snap.primary.activity.kind === 'question', 'вопрос: kind=question')
    check(snap.primary.activity.detail === 'Куда коммитить?', 'вопрос: показан header')
    check(snap.sessions.length === 1 && snap.activeCount === 1, 'вопрос: activeCount=1')

    // 2. Ответ с чужим callId не снимает ожидание, со своим — снимает.
    appendRecords('session-q', [{ type: 'tool/result', seq: 4, time: Date.now(), data: { turn: 1, step: 1, callId: 'other', ok: true } }])
    await sleep(500)
    snap = await status()
    check(snap.primary.status === 'waiting', 'tool/result с чужим callId не снимает ожидание')
    appendRecords('session-q', [{ type: 'tool/result', seq: 5, time: Date.now(), data: { turn: 1, step: 1, callId: 'call-q', ok: true } }])
    snap = await waitFor((s) => s.primary.status === 'working', 4000, 'ответ на вопрос')
    check(true, 'tool/result со своим callId снимает ожидание')

    // 3. Подтверждение (approval) — тоже ожидание, но другого вида.
    appendRecords('session-q', [{
      type: 'approval/asked', seq: 6, time: Date.now(), data: {
        id: 'ap-1', toolName: 'pwsh', callId: 'call-a', reason: 'escalate sandbox to danger-full-access: **rm -rf** build',
      },
    }])
    snap = await waitFor((s) => s.primary.status === 'waiting', 4000, 'ожидание подтверждения')
    check(snap.primary.activity.kind === 'approval', 'approval: kind=approval')
    check(/danger-full-access/.test(snap.primary.activity.detail), 'approval: причина показана')
    appendRecords('session-q', [{ type: 'approval/decided', seq: 7, time: Date.now(), data: { id: 'ap-1', outcome: 'accepted' } }])
    snap = await waitFor((s) => s.primary.status === 'working', 4000, 'подтверждение снято')
    check(true, 'approval/decided снимает ожидание')

    // 3b. План в plan mode: exit_plan_mode ждёт кнопку «Утвердить».
    appendRecords('session-plan-approval', session('session-plan-approval', 'План на утверждение', [
      { type: 'turn/start', seq: 2, time: now, data: { turn: 1 } },
      {
        type: 'tool/call', seq: 3, time: Date.now(), data: {
          turn: 1, step: 1, callId: 'call-plan', name: 'exit_plan_mode',
          arguments: JSON.stringify({ plan: '# План\n\nСделать портал.' }),
        },
      },
    ]))
    snap = await waitFor((s) => s.primary && s.primary.id === 'session-plan-approval' && s.primary.status === 'waiting', 5000, 'ожидание утверждения плана')
    check(snap.primary.activity.kind === 'approval', 'exit_plan_mode: kind=approval')
    check(!snap.primary.activity.tool, 'exit_plan_mode: без технического имени инструмента')
    appendRecords('session-plan-approval', [{ type: 'tool/result', seq: 4, time: Date.now(), data: { turn: 1, step: 1, callId: 'call-plan', ok: true } }])
    snap = await waitFor((s) => s.primary.id === 'session-plan-approval' && s.primary.status === 'working', 4000, 'план утверждён')
    check(true, 'exit_plan_mode: tool/result снимает ожидание')
    appendRecords('session-plan-approval', [{ type: 'turn/end', seq: 5, time: Date.now(), data: { turn: 1, reason: { kind: 'completed' } } }])
    await waitFor((s) => s.sessions.find((x) => x.id === 'session-plan-approval')?.status === 'done', 4000, 'план закрыт')

    // 4. Ошибка хода — done.ok=false.
    appendRecords('session-q', [
      { type: 'assistant/message', seq: 8, time: Date.now(), data: { message: { content: [{ type: 'text', text: 'Не удалось собрать проект.' }] } } },
      { type: 'turn/end', seq: 9, time: Date.now(), data: { turn: 1, reason: { kind: 'error' } } },
    ])
    snap = await waitFor((s) => s.primary && s.primary.status === 'done', 5000, 'завершение с ошибкой')
    check(snap.primary.done && snap.primary.done.ok === false, 'turn/end error: done.ok=false')
    check(snap.lastCompletion && snap.lastCompletion.ok === false, 'turn/end error: lastCompletion.ok=false')

    // 5. План через отдельное событие todo/write.
    appendRecords('session-plan', session('session-plan', 'План', [
      { type: 'turn/start', seq: 2, time: now, data: { turn: 1 } },
    ]))
    appendRecords('session-plan', [{
      type: 'todo/write', seq: 3, time: Date.now(), data: {
        todos: [{ content: 'a', status: 'completed' }, { content: 'b', status: 'in_progress' }, { content: 'c', status: 'pending' }],
      },
    }])
    snap = await waitFor((s) => s.primary && s.primary.id === 'session-plan', 5000, 'план')
    check(snap.primary.todos && snap.primary.todos.done === 1 && snap.primary.todos.total === 3, 'todo/write: 1 из 3')

    // 6. Инкрементальное чтение: одно событие не должно считаться несколько раз.
    const before = await status()
    const stepsBefore = before.primary.steps
    appendRecords('session-plan', [{ type: 'step/start', seq: 4, time: Date.now(), data: { turn: 1, step: 2 } }])
    await sleep(400)
    for (let i = 0; i < 4; i++) await status()
    const after = await status()
    check(after.primary.steps === stepsBefore + 1, `инкремент: шаг +1 (было ${stepsBefore}, стало ${after.primary.steps})`)

    // 7. Разрезанная запись: хвост первого фрейма + начало второго.
    appendRecords('session-split', session('session-split', 'Разрез', [
      { type: 'turn/start', seq: 2, time: now, data: { turn: 1 } },
    ]))
    await waitFor((s) => s.sessions.some((x) => x.id === 'session-split'), 5000, 'новая сессия')
    appendRaw('session-split', '{"type":"step/start","seq":3,"data":{"tur')
    await sleep(400)
    appendRaw('session-split', 'n":1,"step":7}}\n')
    snap = await waitFor((s) => {
      const x = s.sessions.find((v) => v.id === 'session-split')
      return x && x.step === 7
    }, 5000, 'разрезанная запись')
    check(true, 'разрезанная запись прочитана целиком')

    // 8. CORS/Origin/Host.
    const originRes = await request('GET', '/status', { Origin: 'https://evil.example' })
    check(originRes.status === 403, 'Origin → 403')
    const hostRes = await request('GET', '/status', { Host: 'evil.example:' + PORT })
    check(hostRes.status === 403, 'чужой Host → 403')
    const normal = await request('GET', '/status')
    check(normal.status === 200 && !normal.headers['access-control-allow-origin'], 'обычный запрос 200, ACAO отсутствует')

    // 9. Версия и health.
    const health = (await request('GET', '/health')).json
    check(health && health.zstd === true && !!health.version, 'health: zstd и версия')
  } finally {
    try { engine.kill() } catch { }
    await sleep(300)
    try { process.kill(engine.pid, 0) && require('node:child_process').execSync('taskkill /PID ' + engine.pid + ' /T /F', { stdio: 'ignore' }) } catch { }
    fs.rmSync(home, { recursive: true, force: true })
    if (stderr.trim()) console.log('engine stderr:', stderr.trim().split('\n').slice(0, 5).join(' | '))
  }

  console.log('')
  if (failures > 0) {
    console.log(`ПРОВАЛЕНО: ${failures}`)
    process.exit(1)
  }
  console.log('ВСЁ ОК')
}

main().catch((err) => {
  console.error(err)
  try { fs.rmSync(home, { recursive: true, force: true }) } catch { }
  process.exit(1)
})
