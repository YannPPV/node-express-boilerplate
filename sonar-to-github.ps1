param(
  [string]$PreviewDir = (Join-Path ([IO.Path]::GetTempPath()) "sonar-preview")
)

$repo       = "YannPPV/node-express-boilerplate"
$projectKey = "node-express-boilerplate"
$sonarUrl   = "http://localhost:9000"
$dryRun     = $true   # passe à $false pour créer vraiment les issues

# Le token vient de l'environnement, sinon de .env (ignoré par Git). Il n'est jamais affiché.
if (-not $env:SONAR_TOKEN -and (Test-Path .env)) {
  $line = Get-Content .env | Where-Object { $_ -match '^\s*SONAR_TOKEN\s*=' } | Select-Object -First 1
  if ($line) { $env:SONAR_TOKEN = ($line -split '=', 2)[1].Trim().Trim('"') }
}
if (-not $env:SONAR_TOKEN) {
  Write-Host "SONAR_TOKEN introuvable (ni dans l'environnement, ni dans .env). Lance d'abord : `$env:SONAR_TOKEN='sqp_...'"
  exit 1
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  $env:PATH = "C:\Program Files\GitHub CLI;$env:PATH"
}

# ---------------------------------------------------------------------------
# Récupération des issues Sonar : ouvertes + faux positifs S2699 (documentés)
# ---------------------------------------------------------------------------
$h = @{ Authorization = "Bearer $env:SONAR_TOKEN" }
function Get-SonarIssues([string]$query) {
  $all = @(); $page = 1
  do {
    $resp = Invoke-RestMethod "$sonarUrl/api/issues/search?componentKeys=$projectKey&ps=500&p=$page&$query" -Headers $h
    $all += $resp.issues; $page++
  } while ($all.Count -lt $resp.paging.total)
  $all
}
$sonar = @(Get-SonarIssues "resolved=false") + @(Get-SonarIssues "rules=javascript:S2699&resolutions=FALSE-POSITIVE")
foreach ($i in $sonar) {
  $i | Add-Member -NotePropertyName File -NotePropertyValue ($i.component -replace "^$([regex]::Escape($projectKey)):", '') -Force
}
Write-Host "$($sonar.Count) issues Sonar récupérées (ouvertes + faux positifs S2699)"

# ---------------------------------------------------------------------------
# Catalogue : un élément = un problème. L'ordre du catalogue = ordre de création
# (priorité, puis catégorie : Security > bug > maintenance > tests).
# Action : new (nouvelle issue), closed (créée puis fermée).
# Related : issues proches (affiché dans « Issues liées »).
# Ref : identifiant de la section correspondante dans le plan de correction (hors dépôt).
# ---------------------------------------------------------------------------
$catalog = @(
  @{ Ref = 'C-01'; Id = 'cors'; Rule = 'javascript:S5122'; File = 'src/app.js'; Action = 'new'; Priority = 'medium'; Category = 'Security'
     Problem = '`cors()` sans options autorise toutes les origines : n''importe quel site peut appeler l''API depuis le navigateur d''un visiteur.'
     Fix     = 'Restreindre les origines via une variable `CORS_ORIGIN` (config Joi + `cors({ origin })` sur les deux appels). Décider de l''origine par défaut.'
     Check   = '`npx eslint src/app.js src/config/config.js`, `yarn test`, requête avec `Origin: https://evil.example` refusée.'
     Related = 'proche de #17 (même problème, relevé à l''atelier 1, hors périmètre de cette correction).' },
  @{ Ref = 'C-02'; Id = 'docker'; Rule = 'docker:S6470'; File = 'Dockerfile'; Action = 'new'; Priority = 'medium'; Category = 'Security'
     Problem = '`COPY --chown=node:node . .` copie tout le dossier dans l''image, et `.dockerignore` n''exclut pas `.env` : les secrets se retrouvent dans l''image.'
     Fix     = 'Ajouter `.env*`, `!.env.example`, `coverage`, `.scannerwork`, `.vscode` au `.dockerignore` (ne pas toucher au `Dockerfile`).'
     Check   = '`docker build -t node-app .` puis `docker run --rm node-app ls -a` : pas de `.env`.'
     Related = 'proche de #13 (même problème, relevé à l''atelier 1, hors périmètre de cette correction).' },
  @{ Ref = 'C-03'; Id = 'smtp'; Rule = 'javascript:S5332'; File = 'src/services/email.service.js'; Action = 'new'; Priority = 'medium'; Category = 'Security'
     Problem = 'Le transport SMTP n''impose pas TLS : identifiants et e-mails (liens de réinitialisation) peuvent passer en clair.'
     Fix     = 'Ajouter `secure` et `requireTLS: true` dans `config.email.smtp` (`src/config/config.js`).'
     Check   = '`npx eslint src/config/config.js`, `yarn test`, démarrage avec un compte Ethereal.' },
  @{ Ref = 'C-04'; Id = 'bin-catch'; Rule = 'javascript:S905'; File = 'bin/createNodejsApp.js'; Action = 'new'; Priority = 'medium'; Category = 'bug'
     Problem = 'Dans `runCmd()`, le `catch` contient une fonction jamais appelée : les erreurs sont avalées : si `git clone` échoue, le script affiche « Cloned successfully. », lance `yarn install` dans le mauvais dossier puis plante plus loin (`ENOENT`).'
     Fix     = 'Supprimer le `try/catch` de `runCmd()` pour que l''erreur remonte à `setup()`. Même commit que C-07.'
     Check   = '`node --check bin/createNodejsApp.js` (`bin/` est exclu du lint), test avec une URL de dépôt invalide : erreur affichée une fois, arrêt immédiat.'
     Related = 'à corriger avec l''issue « setup() sans gestion de la promesse » (même fichier, même commit).' },
  @{ Ref = 'C-05'; Id = 'bin-path'; Rule = 'javascript:S4036'; File = 'bin/createNodejsApp.js'; Action = 'new'; Priority = 'low'; Category = 'Security'
     Problem = '`execSync(''yarnpkg --version'')` dépend du `PATH`. Risque faible : script lancé localement par un développeur.'
     Fix     = 'Retirer le `await` inutile, puis accepter le risque dans SonarQube (« Accept ») avec justification.'
     Check   = '`node --check bin/createNodejsApp.js`, issue acceptée au prochain scan.' },
  @{ Ref = 'C-06'; Id = 'index-promise'; Rule = 'javascript:S9383'; File = 'src/index.js'; Action = 'new'; Priority = 'low'; Category = 'bug'
     Problem = '`mongoose.connect(...)` n''a pas de `.catch()`. L''erreur est déjà rattrapée par le handler global `unhandledRejection` : le comportement est correct mais implicite.'
     Fix     = 'Ajouter `.catch()` qui journalise et quitte avec le code 1 (chaîne formatée au style Prettier, voir plan).'
     Check   = '`npx eslint src/index.js`, `yarn test`, démarrage avec une `MONGODB_URL` invalide.'
 },
  @{ Ref = 'C-07'; Id = 'bin-promise'; Rule = 'javascript:S9383'; File = 'bin/createNodejsApp.js'; Action = 'new'; Priority = 'low'; Category = 'bug'
     Problem = '`setup();` est appelé sans gérer la promesse, et le script se termine avec le code 0 même en cas d''échec.'
     Fix     = 'Dans le `catch` de `setup()` : afficher `error.message` et `process.exitCode = 1` ; ajouter `.catch()` à l''appel. Même commit que C-04.'
     Check   = '`node --check bin/createNodejsApp.js`, code de sortie 1 en cas d''échec.'
     Related = 'à corriger avec l''issue « runCmd() avale les erreurs » (même fichier, même commit).' },
  @{ Ref = 'C-08'; Id = 'reduce'; Rule = 'javascript:S6959'; File = 'src/models/plugins/paginate.plugin.js'; Action = 'new'; Priority = 'low'; Category = 'bug'
     Problem = '`reduce()` sans valeur initiale (option `populate`). Pas de plantage aujourd''hui, mais code fragile.'
     Fix     = 'Réécrire avec le dernier élément comme valeur initiale, **sans changer le résultat** (ne pas utiliser `{}`).'
     Check   = '`yarn test tests/unit/models/plugins/paginate.plugin.test.js`.'
     Related = 'même fichier que l''issue « parseInt » : commits séparés.' },
  @{ Ref = 'C-09'; Id = 'parseint'; Rule = 'javascript:S7773'; File = 'src/models/plugins/paginate.plugin.js'; Action = 'new'; Priority = 'low'; Category = 'maintenance'
     Title   = "[Sonar MINOR] Prefer ``Number.parseInt`` over ``parseInt`` (x4) (src/models/plugins/paginate.plugin.js:35-36)"
     Problem = '4 appels à `parseInt` global (calcul de `limit` et `page`).'
     Fix     = 'Remplacer par `Number.parseInt` (même comportement).'
     Check   = '`yarn test tests/unit/models/plugins/paginate.plugin.test.js`.'
     Related = 'même fichier que l''issue « reduce() » : commits séparés.' },
  @{ Ref = 'C-10'; Id = 'tests'; Rule = 'javascript:S2699'; File = 'tests/'; Action = 'closed'; Priority = 'low'; Category = 'tests'
     Title   = "[Sonar BLOCKER] Add at least one assertion to this test case : 55 faux positifs (tests/integration)"
     Problem = '55 tests signalés « sans assertion ». **Faux positifs** : ils vérifient le code HTTP avec supertest (`.expect(httpStatus.X)`), que la règle ne reconnaît pas.'
     Fix     = 'Aucun changement de code. Les 55 issues sont passées en « False Positive » dans SonarQube le 25/10/2026.'
     Check   = 'SonarQube : 0 issue S2699 ouverte.' }
)

$labelColors = @{
  sonarqube = "4E9BCD"; "sonar: blocker" = "B60205"; "sonar: critical" = "D93F0B"; "sonar: major" = "FBCA04"
  "sonar: minor" = "0E8A16"; "sonar: info" = "C5DEF5"; maintenance = "BFD4F2"; tests = "D4C5F9"
}

# ---------------------------------------------------------------------------
# Construction des issues (corps courts)
# ---------------------------------------------------------------------------
$used  = @{}
$plans = foreach ($d in $catalog) {
  $m = @($sonar | Where-Object { $_.rule -eq $d.Rule -and $_.File.StartsWith($d.File) -and -not $used[$_.key] } |
         Sort-Object File, line)
  if (-not $m) { Write-Host "Aucune issue Sonar pour '$($d.Id)' ($($d.Rule)) : ignoré" -ForegroundColor Yellow; continue }
  $m | ForEach-Object { $used[$_.key] = $true }
  $first = $m[0]
  $sev   = $first.severity

  $title = if ($d.Title) { $d.Title } else {
    $msg = $first.message; if ($msg.Length -gt 80) { $msg = $msg.Substring(0, 77) + "..." }
    "[Sonar $sev] $msg ($($first.File):$($first.line))"
  }

  $lines = ($m | ForEach-Object { $_.line } | Sort-Object -Unique)
  $where = if ($m.Count -gt 5) { "$($m.Count) tests dans ``tests/integration/`` (liste via le lien SonarQube ci-dessous)" }
           else { "``$($first.File)``, ligne(s) $($lines -join ', ')" }
  $link  = if ($m.Count -eq 1) { "$sonarUrl/project/issues?id=$projectKey&issues=$($first.key)&open=$($first.key)" }
           else { "$sonarUrl/project/issues?id=$projectKey&rules=$([uri]::EscapeDataString($first.rule))" }
  $sonarLine = "**Sonar** : ``$($first.rule)`` · $sev · $($m.Count) issue(s) · [voir dans SonarQube]($link)"
  $guideLine = "**Réf. plan de correction** : $($d.Ref)"
  $marker    = "<!-- sonar:$($d.Id) -->"

  $body = @("## Problème", $d.Problem, "", "**Emplacement** : $where", "", "## Correction", $d.Fix, "",
            "**Validation** : $($d.Check)", "")
  if ($d.Related) { $body += @("**Issues liées** : $($d.Related)", "") }
  $body += @($guideLine, "", $sonarLine, "",
             "_Priorité **$($d.Priority)**, évaluée selon l'impact réel (pas la sévérité Sonar)._", $marker)

  [pscustomobject]@{
    Ref    = $d.Ref
    Id     = $d.Id
    Action = $d.Action
    Title  = $title
    Body   = ($body -join "`n")
    Labels = @("sonarqube", "sonar: $($sev.ToLower())", "priority: $($d.Priority)", $d.Category)
    Sonar  = $m
  }
}

$orphans = @($sonar | Where-Object { -not $used[$_.key] })
if ($orphans) {
  Write-Host "ATTENTION : $($orphans.Count) issue(s) Sonar sans entrée dans le catalogue (non traitées) :" -ForegroundColor Yellow
  $orphans | ForEach-Object { Write-Host "  $($_.rule) $($_.File):$($_.line) $($_.message)" }
}

if ($dryRun) {
  New-Item -ItemType Directory -Force $PreviewDir | Out-Null
  Get-ChildItem $PreviewDir -Filter *.md | Remove-Item
  $n = 0
  foreach ($p in $plans) {
    $n++
    $what = if ($p.Action -eq 'closed') { "NOUVELLE puis fermée" } else { "NOUVELLE" }
    "# $($p.Title)`n`nLabels : $($p.Labels -join ', ')`n`n---`n`n$($p.Body)" |
      Set-Content (Join-Path $PreviewDir ("{0:D2}-{1}.md" -f $n, $p.Id)) -Encoding utf8
    Write-Host ("{0,2}. {1,-21} {2}  [{3}] ({4} issue(s) Sonar)" -f $n, $what, $p.Title, ($p.Labels -join ', '), $p.Sonar.Count)
  }
  Write-Host "`nSimulation : $($plans.Count) issues à créer (dont $(@($plans | Where-Object Action -eq 'closed').Count) fermée aussitôt), $(($plans.Sonar).Count) issues Sonar couvertes."
  Write-Host "Aperçus : $PreviewDir. Rien n'a été envoyé à GitHub."
  exit 0
}

# ---------------------------------------------------------------------------
# Envoi vers GitHub (une seule passe, sans doublon en cas de reprise)
# ---------------------------------------------------------------------------
foreach ($l in ($plans.Labels | Sort-Object -Unique)) {
  $color = if ($labelColors[$l]) { $labelColors[$l] } else { "EDEDED" }
  gh label create $l --repo $repo --color $color 2>$null | Out-Null   # erreur = label déjà présent
}

$existing = @{}
gh issue list --repo $repo --state all --limit 1000 --json number,title | ConvertFrom-Json |
  ForEach-Object { $existing[$_.title] = $_.number }

$bodyFile = Join-Path ([IO.Path]::GetTempPath()) "sonar-issue-body.md"
$created = 0; $skipped = 0; $errors = @()
foreach ($p in $plans) {
  Set-Content -Path $bodyFile -Value $p.Body -Encoding utf8

  if ($existing.ContainsKey($p.Title)) {
    $skipped++
    Write-Host "IGNORÉE (existe déjà, #$($existing[$p.Title])) : $($p.Title)"
  } else {
    $labelArgs = $p.Labels | ForEach-Object { "--label"; $_ }
    $out = gh issue create --repo $repo --title $p.Title --body-file $bodyFile @labelArgs 2>&1
    if ($LASTEXITCODE -eq 0 -and "$out" -match '/issues/(\d+)') {
      $number = [int]$Matches[1]; $created++
      Write-Host "CRÉÉE #$number : $($p.Title)"
      if ($p.Action -eq 'closed') {
        Start-Sleep -Seconds 2
        gh issue close $number --repo $repo --reason "not planned" --comment "Faux positifs traités dans SonarQube (False Positive) le 25/10/2026. Aucun changement de code nécessaire." | Out-Null
      }
    } else {
      $errors += "$($p.Title) -> $out"
      Write-Host "ERREUR : $($p.Title) -> $out" -ForegroundColor Red
    }
    Start-Sleep -Seconds 2
  }
}
Remove-Item $bodyFile -ErrorAction SilentlyContinue

Write-Host "`nCréées : $created | Ignorées (déjà faites) : $skipped | Erreurs : $($errors.Count)"
$errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
