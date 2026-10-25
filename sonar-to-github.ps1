$repo   = "YannPPV/node-express-boilerplate"
$dryRun = $true   # passe à $false pour créer vraiment les issues

if (-not $env:SONAR_TOKEN) {
  Write-Host "SONAR_TOKEN n'est pas défini. Lance d'abord : `$env:SONAR_TOKEN='sqp_...'"
  exit 1
}

$h   = @{ Authorization = "Bearer $env:SONAR_TOKEN" }
$url = "http://localhost:9000/api/issues/search?componentKeys=node-express-boilerplate&resolved=false&ps=500"
$issues = (Invoke-RestMethod $url -Headers $h).issues
Write-Host "$($issues.Count) issues Sonar trouvées"

foreach ($i in $issues) {
  $file  = $i.component -replace '^node-express-boilerplate:', ''
  $title = "[Sonar $($i.severity)] $($i.message)"
  if ($title.Length -gt 120) { $title = $title.Substring(0,117) + "..." }

  $body = @"
Problème détecté par SonarQube.

- **Règle** : ``$($i.rule)``
- **Type** : $($i.type)
- **Sévérité** : $($i.severity)
- **Fichier** : ``$file`` (ligne $($i.line))
- **Identifiant Sonar** : ``$($i.key)``

**Message** : $($i.message)
"@

  if ($dryRun) {
    Write-Host "DRY: $title  [$file`:$($i.line)]"
  } else {
    gh issue create --repo $repo --title $title --body $body
    Start-Sleep -Seconds 2
  }
}

if (-not $env:SONAR_TOKEN -and (Test-Path .env)) {
  $line = Get-Content .env | Where-Object { $_ -match '^\s*SONAR_TOKEN\s*=' } | Select-Object -First 1
  if ($line) { $env:SONAR_TOKEN = ($line -split '=', 2)[1].Trim().Trim('"') }
}
if (-not $env:SONAR_TOKEN) {
  Write-Host "SONAR_TOKEN introuvable (ni dans l'environnement, ni dans .env)"
  exit 1
}