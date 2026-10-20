#requires -Version 7

$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/service-ops.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $function.Extent.Text}
function Assert($condition,$message){if(-not $condition){throw $message}}
Assert ((Resolve-Date 20260818) -ceq '20260818') 'numeric YYYYMMDD normalization failed'
foreach($date in @('20260230','2026-08-18', "20260928';touch file")){
    $failed=$false
    try{Resolve-Date $date | Out-Null}catch{$failed=$true}
    Assert $failed "invalid date accepted: $date"
}
Assert ((Resolve-Time '2026-09-28 00:10' -End) -eq '2026-09-28 00:10:59') 'end minute must include its final second'
Assert ((Resolve-Time '2026-09-28 00:10') -eq '2026-09-28 00:10:00') 'start minute must begin at second zero'
Write-Host 'PASS: numeric dates, impossible dates, injection input and minute boundaries'
