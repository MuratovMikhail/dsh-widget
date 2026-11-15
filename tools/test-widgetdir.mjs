import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { widgetDir } from '../plugin-src/index.js'

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-widgetdir-'))
const oldLocal = process.env.LOCALAPPDATA
const oldDir = process.env.DSH_WIDGET_DIR

try {
  process.env.LOCALAPPDATA = temp
  delete process.env.DSH_WIDGET_DIR

  const custom = path.join(temp, 'custom widget')
  fs.mkdirSync(custom, { recursive: true })
  fs.writeFileSync(path.join(custom, 'widget-ui.ps1'), '# test')
  const pointerDir = path.join(temp, 'DSH Widget')
  fs.mkdirSync(pointerDir, { recursive: true })
  fs.writeFileSync(path.join(pointerDir, 'install-dir.txt'), custom)
  assert.equal(widgetDir(), custom, 'install-dir.txt must override the default path')

  fs.rmSync(path.join(pointerDir, 'install-dir.txt'))
  assert.equal(widgetDir(), path.join(temp, 'Programs', 'DSH Widget'), 'default fallback')

  process.env.DSH_WIDGET_DIR = custom
  assert.equal(widgetDir(), custom, 'DSH_WIDGET_DIR has priority')
} finally {
  if (oldLocal === undefined) delete process.env.LOCALAPPDATA
  else process.env.LOCALAPPDATA = oldLocal
  if (oldDir === undefined) delete process.env.DSH_WIDGET_DIR
  else process.env.DSH_WIDGET_DIR = oldDir
  fs.rmSync(temp, { recursive: true, force: true })
}

console.log('widgetDir: ok')
