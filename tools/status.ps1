# Проверка состояния движка виджета.
# Печатает то, что видит карточка: активную сессию, шаг, инструмент, ожидание и последнее завершение.
param([int]$Port = 45871)

try {
    $s = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/status") -TimeoutSec 5
} catch {
    Write-Output ('Движок не отвечает на порту ' + $Port + ': ' + $_.Exception.Message)
    return
}

Write-Output ('DSH_HOME:        ' + $s.dshHome)
Write-Output ('версия:          ' + $s.version)
Write-Output ('сессий в движке: ' + $s.sessionsTracked + ', активных: ' + $s.activeCount + ' (работают: ' + $s.workingCount + ')')
$b = $s.balance
if ($b) {
    if ($b.ok) { Write-Output ('баланс:          ' + $b.symbol + $b.amount + ' (' + $b.source + ')') }
    else { Write-Output ('баланс:          недоступен — ' + $b.error) }
}
$p = $s.primary
if ($p) {
    Write-Output ''
    Write-Output ('сессия:   ' + $p.title)
    Write-Output ('каталог:  ' + $p.cwd)
    Write-Output ('статус:   ' + $p.status + ' / ' + $p.activity.kind + ' / ' + $p.activity.tool)
    Write-Output ('шаг:      ' + $p.step + ' (всего ' + $p.steps + ')')
    $elapsed = 0
    if ($null -ne $p.elapsedMs) { $elapsed = [int]([double]$p.elapsedMs / 1000) }
    Write-Output ('идёт:     ' + $elapsed + ' c')
    Write-Output ('детали:   ' + $p.activity.detail)
    Write-Output ('план:     ' + $(if ($p.todos) { [string]$p.todos.done + ' из ' + [string]$p.todos.total } else { 'нет' }))
    Write-Output ('задачи:   активно ' + $p.jobs.active)
    if ($p.done) { Write-Output ('итог:     ' + $(if ($p.done.ok) { 'успех' } else { 'ошибка: ' + $p.done.reason })) }
}
Write-Output ''
Write-Output 'сессии:'
foreach ($x in $s.sessions) {
    $detail = [string]$x.activity.detail
    if ($detail.Length -gt 60) { $detail = $detail.Substring(0, 60) + '…' }
    Write-Output ('  [{0,-8}] {1,-40} {2,-10} {3}' -f $x.status, $x.title, $x.activity.kind, $detail)
}
if ($s.lastCompletion) {
    Write-Output ''
    Write-Output ('последнее завершение: ' + $s.lastCompletion.title + ' (' + $s.lastCompletion.reason + ')')
}
