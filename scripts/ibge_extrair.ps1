# Extrai os dados dos paineis "IBGE: IPCA-15" e "IBGE: PMC" do Dashboard.
#
# Fonte: API do SIDRA (apisidra.ibge.gov.br), com os mesmos numeros das publicacoes mensais do
# IBGE na biblioteca (IPCA-15: catalogo 72376; PMC: catalogo 7230). A biblioteca fica atras de
# protecao anti-robo e publica PDF; o SIDRA e a base estruturada oficial desses relatorios.
#   IPCA-15 -> tabela 7062 (variacao mensal, acumulada no ano, 12 meses e peso; Brasil e 11 areas)
#   PMC     -> tabelas 8880 (varejo), 8881 (varejo ampliado) e 8883 (atividades), Brasil e UFs
# Gera assets/data/ibge_ipca15.js (window.IBGE_IPCA15) e assets/data/ibge_pmc.js (window.IBGE_PMC),
# carregados sob demanda pelo Dashboard. Roda diariamente no GitHub Actions
# (.github/workflows/abve-diario.yml); so regrava um arquivo se os dados dele mudaram.
# Compativel com Windows PowerShell 5.1 e PowerShell 7 (pwsh).

$ErrorActionPreference = 'Stop'
$IPCA_ANO_INICIAL = 2023   # base de comparacao do primeiro ano exibido (2024)
$PMC_ANO_INICIAL = 2022    # PMC: o painel compara tambem a variacao do ano anterior (precisa de ano-2)
$RAIZ = Split-Path -Parent $PSScriptRoot
$CULT = [Globalization.CultureInfo]::InvariantCulture

Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromMinutes(5)
$http.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (CDLoad; extracao diaria)')

function Obter-Json([string]$url) {
  for ($t = 1; $t -le 3; $t++) {
    try {
      $resp = $http.GetAsync($url).Result
      $txt = [Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().Result)
      if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode): $($txt.Substring(0, [Math]::Min(300, $txt.Length)))" }
      return ($txt | ConvertFrom-Json)
    } catch {
      if ($t -eq 3) { throw }
      Start-Sleep -Seconds (10 * $t)
    }
  }
}
# Consulta a API de valores do SIDRA; devolve as linhas (sem o cabecalho).
function Sidra([string]$caminho) {
  $j = Obter-Json "https://apisidra.ibge.gov.br/values/$caminho"
  @($j | Select-Object -Skip 1)
}
# "0.70" -> 0.7 ; "...", "-", "X" (sem dado/sigilo) -> $null
function Valor($v) {
  $d = 0.0
  if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, $CULT, [ref]$d)) { return $d }
  $null
}
function Periodos([int]$tabela, [int]$anoIni) {
  @((Obter-Json "https://servicodados.ibge.gov.br/api/v3/agregados/$tabela/periodos") | ForEach-Object { "$($_.id)" } | Where-Object { [int]$_.Substring(0, 4) -ge $anoIni } | Sort-Object)
}
# Listas tipadas: no PowerShell 5.1, arrays acumulados com += , viram {"value":[...],"Count":n} no JSON.
function Nova-Lista { , (New-Object System.Collections.Generic.List[object]) }
# Matriz [a][b][mes] de $null, como listas (serializa limpo nas duas versoes do PowerShell).
function Nova-Matriz([int]$a, [int]$b, [int]$m) {
  $x = Nova-Lista
  for ($i = 0; $i -lt $a; $i++) { $y = Nova-Lista; for ($k = 0; $k -lt $b; $k++) { $y.Add((New-Object object[] $m)) }; $x.Add($y) }
  , $x
}
function Mes([string]$p) { '{0}-{1}' -f $p.Substring(0, 4), $p.Substring(4, 2) }
function Gravar([string]$arquivo, [string]$var, $dados, [string]$resumo) {
  $saida = Join-Path $RAIZ "assets/data/$arquivo"
  $json = $dados | ConvertTo-Json -Depth 12 -Compress
  $conteudo = "// Gerado por scripts/ibge_extrair.ps1 - nao editar a mao.`nwindow.$var = $json;`n"
  if (Test-Path $saida) {
    $semData = { param($t) $t -replace '"extraido_em":"[^"]*"', '' }
    if ((& $semData ([IO.File]::ReadAllText($saida, [Text.Encoding]::UTF8))) -eq (& $semData $conteudo)) { Write-Host "$arquivo`: sem mudancas."; return }
  }
  [IO.File]::WriteAllText($saida, $conteudo, (New-Object System.Text.UTF8Encoding $false))
  Write-Host ("Gravado {0}: {1}, {2:N0} bytes." -f $arquivo, $resumo, $conteudo.Length)
}
$agora = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

# ================= IPCA-15 (tabela 7062) =================
Write-Host 'IPCA-15...'
$meta = Obter-Json 'https://servicodados.ibge.gov.br/api/v3/agregados/7062/metadados'
# Indice geral, os 9 grupos e os itens (codigo de 4 digitos); subitens ficam de fora (volume).
$cats = @($meta.classificacoes[0].categorias | Where-Object { $_.nome -eq 'Índice geral' -or $_.nome -match '^(\d|\d{4})\.' })
$catId = @($cats | ForEach-Object { "$($_.id)" })
$catNome = @($cats | ForEach-Object { ($_.nome -replace '^\d+\.', '').Trim() })
$catNivel = @($cats | ForEach-Object { if ($_.nome -match '^(\d+)\.') { $matches[1].Length } else { 0 } })
$catGrupo = @($cats | ForEach-Object { if ($_.nome -match '^(\d)') { [int]$matches[1] - 1 } else { -1 } })
$iCat = @{}; for ($i = 0; $i -lt $catId.Count; $i++) { $iCat[$catId[$i]] = $i }
$perI = Periodos 7062 $IPCA_ANO_INICIAL
$mesesI = @($perI | ForEach-Object { Mes $_ })
$iMesI = @{}; for ($i = 0; $i -lt $perI.Count; $i++) { $iMesI[$perI[$i]] = $i }
$locCod = Nova-Lista; $locNome = Nova-Lista; $iLoc = @{}
$VAR_I = [ordered]@{ '355' = 'mensal'; '356' = 'ano'; '1120' = 'm12'; '357' = 'peso' }
$matI = @{}
foreach ($ano in @($perI | ForEach-Object { $_.Substring(0, 4) } | Sort-Object -Unique)) {
  Write-Host "  $ano"
  $ps = @($perI | Where-Object { $_.StartsWith($ano) })
  $rows = Sidra ("t/7062/n1/all/n7/all/n6/all/v/355,356,1120,357/p/{0}-{1}/c315/{2}" -f $ps[0], $ps[-1], ($catId -join ','))
  foreach ($r in $rows) {
    $lc = "$($r.D1C)"
    if (-not $iLoc.ContainsKey($lc)) {
      $iLoc[$lc] = $locCod.Count; $locCod.Add($lc); $locNome.Add(("$($r.D1N)" -replace '\s*-\s*[A-Z]{2}$', ''))
      foreach ($k in $VAR_I.Values) { if (-not $matI.ContainsKey($k)) { $matI[$k] = @{} } ; $matI[$k][$lc] = (Nova-Matriz 1 $catId.Count $perI.Count)[0] }
    }
    $nomeVar = $VAR_I["$($r.D2C)"]
    if (-not $nomeVar -or -not $iCat.ContainsKey("$($r.D4C)") -or -not $iMesI.ContainsKey("$($r.D3C)")) { continue }
    $v = Valor $r.V
    if ($null -ne $v) { $matI[$nomeVar][$lc][$iCat["$($r.D4C)"]][$iMesI["$($r.D3C)"]] = [Math]::Round($v, 2) }
  }
}
if ($locCod.Count -lt 2 -or $perI.Count -lt 13) { throw "IPCA-15: dados insuficientes ($($locCod.Count) locais, $($perI.Count) meses)." }
# Brasil primeiro; as areas em ordem alfabetica.
$ordem = @(0..($locCod.Count - 1) | Sort-Object { if ($locCod[$_] -eq '1') { '' } else { $locNome[$_] } })
$ipca = [ordered]@{
  fonte = 'IBGE · IPCA-15 (SIDRA, tabela 7062)'; extraido_em = $agora; meses = $mesesI
  locais = [ordered]@{ cod = @($ordem | ForEach-Object { $locCod[$_] }); nomes = @($ordem | ForEach-Object { $locNome[$_] }) }
  cats = [ordered]@{ nomes = $catNome; nivel = $catNivel; grupo = $catGrupo }
}
foreach ($k in $VAR_I.Values) {
  $lst = Nova-Lista
  foreach ($o in $ordem) {
    $porCat = Nova-Lista
    # acumulados so para o indice geral e os grupos (itens: o painel acumula a partir do mensal)
    for ($c = 0; $c -lt $catId.Count; $c++) { if (($k -eq 'ano' -or $k -eq 'm12') -and $catNivel[$c] -eq 4) { $porCat.Add($null) } else { $porCat.Add([object[]]$matI[$k][$locCod[$o]][$c]) } }
    $lst.Add($porCat)
  }
  $ipca[$k] = $lst
}
Gravar 'ibge_ipca15.js' 'IBGE_IPCA15' $ipca ("{0} meses ({1} a {2}), {3} locais, {4} categorias" -f $mesesI.Count, $mesesI[0], $mesesI[-1], $locCod.Count, $catId.Count)

# ================= PMC (tabelas 8880, 8881, 8883) =================
Write-Host 'PMC...'
$perP = Periodos 8880 $PMC_ANO_INICIAL
$mesesP = @($perP | ForEach-Object { Mes $_ })
$iMesP = @{}; for ($i = 0; $i -lt $perP.Count; $i++) { $iMesP[$perP[$i]] = $i }
$faixa = '{0}-{1}' -f $perP[0], $perP[-1]
$ufCod = Nova-Lista; $ufNome = Nova-Lista; $iUf = @{}
function Uf($r) {
  $c = "$($r.D1C)"
  if (-not $iUf.ContainsKey($c)) { $iUf[$c] = $ufCod.Count; $ufCod.Add($c); $ufNome.Add("$($r.D1N)") }
  $iUf[$c]
}
# series[chave][iUf] = valores mensais; chave = "<total|atividade>|<vol|rec>|<idx|saz>"
$serieP = @{}
function Guardar($chave, [int]$iu, [string]$per, $v) {
  if (-not $serieP.ContainsKey($chave)) { $serieP[$chave] = @{} }
  if (-not $serieP[$chave].ContainsKey($iu)) { $serieP[$chave][$iu] = New-Object object[] $perP.Count }
  if ($null -ne $v -and $iMesP.ContainsKey($per)) { $serieP[$chave][$iu][$iMesP[$per]] = [Math]::Round($v, 2) }
}
$MAPA_TIPO = @{ '56733' = 'vol'; '56734' = 'vol'; '56735' = 'vol'; '56736' = 'vol' }
$MAPA_TIPO['56733'] = 'rec'; $MAPA_TIPO['56735'] = 'rec'   # receita nominal; 56734/56736 = volume
foreach ($par in @(@(8880, 'varejo'), @(8881, 'ampliado'))) {
  Write-Host "  tabela $($par[0])"
  foreach ($r in (Sidra ("t/{0}/n1/all/n3/all/v/7169,7170/p/{1}/c11046/all" -f $par[0], $faixa))) {
    $iu = Uf $r
    $tipo = $MAPA_TIPO["$($r.D4C)"]; if (-not $tipo) { continue }
    $suf = if ("$($r.D2C)" -eq '7170') { 'saz' } else { 'idx' }
    Guardar "$($par[1])|$tipo|$suf" $iu "$($r.D3C)" (Valor $r.V)
  }
}
$meta8883 = Obter-Json 'https://servicodados.ibge.gov.br/api/v3/agregados/8883/metadados'
$ativ = @(($meta8883.classificacoes | Where-Object { $_.id -eq 85 }).categorias)
$ativId = @($ativ | ForEach-Object { "$($_.id)" }); $ativNome = @($ativ | ForEach-Object { $_.nome })
foreach ($ano in @($perP | ForEach-Object { $_.Substring(0, 4) } | Sort-Object -Unique)) {
  Write-Host "  atividades $ano"
  $ps = @($perP | Where-Object { $_.StartsWith($ano) })
  foreach ($r in (Sidra ("t/8883/n1/all/n3/all/v/7169/p/{0}-{1}/c11046/all/c85/all" -f $ps[0], $ps[-1]))) {
    $iu = Uf $r
    $tipo = $MAPA_TIPO["$($r.D4C)"]; if (-not $tipo) { continue }
    Guardar "a$([array]::IndexOf($ativId, "$($r.D5C)"))|$tipo|idx" $iu "$($r.D3C)" (Valor $r.V)
  }
}
if ($ufCod.Count -lt 20 -or $perP.Count -lt 25) { throw "PMC: dados insuficientes ($($ufCod.Count) locais, $($perP.Count) meses)." }
$ordemP = @(0..($ufCod.Count - 1) | Sort-Object { if ($ufCod[$_] -eq '1') { '' } else { $ufNome[$_] } })
function Matriz-Serie([string]$chave) {
  $l = Nova-Lista
  foreach ($o in $ordemP) { $x = if ($serieP.ContainsKey($chave) -and $serieP[$chave].ContainsKey($o)) { $serieP[$chave][$o] } else { New-Object object[] $perP.Count }; $l.Add([object[]]$x) }
  , $l
}
$pmc = [ordered]@{
  fonte = 'IBGE · Pesquisa Mensal de Comércio (SIDRA, tabelas 8880, 8881 e 8883)'; extraido_em = $agora; meses = $mesesP
  locais = [ordered]@{ cod = @($ordemP | ForEach-Object { $ufCod[$_] }); nomes = @($ordemP | ForEach-Object { $ufNome[$_] }) }
  atividades = $ativNome
  # [iLocal][iMes] — números-índice (2022 = 100)
  varejo = [ordered]@{ vol = (Matriz-Serie 'varejo|vol|idx'); rec = (Matriz-Serie 'varejo|rec|idx'); volSaz = (Matriz-Serie 'varejo|vol|saz') }
  ampliado = [ordered]@{ vol = (Matriz-Serie 'ampliado|vol|idx'); rec = (Matriz-Serie 'ampliado|rec|idx') }
  # [iAtividade][iLocal][iMes]
  ativVol = (Nova-Lista); ativRec = (Nova-Lista)
}
for ($a = 0; $a -lt $ativId.Count; $a++) { $pmc.ativVol.Add((Matriz-Serie "a$a|vol|idx")); $pmc.ativRec.Add((Matriz-Serie "a$a|rec|idx")) }
Gravar 'ibge_pmc.js' 'IBGE_PMC' $pmc ("{0} meses ({1} a {2}), {3} locais, {4} atividades" -f $mesesP.Count, $mesesP[0], $mesesP[-1], $ufCod.Count, $ativId.Count)
