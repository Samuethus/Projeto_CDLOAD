# Extrai os dados do painel "Sefaz MT (ICMS)" do Dashboard.
#
# Fonte: "Dashboard de Arrecadacao de Tributos e Contribuicoes" da Sefaz MT (UPER),
# relatorio publico do Looker Studio:
#   https://datastudio.google.com/reporting/e84e7e17-1dee-48d4-bbb9-38639ed431eb
# Gera assets/data/sefaz_icms.js (window.SEFAZ_ICMS), carregado sob demanda pelo Dashboard.
# Roda diariamente no GitHub Actions (.github/workflows/abve-diario.yml); so regrava o
# arquivo se os dados mudaram.
#
# Como funciona: o Looker Studio so aceita, para quem apenas visualiza, consultas identicas
# as dos graficos do proprio relatorio (senao responde PREFETCH_VALIDATION). Por isso as duas
# consultas abaixo sao copias dos componentes reais do relatorio (a tabela de "Baixar dados"
# da aba "ICMS por municipio" e a tabela detalhada da aba "ICMS por CNAE"); o script troca so
# o valor do filtro de periodo, como faria quem usa os filtros do relatorio.
# Se a Sefaz refizer esses graficos, os IDs mudam e o script falha (sem apagar os dados
# anteriores): basta capturar de novo as requisicoes "batchedDataV2" no navegador (F12).
#
# Formato (mensal, a partir de ANO_INICIAL; valores em reais, inteiros):
#   meses: ['2022-01', ...]               meses com arrecadacao publicada por municipio
#   regioes: [...]                        regioes fiscais (RF)
#   mun:  { nomes, ibge, reg, v }         v[iMun][iMes] = ICMS (principal + Fundo da Pobreza)
#   cnae: { macros, setores: {nomes, macro}, segs: {nomes, setor},
#           real, prev, corr                [iSeg][iMes] realizado / previsto / realizado corrigido
#           subs: {nomes, cod, seg, v} }    as TOP_SUB subclasses com maior arrecadacao no periodo
# Compativel com Windows PowerShell 5.1 e PowerShell 7 (pwsh, usado no GitHub Actions).

$ErrorActionPreference = 'Stop'
$ANO_INICIAL = 2022   # base de comparacao do primeiro ano exibido (2023)
$TOP_SUB = 150
$RAIZ = Split-Path -Parent $PSScriptRoot
$SAIDA = Join-Path $RAIZ 'assets/data/sefaz_icms.js'
$URL = 'https://datastudio.google.com/batchedDataV2?appVersion=20260926_0600'
$REFERER = 'https://datastudio.google.com/reporting/e84e7e17-1dee-48d4-bbb9-38639ed431eb'

# Componente cd-x14axbaigd (aba "ICMS por municipio"): ANO, COD_MUN, COD_MUN_IBGE, data, MUNICIPIO, RF, VALOR
$TPL_MUN = @'
{"requestContext":{"reportContext":{"reportId":"e84e7e17-1dee-48d4-bbb9-38639ed431eb","pageId":"54914900","mode":1,"componentId":"cd-x14axbaigd","displayType":"simple-table"},"requestMode":0},"datasetSpec":{"dataset":[{"datasourceId":"d490654c-956c-4de9-a44a-e64046ab5f41","revisionNumber":0,"parameterOverrides":[]}],"queryFields":[{"name":"qt_8z5w5f91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_64962_","aggregation":0}},{"name":"qt_2zux6f91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_1660613695_"}},{"name":"qt_zo1s7f91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_949732279_"}},{"name":"qt_04wn9f91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_3076010_"}},{"name":"qt_5h5idg91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_n1260148787_"}},{"name":"qt_xn0cfg91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_2612_"}},{"name":"qt_n1nvsfveld","datasetNs":"d0","tableNs":"t0","resultTransformation":{"analyticalFunction":0,"isRelativeToBase":false,"bypassCanvasFilters":false},"dataTransformation":{"sourceFieldName":"_81434788_","aggregation":6}}],"sortData":[{"sortColumn":{"name":"qt_8z5w5f91jd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_64962_","aggregation":0}},"sortDir":1}],"includeRowsCount":true,"relatedDimensionMask":{"addDisplay":false,"addUniqueId":false,"addLatLong":false},"paginateInfo":{"startRow":1,"rowsCount":50000},"dsFilterOverrides":[],"filters":[{"filterDefinition":{"filterExpression":{"include":true,"conceptType":0,"concept":{"name":"qt_64b6a3xefd","ns":"t0"},"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_64962_","aggregation":0}},"filterConditionType":"IN","numberValues":[2026]}},"dataSubsetNs":{"datasetNs":"d0","tableNs":"t0","contextNs":"c0"},"version":3,"isCanvasFilter":true}],"features":[],"dateRanges":[],"contextNsCount":1,"calculatedField":[],"needGeocoding":false,"geoFieldMask":[],"multipleGeocodeFields":[],"timezone":"America/Sao_Paulo"},"role":"main"}
'@
# Componente cd-h3l8e99hgd (aba "ICMS por CNAE"): grande setor, setor, subsetor, subsetor MT,
# subclasse, cod. CNAE, (repetidos), ano, mes, ICMS previsto, ICMS realizado, realizado corrigido
$TPL_CNAE = @'
{"requestContext":{"reportContext":{"reportId":"e84e7e17-1dee-48d4-bbb9-38639ed431eb","pageId":"p_kkfvwjyefd","mode":1,"componentId":"cd-h3l8e99hgd","displayType":"simple-table","actionId":"crossFilters|reportDefault"},"requestMode":0},"datasetSpec":{"dataset":[{"datasourceId":"ea2a05a2-56b2-401a-8f97-f8ed1519bef1","revisionNumber":0,"parameterOverrides":[]},{"datasourceId":"8c2834bf-99b2-40f2-8cac-bf44a74949ea","revisionNumber":0,"parameterOverrides":[]}],"queryFields":[{"name":"qt_cwhzv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_C__dv0"}},{"name":"qt_dwhzv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_F__dv0"}},{"name":"qt_ewhzv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_I__dv0"}},{"name":"qt_fwhzv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_L__dv0"}},{"name":"qt_gwhzv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_N__dv0"}},{"name":"qt_aoizv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_A__dv0"}},{"name":"qt_eoizv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_C__dv0"}},{"name":"qt_foizv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_F__dv0"}},{"name":"qt_goizv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_I__dv0"}},{"name":"qt_hoizv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_L__dv0"}},{"name":"qt_1txkbk59gd","datasetNs":"d1","tableNs":"t0","dataTransformation":{"sourceFieldName":"calc_b3res97hgd_dv0"}},{"name":"qt_ao8j3mv9jd","datasetNs":"d1","tableNs":"t0","resultTransformation":{"analyticalFunction":0,"isRelativeToBase":false,"bypassCanvasFilters":false},"dataTransformation":{"sourceFieldName":"_B__dv0"}},{"name":"qt_ladty7ueld","datasetNs":"d1","tableNs":"t0","resultTransformation":{"analyticalFunction":0,"isRelativeToBase":false,"bypassCanvasFilters":false},"dataTransformation":{"sourceFieldName":"_C__dv1","aggregation":6}},{"name":"qt_7pse17ueld","datasetNs":"d1","tableNs":"t0","resultTransformation":{"analyticalFunction":0,"isRelativeToBase":false,"bypassCanvasFilters":false},"dataTransformation":{"sourceFieldName":"_D__dv0","aggregation":6}},{"name":"qt_tf8s57ueld","datasetNs":"d1","tableNs":"t0","resultTransformation":{"analyticalFunction":0,"isRelativeToBase":false,"bypassCanvasFilters":false},"dataTransformation":{"sourceFieldName":"_F__dv1","aggregation":6}}],"sortData":[{"sortColumn":{"name":"qt_cwhzv99hgd","datasetNs":"d0","tableNs":"t0","dataTransformation":{"sourceFieldName":"_C__dv0"}},"sortDir":1}],"includeRowsCount":true,"relatedDimensionMask":{"addDisplay":false,"addUniqueId":false,"addLatLong":false},"paginateInfo":{"startRow":1,"rowsCount":50000},"blendConfig":{"blockDatasource":{"blocks":[{"id":"block_43whvp8hgd","type":6,"inputBlockIds":[],"outputBlockIds":[],"fields":[],"isExperimental":true,"treeQueryBlockConfig":{"join":{"right":{"query":{"concepts":[{"id":{"id":"t0.qt_tu38xr8hgd","name":"qt_tu38xr8hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_A_","aggregation":0}},"isDummy":false},{"id":{"id":"t0.qt_krqfcoamid","name":"qt_krqfcoamid","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_B_"}},"isDummy":false},{"id":{"id":"t0.qt_e29fesamid","name":"qt_e29fesamid","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"calc_b3res97hgd"}}},{"id":{"id":"t0.qt_elb18o9hgd","name":"qt_elb18o9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_C_","aggregation":6}},"isDummy":false},{"id":{"id":"t0.qt_nbp89o9hgd","name":"qt_nbp89o9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_D_","aggregation":6}},"isDummy":false},{"id":{"id":"t0.qt_4hppbp9hgd","name":"qt_4hppbp9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_F_","aggregation":6}},"isDummy":false}],"datasourceId":"8c2834bf-99b2-40f2-8cac-bf44a74949ea","dateRangeDimension":{"id":{"id":"t0.qt_k6g3gs9hgd","name":"qt_k6g3gs9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"calc_b3res97hgd"}}}}},"left":{"query":{"datasourceId":"ea2a05a2-56b2-401a-8f97-f8ed1519bef1","concepts":[{"id":{"id":"t0.qt_r5osgr8hgd","name":"qt_r5osgr8hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_A_","aggregation":0}},"isDummy":false},{"id":{"id":"t0.qt_vrk8lj9hgd","name":"qt_vrk8lj9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_C_"}},"isDummy":false},{"id":{"id":"t0.qt_kfgukk9hgd","name":"qt_kfgukk9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_F_"}},"isDummy":false},{"id":{"id":"t0.qt_pvssdl9hgd","name":"qt_pvssdl9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_I_"}},"isDummy":false},{"id":{"id":"t0.qt_e5n25l9hgd","name":"qt_e5n25l9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_L_"}},"isDummy":false},{"id":{"id":"t0.qt_3qdytm9hgd","name":"qt_3qdytm9hgd","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_N_"}},"isDummy":false},{"id":{"id":"t0.qt_hhmszqdvld","name":"qt_hhmszqdvld","namespace":"t0"},"semantic":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_M_"}}}]}},"condition":{"and":{"conditions":[{"boolean":{"joinKeyPair":{"leftName":"qt_r5osgr8hgd","rightName":"qt_tu38xr8hgd"}}}]}},"type":1}}}],"datasourceBlock":{"id":"block_33whvp8hgd","type":1,"inputBlockIds":[],"outputBlockIds":[],"fields":[{"columnType":0,"field":{"ns":"t0","name":"_A__dv0","simpleName":"_A__dv0"},"outputName":"CODG_CNAE","enabled":true,"conceptType":0,"params":[],"dataType":2,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_r5osgr8hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_C__dv0","simpleName":"_C__dv0"},"outputName":"CODG_DESC_GRANDE_SETOR","enabled":true,"conceptType":0,"params":[],"dataType":100,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_vrk8lj9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_F__dv0","simpleName":"_F__dv0"},"outputName":"CODG_DESC_SETOR","enabled":true,"conceptType":0,"params":[],"dataType":100,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_kfgukk9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_I__dv0","simpleName":"_I__dv0"},"outputName":"CODG_DESC_SUBSETOR","enabled":true,"conceptType":0,"params":[],"dataType":100,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_pvssdl9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_L__dv0","simpleName":"_L__dv0"},"outputName":"CODG_DESC_SUBSETOR_MT","enabled":true,"conceptType":0,"params":[],"dataType":100,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_e5n25l9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_N__dv0","simpleName":"_N__dv0"},"outputName":"CODG_DESC_SUBCLASSE_CNAE","enabled":true,"conceptType":0,"params":[],"dataType":100,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_3qdytm9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_M__dv0","simpleName":"_M__dv0"},"outputName":"DESC_SUBCLASSE_CNAE","enabled":true,"conceptType":0,"params":[],"dataType":100,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_hhmszqdvld"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_A__dv1","simpleName":"_A__dv1"},"outputName":"COD_CNAE","enabled":true,"conceptType":0,"params":[],"dataType":2,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_tu38xr8hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_B__dv0","simpleName":"_B__dv0"},"outputName":"Data","enabled":true,"conceptType":0,"params":[],"dataType":8,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_krqfcoamid"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"calc_b3res97hgd_dv0","simpleName":"calc_b3res97hgd_dv0"},"outputName":"Ano","enabled":true,"conceptType":0,"params":[],"dataType":8,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_e29fesamid"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_C__dv1","simpleName":"_C__dv1"},"outputName":"ICMS_PREVISTO","enabled":true,"conceptType":0,"params":[],"dataType":2,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_elb18o9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_D__dv0","simpleName":"_D__dv0"},"outputName":"ICMS_REALIZADO","enabled":true,"conceptType":0,"params":[],"dataType":2,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_nbp89o9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]},{"columnType":0,"field":{"ns":"t0","name":"_F__dv1","simpleName":"_F__dv1"},"outputName":"REALDO_CORRIGIDO","enabled":true,"conceptType":0,"params":[],"dataType":2,"property":[],"isRepeated":false,"isDefault":false,"ancestors":[],"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"qt_4hppbp9hgd"}},"lookerFilterOnlyFieldAllowedValues":[]}],"name":"cnaes desc"},"delegatedAccessEnabled":true,"isUnlocked":true,"isCacheable":false,"allowNativeFunctions":false}},"dsFilterOverrides":[],"filters":[{"filterDefinition":{"filterExpression":{"include":true,"conceptType":0,"concept":{"name":"qt_bkryggdvld","ns":"t0"},"queryTimeTransformation":{"dataTransformation":{"sourceFieldName":"_B__dv0"}},"filterConditionType":"IN","stringValues":["20250101","20250201","20250301","20250401","20250501","20250601","20250701","20250801","20250901","20251001","20251101","20251201","20260101","20260201","20260301","20260401","20260501","20260601","20260701","20260801","20260901","20261001","20261101"]}},"dataSubsetNs":{"tableNs":"t0","contextNs":"c0"},"version":3,"isCanvasFilter":true}],"features":[],"dateRanges":[],"contextNsCount":1,"calculatedField":[],"needGeocoding":false,"geoFieldMask":[],"multipleGeocodeFields":[],"timezone":"America/Sao_Paulo"},"role":"main"}
'@

Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromMinutes(5)
$http.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (CDLoad; extracao diaria)')

function Texto-Utf8($resp) { [Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().Result) }

# Executa o componente com o filtro de periodo trocado; devolve as linhas (arrays de valores).
function Consultar($tpl, $valoresFiltro) {
  $req = $tpl | ConvertFrom-Json
  $req.datasetSpec.filters[0].filterDefinition.filterExpression.PSObject.Properties | Out-Null
  $e = $req.datasetSpec.filters[0].filterDefinition.filterExpression
  if ($e.PSObject.Properties.Name -contains 'stringValues') { $e.stringValues = [string[]]$valoresFiltro }
  else { $e.numberValues = [int[]]$valoresFiltro }
  $req.datasetSpec.paginateInfo.rowsCount = 100000
  $corpo = '{"dataRequest":[' + ($req | ConvertTo-Json -Depth 40 -Compress) + ']}'
  for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
    try {
      $msg = New-Object System.Net.Http.HttpRequestMessage 'Post', $URL
      $msg.Headers.Add('encoding', 'null')
      $msg.Headers.Referrer = [Uri]$REFERER
      $msg.Content = New-Object System.Net.Http.StringContent($corpo, [Text.Encoding]::UTF8, 'application/json')
      $resp = $http.SendAsync($msg).Result
      $txt = (Texto-Utf8 $resp) -replace "^\)\]\}'\s*", ''
      $j = $txt | ConvertFrom-Json
      $ds = $j.dataResponse[0].dataSubset[0].dataset.tableDataset
      if (-not $ds) { throw "Resposta sem dados: $($txt.Substring(0, [Math]::Min(400, $txt.Length)))" }
      break
    } catch {
      if ($tentativa -eq 3) { throw }
      Start-Sleep -Seconds (10 * $tentativa)
    }
  }
  $cols = @()
  foreach ($col in $ds.column) {
    $pr = $col.PSObject.Properties | Where-Object { $_.Name -like '*Column' } | Select-Object -First 1
    $vals = New-Object System.Collections.ArrayList
    if ($pr -and $pr.Value.values) { $vals.AddRange(@($pr.Value.values)) }
    foreach ($n in @($col.nullIndex)) { if ($null -ne $n) { $vals.Insert([int]$n, $null) } }
    $cols += , $vals
  }
  $rows = New-Object System.Collections.ArrayList
  for ($l = 0; $l -lt [int]$ds.size; $l++) {
    $o = New-Object object[] $cols.Count
    for ($k = 0; $k -lt $cols.Count; $k++) { $o[$k] = $cols[$k][$l] }
    [void]$rows.Add($o)
  }
  if ([int]$ds.totalCount -gt $rows.Count) { throw "Resposta truncada: $($rows.Count) de $($ds.totalCount) linhas" }
  , $rows
}

$CULT = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$MINUSC = @('e', 'de', 'da', 'do', 'das', 'dos', 'a', 'o', 'em', 'para', 'por', 'com', 'ou', 'no', 'na', 'nos', 'nas', 'ao', 'aos', 'exceto')
# "03 - COMERCIO E SERVICOS" -> "Comercio e Servicos" (mantendo acentos); siglas curtas em maiusculas ficam.
function Titulo([string]$t, [bool]$forcar = $false) {
  $t = ($t -replace '^\s*[\d.]+\s*-\s*', '').Trim()
  if (-not $forcar -and $t -cne $t.ToUpper($CULT)) { return $t }
  $p = $CULT.TextInfo.ToTitleCase($t.ToLower($CULT)) -split ' '
  for ($i = 1; $i -lt $p.Count; $i++) { if ($MINUSC -contains $p[$i].ToLower($CULT)) { $p[$i] = $p[$i].ToLower($CULT) } }
  ($p -join ' ') -replace "D'oeste", "D'Oeste"
}
function Num($v) { if ($null -eq $v -or "$v" -eq '') { 0.0 } else { [double]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture) } }
# Listas tipadas: no PowerShell 5.1, arrays acumulados com += , viram {"value":[...],"Count":n} no JSON.
function Nova-Lista { , (New-Object System.Collections.Generic.List[object]) }

# ---------- Municipios ----------
$anoAtual = (Get-Date).Year
$porMun = @{}   # ibge -> @{ nome; reg; v = @{ 'AAAA-MM' = valor } }
$mesesSet = @{}
for ($ano = $ANO_INICIAL; $ano -le $anoAtual; $ano++) {
  Write-Host "Municipios $ano..."
  $rows = Consultar $TPL_MUN @($ano)
  foreach ($r in $rows) {
    # 0 ANO, 1 COD_MUN, 2 COD_MUN_IBGE, 3 data, 4 MUNICIPIO, 5 RF, 6 VALOR
    if (-not $r[3] -or -not $r[2]) { continue }
    $mes = "$($r[3])".Substring(0, 7)
    $k = "$($r[2])"
    if (-not $porMun.ContainsKey($k)) { $porMun[$k] = @{ nome = "$($r[4])"; reg = "$($r[5])"; v = @{} } }
    $valor = Num $r[6]
    $porMun[$k].v[$mes] = $porMun[$k].v[$mes] + $valor
    if ($valor -ne 0) { $mesesSet[$mes] = $true }
  }
}
$meses = @($mesesSet.Keys | Sort-Object)
if ($meses.Count -lt 13) { throw "Poucos meses de dados por municipio ($($meses.Count))." }
$iMes = @{}; for ($i = 0; $i -lt $meses.Count; $i++) { $iMes[$meses[$i]] = $i }

# Nomes com acento pelo IBGE (a Sefaz publica em maiusculas e sem acento).
$ibgeNome = @{}
try {
  $lista = (Texto-Utf8 $http.GetAsync('https://servicodados.ibge.gov.br/api/v1/localidades/estados/51/municipios').Result) | ConvertFrom-Json
  foreach ($m in $lista) { $ibgeNome["$($m.id)"] = $m.nome }
} catch { Write-Host "Aviso: nomes do IBGE indisponiveis ($($_.Exception.Message)); usando os da Sefaz." }

$regioes = @($porMun.Values | ForEach-Object { $_.reg } | Where-Object { $_ } | Sort-Object -Unique)
$munChaves = @($porMun.Keys | Sort-Object { if ($ibgeNome[$_]) { $ibgeNome[$_] } else { Titulo $porMun[$_].nome $true } })
$mun = [ordered]@{ nomes = (Nova-Lista); ibge = (Nova-Lista); reg = (Nova-Lista); v = (Nova-Lista) }
foreach ($k in $munChaves) {
  $m = $porMun[$k]
  $arr = New-Object long[] $meses.Count
  foreach ($mes in $m.v.Keys) { if ($iMes.ContainsKey($mes)) { $arr[$iMes[$mes]] = [long][Math]::Round($m.v[$mes]) } }
  $mun.nomes.Add($(if ($ibgeNome[$k]) { $ibgeNome[$k] } else { Titulo $m.nome $true }))
  $mun.ibge.Add([int]$k)
  $mun.reg.Add([array]::IndexOf($regioes, $m.reg))
  $mun.v.Add([long[]]$arr)
}

# ---------- Agrupamentos consolidados (rosca do painel) ----------
# Pela subclasse CNAE (7 digitos). Setores pela divisao (2 digitos):
#   01-03 Agropecuaria · 05-33 Industria · 41-43 Construcao · 45-47 Comercio · 49-99 Servicos
#   Outros: 35-39 (energia eletrica, gas, agua, esgoto, residuos) e codigos sem divisao valida.
$GRP_SETORES = @('Comércio', 'Serviços', 'Indústria', 'Agropecuária', 'Construção', 'Outros')
function Setor6([string]$c) {
  $d = [int]$c.Substring(0, 2)
  if ($d -ge 1 -and $d -le 3) { return 3 }
  if ($d -ge 5 -and $d -le 33) { return 2 }
  if ($d -ge 41 -and $d -le 43) { return 4 }
  if ($d -ge 45 -and $d -le 47) { return 0 }
  if ($d -ge 49 -and $d -le 99) { return 1 }
  5
}
# Associacoes com que a CDL Cuiaba interage. Inclui a industria que recolhe o ICMS por
# substituicao tributaria das vendas no estado (refinarias/usinas, cervejarias, montadoras).
# Prefixos de CNAE; vale o primeiro grupo que casar (ordem: Sindipetroleo, Abrasel, Fenabrave).
$GRP_ASSOC = @('CDL Cuiabá', 'Sindipetróleo', 'Abrasel', 'Fenabrave', 'Outros')
$ASSOC_PREFIXOS = @(
  # Sindipetroleo: petroleo e gas, refino e biocombustiveis (inclui alcool), distribuidoras e TRR,
  # GLP, postos, lubrificantes, lojas de conveniencia, troca de oleo/lavagem, gas canalizado.
  @(1, @('06', '19', '4681', '4682', '4731', '4732', '4784', '4729602', '4520005', '3520')),
  # Abrasel: restaurantes, bares, lanchonetes, ambulantes, delivery/catering; bebidas (industria,
  # atacado e varejo); laticinios, sorvetes, cafe, panificacao, confeitaria e demais alimentos
  # de consumo (grupos 105, 108, 109); padarias/docerias; distribuidores de alimentos.
  # Fora: frigorificos, oleos, moagem, racoes e acucar (agroindustria, grupos 101-104, 106, 107).
  @(2, @('561', '562', '11', '4635', '4723', '105', '108', '109', '4721102', '4721104', '4637', '4639')),
  # Fenabrave: concessionarias e revendas de veiculos e motos (e seus representantes), maquinas
  # e implementos agricolas, e as montadoras (automoveis, caminhoes/onibus, implementos, motos, tratores).
  @(3, @('4511', '4512', '4541', '4542', '4661', '2910', '2920', '2930', '3091', '2831', '2832', '2833'))
)
function Assoc([string]$c) {
  foreach ($g in $ASSOC_PREFIXOS) { foreach ($p in $g[1]) { if ($c.StartsWith($p)) { return $g[0] } } }
  # CDL Cuiaba: o restante do comercio e dos servicos (varejo, atacado, autopecas, servicos, credito...)
  $d = [int]$c.Substring(0, 2)
  if (($d -ge 45 -and $d -le 47) -or ($d -ge 49 -and $d -le 99)) { return 0 }
  4
}

# ---------- CNAE ----------
$grpVal = @{}    # "s|iSeg|iGrupo" ou "a|iSeg|iGrupo" -> long[] mensal (realizado)
$macros = New-Object System.Collections.ArrayList
$setores = New-Object System.Collections.ArrayList; $setorMacro = New-Object System.Collections.ArrayList
$segs = New-Object System.Collections.ArrayList; $segSetor = New-Object System.Collections.ArrayList
$segVal = @{}    # "iSeg|iMes" -> [real, prev, corr]
$subInfo = @{}   # cod -> @{ nome; seg; total; v = @{ iMes = real } }
function Indice($lista, $nome) { $i = $lista.IndexOf($nome); if ($i -lt 0) { $i = $lista.Add($nome) }; $i }
for ($ano = $ANO_INICIAL; $ano -le $anoAtual; $ano++) {
  Write-Host "CNAE $ano..."
  $filtro = 1..12 | ForEach-Object { '{0}{1:D2}01' -f $ano, $_ }
  $rows = Consultar $TPL_CNAE $filtro
  foreach ($r in $rows) {
    # 0 grande setor, 1 setor, 2 subsetor, 3 subsetor MT, 4 subclasse "cod-desc", 5 cod, ..., 11 data, 12 previsto, 13 realizado, 14 corrigido
    if (-not $r[11] -or -not $r[3]) { continue }
    $mes = "$($r[11])".Substring(0, 7)
    if (-not $iMes.ContainsKey($mes)) { continue }
    $im = $iMes[$mes]
    $iMacro = Indice $macros (Titulo "$($r[0])" $true)
    $nSetor = Titulo "$($r[1])"
    $iSetor = $setores.IndexOf($nSetor); if ($iSetor -lt 0) { $iSetor = $setores.Add($nSetor); [void]$setorMacro.Add($iMacro) }
    $nSeg = Titulo "$($r[3])"
    $iSeg = $segs.IndexOf($nSeg); if ($iSeg -lt 0) { $iSeg = $segs.Add($nSeg); [void]$segSetor.Add($iSetor) }
    $real = Num $r[13]; $prev = Num $r[12]; $corr = Num $r[14]
    $ch = "$iSeg|$im"
    if (-not $segVal.ContainsKey($ch)) { $segVal[$ch] = @(0.0, 0.0, 0.0) }
    $segVal[$ch][0] += $real; $segVal[$ch][1] += $prev; $segVal[$ch][2] += $corr
    $cod = "$($r[5])"
    if ($cod) { $cod = $cod.PadLeft(7, '0') }   # a fonte omite o zero inicial (0115600 -> 115600)
    if ($cod -and $real -ne 0) {
      foreach ($par in @(@('s', (Setor6 $cod)), @('a', (Assoc $cod)))) {
        $gk = "$($par[0])|$iSeg|$($par[1])"
        if (-not $grpVal.ContainsKey($gk)) { $grpVal[$gk] = New-Object double[] $meses.Count }
        $grpVal[$gk][$im] += $real
      }
      if (-not $subInfo.ContainsKey($cod)) {
        $desc = ("$($r[4])" -replace '^\s*\d+\s*-\s*', '').Trim()
        $subInfo[$cod] = @{ nome = $desc; seg = $iSeg; total = 0.0; v = @{} }
      }
      $subInfo[$cod].total += $real
      $subInfo[$cod].v[$im] = $subInfo[$cod].v[$im] + $real
    }
  }
}
if ($segs.Count -lt 10) { throw "Poucos segmentos CNAE ($($segs.Count))." }
$serie = { param($j) $a = New-Object long[] $meses.Count; for ($m = 0; $m -lt $meses.Count; $m++) { $x = $segVal["$s|$m"]; if ($x) { $a[$m] = [long][Math]::Round($x[$j]) } }; , $a }
$real = Nova-Lista; $prev = Nova-Lista; $corr = Nova-Lista
for ($s = 0; $s -lt $segs.Count; $s++) { $real.Add([long[]](& $serie 0)); $prev.Add([long[]](& $serie 1)); $corr.Add([long[]](& $serie 2)) }
$top = @($subInfo.Keys | Sort-Object { $subInfo[$_].total } -Descending | Select-Object -First $TOP_SUB)
$subs = [ordered]@{ nomes = (Nova-Lista); cod = (Nova-Lista); seg = (Nova-Lista); v = (Nova-Lista) }
foreach ($cod in $top) {
  $x = $subInfo[$cod]
  $a = New-Object long[] $meses.Count
  foreach ($m in $x.v.Keys) { $a[[int]$m] = [long][Math]::Round($x.v[$m]) }
  $subs.nomes.Add($x.nome); $subs.cod.Add("$cod"); $subs.seg.Add($x.seg); $subs.v.Add([long[]]$a)
}
# Pares (segmento, grupo) com arrecadação: [iSeg, iGrupo, [mensal]] — a busca filtra por segmento.
$grupos = [ordered]@{ setores = $GRP_SETORES; assoc = $GRP_ASSOC; setor = (Nova-Lista); associacao = (Nova-Lista) }
foreach ($gk in ($grpVal.Keys | Sort-Object)) {
  $p = $gk -split '\|'
  $par = Nova-Lista
  $par.Add([int]$p[1]); $par.Add([int]$p[2]); $par.Add([long[]]($grpVal[$gk] | ForEach-Object { [long][Math]::Round($_) }))
  if ($p[0] -eq 's') { $grupos.setor.Add($par) } else { $grupos.associacao.Add($par) }
}

$dados = [ordered]@{
  fonte = 'Sefaz MT · Dashboard de Arrecadação de Tributos e Contribuições (UPER)'
  extraido_em = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
  meses = $meses
  regioes = @($regioes | ForEach-Object { Titulo $_ $true })
  mun = $mun
  cnae = [ordered]@{
    macros = @($macros); setores = [ordered]@{ nomes = @($setores); macro = @($setorMacro) }
    segs = [ordered]@{ nomes = @($segs); setor = @($segSetor) }
    real = $real; prev = $prev; corr = $corr; subs = $subs; grupos = $grupos
  }
}
$json = $dados | ConvertTo-Json -Depth 12 -Compress
$conteudo = "// Gerado por scripts/sefaz_extrair.ps1 - nao editar a mao.`nwindow.SEFAZ_ICMS = $json;`n"

# So regrava se algo alem da data de extracao mudou.
$semData = { param($t) $t -replace '"extraido_em":"[^"]*"', '' }
if (Test-Path $SAIDA) {
  $antigo = [IO.File]::ReadAllText($SAIDA, [Text.Encoding]::UTF8)
  if ((& $semData $antigo) -eq (& $semData $conteudo)) { Write-Host 'Sem mudancas.'; exit 0 }
}
[IO.File]::WriteAllText($SAIDA, $conteudo, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("Gravado {0}: {1} meses ({2} a {3}), {4} municipios, {5} segmentos, {6} subclasses, {7:N0} bytes." -f `
  $SAIDA, $meses.Count, $meses[0], $meses[-1], $mun.nomes.Count, $segs.Count, $subs.nomes.Count, $conteudo.Length)
