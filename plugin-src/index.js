import { spawn } from 'node:child_process'
import path from 'node:path'
import fs from 'node:fs'

export const name = 'dsh-widget-bridge'

function widgetDir() {
  if (process.env.DSH_WIDGET_DIR) return process.env.DSH_WIDGET_DIR
  const base = process.env.LOCALAPPDATA || ''
  return path.join(base, 'Programs', 'DSH Widget')
}

function appendLog(dir, message) {
  try {
    const line = new Date().toISOString().slice(11, 19) + ' bridge: ' + message + '\n'
    fs.appendFileSync(path.join(dir, 'widget.log'), line, 'utf8')
  } catch { }
}

// Запускает карточку вместе с DSH и гасит её при выгрузке плагина.
export function apply(ctx) {
  if (process.platform !== 'win32') return

  const dir = widgetDir()
  const ui = path.join(dir, 'widget-ui.ps1')
  const stop = path.join(dir, 'tools', 'stop-widget.ps1')
  if (!fs.existsSync(ui)) {
    console.warn('[dsh-widget-bridge] не найден виджет: ' + ui)
    return
  }

  ctx.effect(() => {
    let child = null
    let errFd = null
    try {
      let stdio = 'ignore'
      if (process.env.DSH_WIDGET_DEBUG) {
        errFd = fs.openSync(path.join(dir, 'bridge-stderr.log'), 'a')
        stdio = ['ignore', errFd, errFd]
      }
      child = spawn(
        'powershell.exe',
        ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ui],
        { cwd: dir, detached: false, stdio, windowsHide: true }
      )
      appendLog(dir, 'started pid=' + child.pid)
    } catch (err) {
      appendLog(dir, 'start failed: ' + String(err && err.message))
    } finally {
      // После spawn дескриптор у ребёнка уже продублирован — родительский закрываем.
      if (errFd !== null) {
        try { fs.closeSync(errFd) } catch { }
      }
    }

    return () => {
      // Виджет сам умеет останавливаться: гасим через его же скрипт,
      // потому что powershell мог перезапуститься, а движок — отдельный процесс.
      try {
        if (fs.existsSync(stop)) {
          const k = spawn(
            'powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', stop],
            { stdio: 'ignore', windowsHide: true }
          )
          k.unref()
          appendLog(dir, 'stop requested')
          return
        }
        if (child && child.pid) {
          spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true })
        }
      } catch { }
    }
  })
}
