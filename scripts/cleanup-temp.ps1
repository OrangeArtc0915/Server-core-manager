# @scm-id cleanup-temp
# @scm-name 清理临时文件
# @scm-desc 清理用户/系统临时目录中 1 天前的文件、7 天前的 CBS 日志，并清空回收站。
# @scm-risk medium

$ErrorActionPreference = 'Continue'
$cutoff = (Get-Date).AddDays(-1)
$script:freed = 0
$script:count = 0

function Clear-ScmDir {
    param([string]$Path, [datetime]$OlderThan)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -ge $OlderThan) { continue }
        try {
            $len = $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $script:freed += $len
            $script:count++
        } catch { }
    }
}

Clear-ScmDir -Path $env:TEMP -OlderThan $cutoff
Clear-ScmDir -Path (Join-Path $env:windir 'Temp') -OlderThan $cutoff
Clear-ScmDir -Path (Join-Path $env:windir 'Logs\CBS') -OlderThan (Get-Date).AddDays(-7)

try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch { }

"清理完成：删除 {0} 个文件，释放 {1:N1} MB" -f $script:count, ($script:freed / 1MB)
