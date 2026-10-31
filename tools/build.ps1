param(
    [Parameter(Mandatory=$true)][ValidateSet('main','slave')][string]$Board,
    [string]$Python = 'python',
    [string]$Td = '',
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$BuildArgs = @('-B', '-X', 'utf8', (Join-Path $PSScriptRoot 'build.py'), '--board', $Board)
if ($Td) { $BuildArgs += @('--td', $Td) }
if ($CheckOnly) { $BuildArgs += '--check-only' }
& $Python @BuildArgs
exit $LASTEXITCODE
