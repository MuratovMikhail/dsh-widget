#!/usr/bin/env node
'use strict'

/**
 * DSH Widget — движок состояния.
 *
 * Читает журналы сессий DeepSeek Harness (~/.dsh/sessions/<проект>/<сессия>/session.v*.jsonl.zstd),
 * которые представляют собой поток дописываемых zstd-фреймов с NDJSON-событиями,
 * и отдаёт по HTTP компактный снимок состояния: что агент делает прямо сейчас,
 * чем закончился последний ход и когда именно он закончился.
 *
 * Зависимостей нет — только встроенные модули Node 24 (zlib умеет zstd).
 * Порт по умолчанию 45871, интерфейс только 127.0.0.1.
 */

const http = require('node:http')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const zlib = require('node:zlib')

const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
const DONE_VISIBLE_MS = 3 * 60 * 1000      // сколько держим «готово» на карточке
const STALE_MS = 30 * 60 * 1000            // ход без событий дольше — считаем брошенным
const TICK_MS = 1000
const VERSION = '1.0.5'
const HAS_ZSTD = typeof zlib.zstdDecompressSync === 'function'

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
const SESSIONS_ROOT = path.join(DSH_HOME, 'sessions')

const argPort = process.argv.indexOf('--port')
const PORT = Number((argPort > -1 && process.argv[argPort + 1]) || process.env.DSH_WIDGET_PORT || 45871)
const argParent = process.argv.indexOf('--parent-pid')
const PARENT_PID = Number((argParent > -1 && process.argv[argParent + 1]) || 0)

let completionSerial = 0
const store = new Map()   // filePath -> { size, parsedTo, state }

// ---------------------------------------------------------------- баланс

const CONFIG_PATH = path.join(__dirname, 'config.json')

// Конфиг читается с диска редко и кэшируется по mtime: настройки меняются из UI,
// а опрос состояния идёт несколько раз в секунду.
let configCache = { mtime: -1, at: 0, value: {} }

function readConfig() {
  try {
    const st = fs.statSync(CONFIG_PATH)
    if (st.mtimeMs !== configCache.mtime || Date.now() - configCache.at > 5000) {
      configCache = { mtime: st.mtimeMs, at: Date.now(), value: JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')) }
    }
    return configCache.value || {}
  } catch {
    if (configCache.mtime !== -1) configCache = { mtime: -1, at: Date.now(), value: {} }
    return {}
  }
}

function doneVisibleMs() {
  const sec = Number(readConfig().doneVisibleSec)
  if (!Number.isFinite(sec)) return DONE_VISIBLE_MS
  return Math.max(30, Math.min(3600, sec)) * 1000
}

/**
 * Грант аккаунта, который DSH хранит у себя. Читается только для запроса баланса;
 * токен нигде не логируется и уходит исключительно на issuer из самого гранта.
 */
function readAccountGrant() {
  try {
    const file = path.join(DSH_HOME, '.credentials.yaml')
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)

    // Записи лежат в records на отступе 2, поля — глубже и с вложенностью (payload.token).
    // Нам нужны только leaf-значения, поэтому просто собираем их в плоский объект.
    const unquote = (v) => v.replace(/^'(.*)'$/, '$1').replace(/^"(.*)"$/, '$1')
    const records = {}
    let current = null
    for (const line of lines) {
      const top = line.match(/^ {2}([A-Za-z0-9_./-]+):\s*$/)
      if (top) {
        current = records[top[1]] = {}
        continue
      }
      if (!current) continue
      const kv = line.match(/^( +)([A-Za-z0-9_.-]+):\s*(.*)$/)
      if (!kv) continue
      if (kv[1].length <= 2) current = null
      else if (kv[3].trim()) current[kv[2]] = unquote(kv[3].trim())
    }

    const name = Object.keys(records).find((k) => k.startsWith('deepseek-account-platform/') && records[k].token)
    if (!name) return null
    const rec = records[name]
    if (!rec.token || !rec.issuer) return null
    return { token: rec.token, issuer: rec.issuer }
  } catch {
    return null
  }
}

function currencySymbol(code) {
  if (code === 'CNY') return '¥'
  if (code === 'USD') return '$'
  return String(code || '') + ' '
}

function pickWallet(wallets) {
  const list = (wallets || [])
    .map((w) => ({ currency: w && w.currency, value: Number(w && w.balance) }))
    .filter((w) => Number.isFinite(w.value))
  if (!list.length) return null
  for (const code of ['CNY', 'USD']) {
    const hit = list.find((w) => w.currency === code && w.value > 0)
    if (hit) return hit
  }
  const anyNonZero = list.find((w) => w.value > 0)
  return anyNonZero || list[0]
}

const balanceState = {
  enabled: true,
  ok: false,
  source: null,
  currency: null,
  symbol: null,
  amount: null,
  bonus: null,
  updatedAt: null,
  error: null,
  loading: false,
  // Аккаунт не привязан: не мигаем прочерком на каждой попытке, но продолжаем пробовать.
  noAccount: false,
}

function balanceIntervalMs() {
  const cfg = readConfig()
  const sec = Number(cfg.balanceIntervalSec)
  return (Number.isFinite(sec) && sec >= 60 ? sec : 300) * 1000
}

function balanceConfig() {
  const cfg = readConfig()
  const apiKey = typeof cfg.balanceApiKey === 'string' ? cfg.balanceApiKey.trim() : ''
  let source = String(cfg.balanceSource || '').toLowerCase()
  if (source !== 'account' && source !== 'apikey' && source !== 'off') {
    source = apiKey ? 'apikey' : 'account'
  }
  // Нет ключа для режима apikey — не притворяемся, что баланс есть.
  const usable = source === 'account' || (source === 'apikey' && !!apiKey)
  const enabled = cfg.balance !== false && source !== 'off' && usable
  return { enabled, source, apiKey }
}

async function fetchBalanceFromPlatform(grant) {
  const url = new URL('/api/v0/users/get_user_summary', grant.issuer)
  if (url.protocol !== 'https:' || !/(^|\.)deepseek\.com$/i.test(url.hostname)) {
    throw new Error('issuer отклонён')
  }
  const res = await fetch(url, {
    headers: { 'x-dsh-auth-token': grant.token },
    signal: AbortSignal.timeout(15000),
  })
  if (!res.ok) throw new Error('HTTP ' + res.status)
  const json = await res.json()
  const biz = json && json.data && json.data.biz_data
  if (!biz) throw new Error('пустой ответ')
  const wallet = pickWallet(biz.normal_wallets)
  if (!wallet) throw new Error('нет кошельков')
  const bonusList = (biz.bonus_wallets || []).filter((w) => w && w.currency === wallet.currency)
  const bonus = bonusList.reduce((sum, w) => sum + (Number(w.balance) || 0), 0)
  return { source: 'platform', currency: wallet.currency, amount: wallet.value, bonus }
}

async function fetchBalanceFromApiKey(apiKey) {
  const res = await fetch('https://api.deepseek.com/user/balance', {
    headers: { authorization: 'Bearer ' + apiKey },
    signal: AbortSignal.timeout(15000),
  })
  if (!res.ok) throw new Error('HTTP ' + res.status)
  const json = await res.json()
  const infos = Array.isArray(json.balance_infos) ? json.balance_infos : []
  const list = infos
    .map((i) => ({ currency: i.currency, value: Number(i.total_balance), granted: Number(i.granted_balance) }))
    .filter((i) => Number.isFinite(i.value))
  const wallet = list.find((i) => i.currency === 'CNY') || list[0]
  if (!wallet) throw new Error('нет данных о балансе')
  return { source: 'api-key', currency: wallet.currency, amount: wallet.value, bonus: Number(wallet.granted) || 0 }
}

async function refreshBalance(force) {
  const cfg = balanceConfig()
  balanceState.enabled = cfg.enabled && !balanceState.noAccount
  if (!cfg.enabled) {
    balanceState.ok = false
    balanceState.error = 'выключено в config.json'
    return
  }
  if (balanceState.loading) return
  const interval = balanceIntervalMs()
  if (!force && balanceState.updatedAt && Date.now() - balanceState.updatedAt < interval) return

  balanceState.loading = true
  try {
    let result = null
    if (cfg.source === 'apikey') {
      result = await fetchBalanceFromApiKey(cfg.apiKey)
    } else {
      const grant = readAccountGrant()
      if (!grant) throw new Error('аккаунт DSH не найден')
      result = await fetchBalanceFromPlatform(grant)
    }
    balanceState.ok = true
    balanceState.noAccount = false
    balanceState.enabled = true
    balanceState.source = result.source
    balanceState.currency = result.currency
    balanceState.symbol = currencySymbol(result.currency)
    balanceState.amount = Math.round(result.amount * 100) / 100
    balanceState.bonus = result.bonus ? Math.round(result.bonus * 100) / 100 : 0
    balanceState.error = null
  } catch (err) {
    balanceState.ok = false
    balanceState.error = String((err && err.message) || err)
    // Нет привязанного аккаунта и нет ключа — показывать нечего, карточка остаётся без баланса.
    if (balanceState.error === 'аккаунт DSH не найден') {
      balanceState.noAccount = true
      balanceState.enabled = false
    }
  } finally {
    balanceState.loading = false
    balanceState.updatedAt = Date.now()
  }
}

function balanceView() {
  return {
    enabled: balanceState.enabled,
    ok: balanceState.ok,
    source: balanceState.source,
    currency: balanceState.currency,
    symbol: balanceState.symbol,
    amount: balanceState.amount,
    bonus: balanceState.bonus,
    updatedAt: balanceState.updatedAt,
    error: balanceState.error,
  }
}

// ---------------------------------------------------------------- состояние

function blankState(filePath) {
  return {
    file: filePath,
    id: null,
    title: null,
    cwd: null,
    delegationDepth: 0,
    parentId: null,
    origin: null,
    createdAt: null,
    turn: 0,
    step: 0,
    steps: 0,
    status: 'idle',
    turnStartedAt: null,
    turnEndedAt: null,
    lastEventAt: null,
    lastEventType: null,
    lastSeq: 0,
    tool: null,
    lastToolName: null,
    lastToolResultAt: null,
    assistantText: '',
    pendingQuestion: false,
    pendingQuestionText: '',
    pendingApproval: null,
    todos: null,
    jobsRegistered: 0,
    jobsSettled: 0,
    completions: 0,
    lastCompletion: null,
    pendingEnd: null,
    // Серийник завершения, который пользователь уже увидел (открыл окно).
    ackSerial: 0,
  }
}

function clip(text, n) {
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim()
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

function baseName(p) {
  if (!p) return ''
  const s = String(p).replace(/[\\/]+$/, '')
  const i = Math.max(s.lastIndexOf('\\'), s.lastIndexOf('/'))
  return i >= 0 ? s.slice(i + 1) : s
}

function hostOf(url) {
  try { return new URL(String(url)).host } catch { return clip(url, 60) }
}

function stripMarkdown(text) {
  return String(text || '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/[*_>#]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

function previewText(text) {
  const plain = stripMarkdown(text)
  if (!plain) return ''
  return clip(plain, 160)
}

/** Короткое человеческое описание аргументов инструмента. */
function summarizeTool(name, rawArgs) {
  let a = null
  try { a = JSON.parse(rawArgs) } catch { /* бывает неполный JSON */ }
  const g = (k) => (a && typeof a === 'object' ? a[k] : null)

  switch (name) {
    case 'pwsh':
    case 'bash':
      return clip(g('description') || String(g('command') || '').split('\n')[0], 110)
    case 'read':
    case 'write':
    case 'edit':
    case 'str_replace_editor':
      return baseName(g('file_path') || g('path'))
    case 'grep':
    case 'glob':
      return clip(g('pattern') || g('query') || '', 80)
    case 'web_search': {
      const q = g('queries') || g('query')
      return clip(Array.isArray(q) ? q.join(', ') : q || '', 90)
    }
    case 'web_fetch':
      return hostOf(g('url'))
    case 'subagent':
    case 'subagent_fork':
      return clip(g('description') || 'задача', 70)
    case 'present': {
      const files = g('files')
      if (Array.isArray(files) && files.length) {
        return clip(files.map((f) => baseName(f && (f.path || f))).join(', '), 90)
      }
      return ''
    }
    case 'todo_write':
      return 'план работ'
    case 'ask_user_question':
      return 'нужен ваш ответ'
    case 'workflow':
      return clip(g('meta') && g('meta').name, 60)
    case 'skill':
      return clip(g('name'), 60)
    default:
      return ''
  }
}

/** Текст вопроса, который агент задал пользователю (ask_user_question). */
function questionText(rawArgs) {
  try {
    const a = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs
    const q = a && Array.isArray(a.questions) ? a.questions[0] : null
    const text = q && (q.header || q.question)
    return clip(text || '', 120)
  } catch {
    return ''
  }
}

/** Пункты плана агента: сколько сделано из скольких. */
function todoCounts(list) {
  if (!Array.isArray(list) || !list.length) return null
  const isDone = (t) => t && (t.status === 'completed' || t.status === 'done')
  return { done: list.filter(isDone).length, total: list.length }
}

function applyRecord(s, r) {
  if (!r || typeof r !== 'object' || typeof r.type !== 'string') return
  const d = r.data || {}
  const time = Number(r.time) || 0
  const seq = Number(r.seq) || 0
  if (seq > s.lastSeq) s.lastSeq = seq
  // У заголовка журнала ('session') поля time нет — он не является событием активности.
  if (time > 0 && (!s.lastEventAt || time >= s.lastEventAt)) {
    s.lastEventAt = time
    s.lastEventType = r.type
  }

  switch (r.type) {
    case 'session': {
      // У заголовка журнала поля лежат в корне записи, а не в data.
      const id = r.id || d.id
      const cwd = r.cwd || d.cwd
      const depth = r.delegationDepth != null ? r.delegationDepth : d.delegationDepth
      const createdAt = r.createdAt || d.createdAt
      const parent = r.parentSession || d.parentSession
      const origin = r.origin || d.origin
      if (id) s.id = id
      if (cwd) s.cwd = cwd
      if (parent) s.parentId = parent
      if (origin) s.origin = origin
      s.delegationDepth = Number(depth) || 0
      if (createdAt) s.createdAt = createdAt
      break
    }

    case 'session/title':
      if (d.title) s.title = String(d.title)
      break

    case 'turn/start':
      s.turn = Number(d.turn) || s.turn + 1
      s.turnStartedAt = time
      s.step = 0
      s.steps = 0
      s.status = 'working'
      s.tool = null
      s.pendingQuestion = false
      s.pendingQuestionText = ''
      s.pendingApproval = null
      s.todos = null
      s.pendingEnd = null
      s.jobsRegistered = 0
      s.jobsSettled = 0
      s.ackSerial = 0
      break

    case 'turn/end': {
      // Ход мог закончиться, пока субагенты ещё работают: не объявляем работу
      // готовой сразу — завершение финализируется в snapshot(), когда дети успокоятся.
      s.status = 'done'
      s.turnEndedAt = time
      const reason = (d.reason && d.reason.kind) || 'completed'
      // Старые ходы из истории (движок только что запустился) не должны
      // превращаться в «только что завершено» и присылать уведомление.
      const isHistory = Date.now() - time > 10 * 60 * 1000
      s.pendingEnd = isHistory
        ? null
        : {
            at: time,
            turn: Number(d.turn) || s.turn,
            ok: reason === 'completed',
            reason,
            preview: previewText(s.assistantText),
            durationMs: s.turnStartedAt ? Math.max(0, time - s.turnStartedAt) : null,
            steps: s.steps,
          }
      s.tool = null
      s.pendingQuestion = false
      s.pendingQuestionText = ''
      s.pendingApproval = null
      break
    }

    case 'step/start':
      s.step = Number(d.step) || s.step + 1
      s.steps += 1
      break

    case 'tool/call':
      s.tool = {
        callId: d.callId || null,
        name: d.name || 'tool',
        args: d.arguments || '',
        startedAt: time,
        done: false,
      }
      s.lastToolName = d.name || null
      if (d.name === 'ask_user_question') {
        s.pendingQuestion = true
        s.pendingQuestionText = questionText(d.arguments)
      }
      if (d.name === 'exit_plan_mode') {
        // DSH показывает план и ждёт «Утвердить» / «Запросить изменения».
        // Пока tool/result не пришёл, это ожидание подтверждения, а не работа.
        s.pendingApproval = { tool: '', detail: '' }
      }
      if (d.name === 'todo_write') {
        // План агента: сколько пунктов сделано из скольких.
        try {
          const rawArgs = d.arguments
          const todoArgs = typeof rawArgs === 'string' ? JSON.parse(rawArgs) : rawArgs
          const todoList = todoArgs && Array.isArray(todoArgs.todos) ? todoArgs.todos : null
          s.todos = todoCounts(todoList) || s.todos
        } catch { }
      }
      break

    case 'todo/write': {
      // Отдельное событие плана (есть не во всех версиях): более надёжный источник, чем tool/call.
      const list = Array.isArray(d.todos) ? d.todos : null
      s.todos = todoCounts(list) || s.todos
      break
    }

    case 'approval/asked':
      s.pendingApproval = {
        tool: String(d.toolName || ''),
        detail: clip(stripMarkdown(d.reason || ''), 120),
      }
      break

    case 'approval/decided':
      s.pendingApproval = null
      break

    case 'tool/result': {
      const callId = d.callId || null
      const matches = s.tool && (!callId || !s.tool.callId || callId === s.tool.callId)
      if (matches) {
        s.tool.done = true
        if (s.tool.name === 'ask_user_question') {
          s.pendingQuestion = false
          s.pendingQuestionText = ''
        }
        if (s.tool.name === 'exit_plan_mode') {
          s.pendingApproval = null
        }
      }
      s.lastToolResultAt = time
      break
    }

    case 'assistant/message': {
      const msg = d.message || {}
      const content = Array.isArray(msg.content) ? msg.content : []
      const texts = content.filter((c) => c && c.type === 'text' && c.text).map((c) => c.text)
      if (texts.length) s.assistantText = texts.join('\n')
      break
    }

    case 'user/message':
      if (s.status !== 'working') {
        s.status = 'working'
        s.turnStartedAt = time
        s.steps = 0
      }
      s.tool = null
      s.pendingApproval = null
      break

    case 'job/registered':
      s.jobsRegistered += 1
      break

    case 'job/settled':
      s.jobsSettled += 1
      break

    default:
      break
  }
}

/**
 * Разбирает текст нового фрагмента журнала. Остаток недописанной строки
 * переходит в следующий фрейм — иначе запись на границе фреймов терялась.
 */
function applyText(rec, text) {
  const lines = (rec.remainder + text).split('\n')
  rec.remainder = lines.pop() || ''
  for (const line of lines) {
    if (!line.trim()) continue
    let record
    try { record = JSON.parse(line) } catch { continue }
    applyRecord(rec.state, record)
  }
}

/** Последняя строка без перевода строки — если она уже целый JSON, забираем её. */
function flushRemainder(rec) {
  const tail = rec.remainder.trim()
  if (!tail) { rec.remainder = ''; return }
  try {
    const record = JSON.parse(tail)
    rec.remainder = ''
    applyRecord(rec.state, record)
  } catch { /* запись ещё не дописана — подождём следующий фрейм */ }
}

/**
 * Дописывает в состояние только то, что появилось в файле с прошлого раза:
 * читает с сохранённого offset, а не весь журнал (он бывает по 8–10 МБ).
 * Возвращает true, если прочитались новые данные.
 */
function refreshFile(entry) {
  const file = entry.path
  let st
  try { st = fs.statSync(file) } catch { store.delete(file); return false }

  let rec = store.get(file)
  if (!rec) {
    rec = { offset: 0, size: 0, mtimeMs: 0, remainder: '', state: blankState(file) }
    store.set(file, rec)
  }
  if (rec.size === st.size && rec.mtimeMs === st.mtimeMs) return false

  // Журнал переписали целиком (компакция/новая версия формата) — начинаем заново.
  if (st.size < rec.offset) {
    rec.state = blankState(file)
    rec.offset = 0
    rec.remainder = ''
  }

  const length = st.size - rec.offset
  let progressed = false
  if (length > 0) {
    let buf
    try {
      const fd = fs.openSync(file, 'r')
      try {
        buf = Buffer.allocUnsafe(length)
        const read = fs.readSync(fd, buf, 0, length, rec.offset)
        if (read < length) buf = buf.subarray(0, read)
      } finally {
        fs.closeSync(fd)
      }
    } catch {
      return false
    }

    let pos = 0
    while (pos < buf.length) {
      const idx = buf.indexOf(ZSTD_MAGIC, pos)
      if (idx === -1) break
      let text
      try {
        text = zlib.zstdDecompressSync(buf.subarray(idx)).toString('utf8')
      } catch {
        // Хвостовой фрейм мог быть недописан. Пропускаем мусор до его начала
        // и оставляем offset на этом фрейме — дочитаем после следующего append.
        if (idx > pos) pos = idx
        break
      }
      applyText(rec, text)
      progressed = true
      const next = buf.indexOf(ZSTD_MAGIC, idx + 4)
      pos = next === -1 ? buf.length : next
    }
    rec.offset += pos
  }

  flushRemainder(rec)
  rec.size = st.size
  rec.mtimeMs = st.mtimeMs
  return progressed
}

// ---------------------------------------------------------------- обзор

function listSessionFiles() {
  const out = []
  let projects
  try { projects = fs.readdirSync(SESSIONS_ROOT, { withFileTypes: true }) } catch { return out }
  for (const proj of projects) {
    if (!proj.isDirectory()) continue
    const projDir = path.join(SESSIONS_ROOT, proj.name)
    let dirs
    try { dirs = fs.readdirSync(projDir, { withFileTypes: true }) } catch { continue }
    for (const dirEnt of dirs) {
      if (!dirEnt.isDirectory()) continue
      const dir = path.join(projDir, dirEnt.name)
      let names
      try { names = fs.readdirSync(dir) } catch { continue }
      const candidates = names
        .filter((n) => /^session\.v\d+\.jsonl\.zstd$/.test(n))
        .sort((a, b) => Number(a.replace(/\D+/g, '')) - Number(b.replace(/\D+/g, '')))
      if (!candidates.length) continue
      out.push({ path: path.join(dir, candidates[candidates.length - 1]), project: proj.name, dirName: dirEnt.name })
    }
  }
  return out
}

function describeActivity(s, status) {
  if (status === 'working') {
    if (s.pendingQuestion) return { kind: 'question', tool: s.tool && s.tool.name, detail: s.pendingQuestionText || '' }
    if (s.pendingApproval) return { kind: 'approval', tool: s.pendingApproval.tool, detail: s.pendingApproval.detail || '' }
    if (s.tool && !s.tool.done) {
      return { kind: 'tool', tool: s.tool.name, detail: summarizeTool(s.tool.name, s.tool.args) }
    }
    if (s.tool && s.tool.done) return { kind: 'thinking', tool: s.tool.name, detail: '' }
    return { kind: 'thinking', tool: null, detail: '' }
  }
  if (status === 'done') return { kind: 'done', tool: null, detail: s.lastCompletion ? s.lastCompletion.preview : '' }
  if (status === 'subagents') return { kind: 'subagents', tool: null, detail: '' }
  if (status === 'waiting') {
    if (s.pendingApproval) return { kind: 'approval', tool: s.pendingApproval.tool, detail: s.pendingApproval.detail || '' }
    return { kind: 'question', tool: s.tool && s.tool.name, detail: s.pendingQuestionText || '' }
  }
  return { kind: 'idle', tool: null, detail: '' }
}

/** Сессия реально работает прямо сейчас (а не «зависла» после закрытия DSH). */
function isFresh(s, now) {
  return s.status === 'working' && !!s.lastEventAt && now - s.lastEventAt < STALE_MS
}

function buildChildrenIndex(states) {
  const map = new Map()
  for (const s of states) {
    if (!s.parentId) continue
    let list = map.get(s.parentId)
    if (!list) {
      list = []
      map.set(s.parentId, list)
    }
    list.push(s)
  }
  return map
}

/** Список потомков (субагентов любого уровня), которые реально работают. */
function collectActiveDescendants(id, childrenOf, now, seen, out) {
  const kids = childrenOf.get(id)
  if (!kids) return out
  for (const k of kids) {
    if (!k.id || seen.has(k.id)) continue
    seen.add(k.id)
    if (isFresh(k, now)) out.push(k)
    collectActiveDescendants(k.id, childrenOf, now, seen, out)
  }
  return out
}

function countActiveDescendants(id, childrenOf, now) {
  return collectActiveDescendants(id, childrenOf, now, new Set(), []).length
}

/** Самый свежий работающий субагент — чтобы показать, чем именно он занят. */
function topActiveSubagent(id, childrenOf, now) {
  const active = collectActiveDescendants(id, childrenOf, now, new Set(), [])
  if (!active.length) return null
  active.sort((a, b) => (b.lastEventAt || 0) - (a.lastEventAt || 0))
  const k = active[0]
  const act = describeActivity(k, 'working')
  return {
    title: clip(k.title || 'субагент', 70),
    kind: act.kind,
    tool: act.tool || null,
    detail: act.detail || '',
  }
}

function lastActivityAt(s, childrenOf, now, seen) {
  let at = s.lastEventAt || 0
  const kids = childrenOf.get(s.id)
  if (!kids) return at
  for (const k of kids) {
    if (!k.id || seen.has(k.id)) continue
    seen.add(k.id)
    at = Math.max(at, lastActivityAt(k, childrenOf, now, seen))
  }
  return at
}

function completionAt(c) {
  return (c && (c.emittedAt || c.at)) || 0
}

/** Завершение уже просмотрено пользователем — блок можно убрать с карточки. */
function isAcked(s) {
  return !!(s.lastCompletion && s.ackSerial >= s.lastCompletion.serial)
}

/**
 * turn/end приходит раньше, чем заканчивают работу субагенты: ход завершён,
 * но дерево ещё живо. Завершение объявляем только когда успокоились все потомки.
 */
function finalizeCompletions(states, childrenOf, now) {
  let completed = false
  for (const s of states) {
    if ((s.delegationDepth || 0) !== 0) continue
    const pending = s.pendingEnd
    if (!pending) continue
    if (s.status === 'working') {
      s.pendingEnd = null
      continue
    }
    if (countActiveDescendants(s.id, childrenOf, now, new Set()) > 0) continue
    s.completions += 1
    s.lastCompletion = {
      serial: ++completionSerial,
      at: pending.at,
      emittedAt: now,
      sessionId: s.id,
      title: s.title,
      turn: pending.turn,
      ok: pending.ok,
      reason: pending.reason,
      preview: pending.preview,
      durationMs: pending.durationMs,
      steps: pending.steps,
    }
    s.pendingEnd = null
    completed = true
  }
  // Ход закрыл счёт — обновим баланс, не дожидаясь планового опроса.
  if (completed) refreshBalance(true)
}

function toView(s, primary, ctx) {
  const { now, childrenOf } = ctx
  const activeKids = countActiveDescendants(s.id, childrenOf, now)
  const totalKids = (childrenOf.get(s.id) || []).length
  const topKid = activeKids > 0 ? topActiveSubagent(s.id, childrenOf, now) : null

  let status = s.status
  // Ход, о котором давно не было событий, брошен (приложение закрыли) — не выдаём его за работу.
  if (status === 'working' && !isFresh(s, now)) status = 'stale'
  if (status === 'done' && activeKids > 0) status = 'subagents'
  // Пользователь уже открыл это окно — задача считается просмотренной и уходит с карточки.
  if (status === 'done' && isAcked(s)) status = 'idle'
  if (status === 'done' && activeKids === 0 && !(s.lastCompletion && now - completionAt(s.lastCompletion) < ctx.doneVisible)) status = 'idle'
  if (status === 'working' && (s.pendingQuestion || s.pendingApproval)) status = 'waiting'

  const elapsedMs = status === 'working' && s.turnStartedAt ? now - s.turnStartedAt : null
  return {
    id: s.id,
    title: s.title,
    cwd: s.cwd,
    status,
    turn: s.turn,
    step: s.step,
    steps: s.steps,
    elapsedMs,
    lastEventAt: s.lastEventAt,
    lastEventType: s.lastEventType,
    idleMs: s.lastEventAt ? now - s.lastEventAt : null,
    activity: describeActivity(s, status),
    jobs: {
      active: Math.max(0, s.jobsRegistered - s.jobsSettled),
      registered: s.jobsRegistered,
      settled: s.jobsSettled,
    },
    subagents: { active: activeKids, total: totalKids, top: topKid },
    delegationDepth: s.delegationDepth,
    done: status === 'done' && s.lastCompletion
      ? { at: completionAt(s.lastCompletion), ok: s.lastCompletion.ok, reason: s.lastCompletion.reason, preview: s.lastCompletion.preview, durationMs: s.lastCompletion.durationMs }
      : null,
    todos: s.todos || null,
    completionSerial: s.lastCompletion ? s.lastCompletion.serial : 0,
    primary: !!primary,
    pinned: s.id === pinnedPrimaryId,
  }
}

const DEBUG = !!process.env.DSH_WIDGET_DEBUG

// ---------------------------------------------------------------- выбор сессии

// Ручное закрепление из меню виджета: пока оно задано, карточка не прыгает.
let pinnedPrimaryId = null
// Что показываем сейчас — чтобы не переключаться на каждое событие в соседнем окне.
let currentPrimaryId = null

// Закрепление переживает перезапуск движка: UI хранит его в config.json.
try {
  const saved = readConfig().pinnedSessionId
  if (typeof saved === 'string' && saved) pinnedPrimaryId = saved
} catch { /* конфиг может быть битым — не повод падать */ }

/**
 * Выбор сессии для карточки.
 *
 * Правило простое и предсказуемое: однажды выбранную сессию держим, пока она реально
 * работает. Переключаемся только если она уснула или если в другом окне агент задал
 * вопрос — на вопрос нельзя не отреагировать. Иначе при двух активных окнах карточка
 * дёргалась бы на каждом шаге того, кто только что пошевелился.
 */
function selectPrimary(roots, busy, recentlyDone, isBusy) {
  const byId = (id) => roots.find((s) => s.id === id)

  if (pinnedPrimaryId) {
    const pinned = byId(pinnedPrimaryId)
    // Закрепление уважаем, только пока в этом окне действительно идёт работа
    // или только что завершился ход. Иначе закреплённая «мёртвая» сессия
    // перекрывала бы активную.
    if (pinned && (isBusy(pinned) || recentlyDone.includes(pinned))) return pinned
    if (!pinned) pinnedPrimaryId = null
  }

  const current = byId(currentPrimaryId)
  if (current && isBusy(current)) {
    if (!current.pendingQuestion && !current.pendingApproval) {
      const asking = busy.find((s) => s.pendingQuestion || s.pendingApproval)
      if (asking) return asking
    }
    return current
  }

  const asking = busy.find((s) => s.pendingQuestion || s.pendingApproval)
  if (asking) return asking

  return busy[0] || recentlyDone[0] ||
    roots.slice().sort((a, b) => (b.lastEventAt || 0) - (a.lastEventAt || 0))[0] || null
}

/**
 * Убирает из памяти сессии, которых больше нет в каталоге журналов,
 * и не даёт карте расти бесконечно за месяцы работы.
 */
function pruneStore(activePaths) {
  const dayMs = 24 * 60 * 60 * 1000
  const now = Date.now()
  for (const [file, rec] of store) {
    if (activePaths.has(file)) continue
    const last = Number(rec.state.lastEventAt || rec.state.createdAt || 0)
    if (!last || now - last > dayMs) store.delete(file)
  }
  if (store.size > 200) {
    const oldest = [...store.entries()]
      .sort((a, b) => Number(a[1].state.lastEventAt || 0) - Number(b[1].state.lastEventAt || 0))
    for (let i = 0; i < oldest.length - 200; i++) store.delete(oldest[i][0])
  }
}

function snapshot() {
  const now = Date.now()
  const files = listSessionFiles()
  for (const entry of files) refreshFile(entry)
  pruneStore(new Set(files.map((f) => f.path)))
  if (DEBUG) {
    console.error(`[debug] files=${files.length} tracked=${store.size} states=${[...store.values()].filter((v) => v.state.id).length}`)
  }

  const states = [...store.values()].map((v) => v.state).filter((s) => s.id || s.createdAt)
  const childrenOf = buildChildrenIndex(states)
  finalizeCompletions(states, childrenOf, now)

  const roots = states.filter((s) => (s.delegationDepth || 0) === 0)
  const ctx = { now, childrenOf, doneVisible: doneVisibleMs() }
  const isBusy = (s) => isFresh(s, now) || countActiveDescendants(s.id, childrenOf, now, new Set()) > 0

  const busy = roots
    .filter(isBusy)
    .sort((a, b) => lastActivityAt(b, childrenOf, now, new Set()) - lastActivityAt(a, childrenOf, now, new Set()))

  const recentlyDone = roots
    .filter((s) => s.lastCompletion && !isBusy(s) && !isAcked(s) && now - completionAt(s.lastCompletion) < ctx.doneVisible)
    .sort((a, b) => completionAt(b.lastCompletion) - completionAt(a.lastCompletion))

  const primary = selectPrimary(roots, busy, recentlyDone, isBusy)
  if (primary) currentPrimaryId = primary.id

  let lastCompletion = null
  for (const s of roots) {
    if (s.lastCompletion && (!lastCompletion || s.lastCompletion.serial > lastCompletion.serial)) {
      lastCompletion = { ...s.lastCompletion }
    }
  }

  // В список для карточки отдаём только живые сессии: сейчас работают или только что
  // завершились и ещё не просмотрены. Простаивающие и брошенные не занимают места.
  const recent = roots
    .filter((s) => s.lastEventAt)
    .map((s) => toView(s, s === primary, ctx))
    // Отсекаем по ИТОГОВОМУ статусу: toView может понизить сессию до idle/stale
    // (просмотрена, ход брошен) — такие блоки на карточке не нужны.
    .filter((v) => v.status !== 'idle' && v.status !== 'stale')
    .sort((a, b) => (b.lastEventAt || 0) - (a.lastEventAt || 0))
    .slice(0, 6)

  return {
    ok: true,
    version: VERSION,
    now,
    pid: process.pid,
    port: PORT,
    dshHome: DSH_HOME,
    sessionsTracked: states.length,
    workingCount: busy.length,
    activeCount: busy.length + recentlyDone.length,
    subagentWorkingCount: states.filter((s) => (s.delegationDepth || 0) > 0 && isFresh(s, now)).length,
    primary: primary ? toView(primary, true, ctx) : null,
    pinnedId: pinnedPrimaryId,
    lastCompletion,
    sessions: recent,
    balance: balanceView(),
  }
}

// ---------------------------------------------------------------- HTTP

function send(res, code, body) {
  const payload = JSON.stringify(body)
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(payload),
    'x-content-type-options': 'nosniff',
  })
  res.end(payload)
}

/** Только локальные имена хоста: защита от DNS-rebinding. */
function isLocalHost(hostHeader) {
  if (!hostHeader) return true // HTTP/1.0 и локальные утилиты без Host
  const host = String(hostHeader).toLowerCase()
  return host === `127.0.0.1:${PORT}` || host === `localhost:${PORT}` || host === `[::1]:${PORT}`
}

const server = http.createServer((req, res) => {
  // Запросы из браузера (Origin) и с чужого Host к движку не пускаем:
  // карточка общается с ним через WebClient, CORS ей не нужен.
  if (req.headers.origin || !isLocalHost(req.headers.host)) {
    return send(res, 403, { ok: false, error: 'forbidden' })
  }
  const url = new URL(req.url || '/', 'http://127.0.0.1')
  try {
    if (url.pathname === '/health') {
      return send(res, 200, {
        ok: HAS_ZSTD,
        version: VERSION,
        zstd: HAS_ZSTD,
        pid: process.pid,
        uptimeMs: Math.round(process.uptime() * 1000),
      })
    }
    if (url.pathname === '/status') return send(res, 200, snapshot())
    if (url.pathname === '/sessions') return send(res, 200, { ok: true, sessions: snapshot().sessions })
    if (url.pathname === '/balance') return send(res, 200, { ok: true, balance: balanceView() })
    if (url.pathname === '/balance/refresh') {
      refreshBalance(true)
        .then(() => send(res, 200, { ok: true, balance: balanceView() }))
        .catch((err) => send(res, 500, { ok: false, error: String(err && err.message) }))
      return
    }
    if (url.pathname === '/primary' && req.method === 'POST') {
      let body = ''
      req.on('data', (chunk) => {
        body += chunk
        if (body.length > 8192) req.destroy()
      })
      req.on('end', () => {
        try {
          const payload = JSON.parse(body || '{}')
          const id = payload.id == null ? null : String(payload.id)
          if (id && ![...store.values()].some((v) => v.state.id === id)) {
            return send(res, 404, { ok: false, error: 'неизвестная сессия' })
          }
          pinnedPrimaryId = id
          if (id) currentPrimaryId = id
          send(res, 200, { ok: true, pinnedId: pinnedPrimaryId })
        } catch (err) {
          send(res, 400, { ok: false, error: String(err && err.message) })
        }
      })
      return
    }
    if (url.pathname === '/ack' && req.method === 'POST') {
      let body = ''
      req.on('data', (chunk) => {
        body += chunk
        if (body.length > 8192) req.destroy()
      })
      req.on('end', () => {
        try {
          const payload = JSON.parse(body || '{}')
          const id = payload.id == null ? null : String(payload.id)
          const entry = [...store.values()].find((v) => v.state.id === id)
          if (!entry) return send(res, 404, { ok: false, error: 'неизвестная сессия' })
          const s = entry.state
          if (s.lastCompletion && s.status === 'done') s.ackSerial = s.lastCompletion.serial
          send(res, 200, { ok: true })
        } catch (err) {
          send(res, 400, { ok: false, error: String(err && err.message) })
        }
      })
      return
    }
    return send(res, 404, { ok: false, error: 'not found' })
  } catch (err) {
    return send(res, 500, { ok: false, error: String(err && err.message) })
  }
})

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    // Движок уже запущен — второй экземпляр не нужен.
    process.exit(0)
  }
  console.error('[dsh-widget] server error:', err)
  process.exit(1)
})

if (!HAS_ZSTD) {
  console.error('[dsh-widget] этот Node не умеет zstd (нужен 22.15+); обновите DeepSeek Harness')
  process.exit(2)
}

// Если UI упал/убит, движок не должен оставаться сиротой в процессах.
if (PARENT_PID) {
  setInterval(() => {
    try { process.kill(PARENT_PID, 0) } catch { process.exit(0) }
  }, 5000).unref()
}

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[dsh-widget] engine ${VERSION} listening on http://127.0.0.1:${PORT} (home: ${DSH_HOME})`)
  refreshBalance(false)
})

setInterval(() => {
  try { snapshot() } catch (err) { console.error('[dsh-widget] tick failed:', err && err.message) }
}, TICK_MS)

// Баланс меняется медленно: раз в интервал из config.json (по умолчанию 5 минут).
setInterval(() => {
  refreshBalance(false)
}, 30000)

process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))
