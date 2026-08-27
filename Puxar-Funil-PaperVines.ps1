# =====================================================================
#  Puxa o TOPO DO FUNIL do Paper Vines (wts.chat) e salva num arquivo
#  que o dashboard usa. Roda no seu PC (Windows), sem instalar nada.
#  Uso: dê 2 cliques no "Puxar-Funil.bat".
# =====================================================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"
# Formato brasileiro (milhar com ponto) - garante numeros iguais no Windows e na nuvem (Linux)
try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR') } catch {}
$base = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($base)) { $base = Split-Path -Parent $MyInvocation.MyCommand.Path }
Write-Host "===== VERSAO v6 - com motivos de encerramento =====" -ForegroundColor Cyan
Write-Host ("Pasta do script: {0}" -f $base) -ForegroundColor DarkGray

$candidates = @(
  (Join-Path $base "config/papervines-token.txt"),
  (Join-Path $base "papervines-token.txt")
)
$tokenFile = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $tokenFile) {
  Write-Host "ERRO: nao encontrei o arquivo do token. Procurei em:" -ForegroundColor Red
  $candidates | ForEach-Object { Write-Host ("   - {0}" -f $_) }
  Write-Host "O que tem nesta pasta:" -ForegroundColor Yellow
  Get-ChildItem $base -Force | ForEach-Object { Write-Host ("   {0}" -f $_.Name) }
  $cfg = Join-Path $base "config"
  if (Test-Path $cfg) { Write-Host "O que tem na pasta config:" -ForegroundColor Yellow; Get-ChildItem $cfg -Force | ForEach-Object { Write-Host ("   {0}" -f $_.Name) } }
  Read-Host "Enter para sair"; exit
}
Write-Host ("Token lido de: {0}" -f $tokenFile) -ForegroundColor DarkGray
$token = (Get-Content $tokenFile -Raw).Trim() -replace '^Bearer\s+',''
if ([string]::IsNullOrWhiteSpace($token) -or -not $token.StartsWith("pn_")) {
  Write-Host "ERRO: o token no arquivo nao parece valido (deve comecar com pn_)." -ForegroundColor Red
  Read-Host "Enter para sair"; exit
}

# ---- Janela da semana comercial fechada (sexta anterior -> quinta), horario de Brasilia ----
# Sempre pega a ultima semana FECHADA: a quinta-feira mais recente ANTES de hoje, e a sexta 6 dias antes.
# Rola automaticamente toda sexta.
$now = Get-Date
$dow = [int]$now.Date.DayOfWeek        # Dom=0 ... Qui=4 ... Sab=6
$daysSinceThu = ((($dow - 4) + 7) % 7) # dias desde a ultima quinta (0 = hoje e quinta)
if ($daysSinceThu -eq 0) { $daysSinceThu = 7 }  # se hoje e quinta, usa a quinta anterior (semana ainda nao fechou)
$end   = $now.Date.AddDays(-$daysSinceThu)   # ultima quinta antes de hoje
$start = $end.AddDays(-6)                     # sexta anterior
# API usa UTC. Brasilia = UTC-3  =>  meia-noite local = 03:00Z
$afterUtc  = $start.ToString("yyyy-MM-dd") + "T03:00:00Z"
$beforeUtc = $end.AddDays(1).ToString("yyyy-MM-dd") + "T02:59:59Z"

Write-Host ("Semana: {0} a {1}" -f $start.ToString('dd/MM/yyyy'), $end.ToString('dd/MM/yyyy'))
Write-Host "Puxando contatos do Paper Vines..."

$headers = @{ Authorization = "Bearer $token"; Accept = "application/json" }
$all = @()
$page = 1
do {
  $url = "https://api.wts.chat/core/v1/contact?CreatedAt.After=$([uri]::EscapeDataString($afterUtc))&CreatedAt.Before=$([uri]::EscapeDataString($beforeUtc))&IncludeDetails=Tags&PageSize=100&PageNumber=$page"
  $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
  if ($resp.items) { $all += $resp.items }
  $more = [bool]$resp.hasMorePages
  $page++
} while ($more -and $page -le 40)

# ---- Contagem ----
$total = $all.Count
$ctt = 0; $cda = 0
$origin = @{}; $tagFreq = @{}
foreach ($c in $all) {
  $tags = @($c.tagNames)
  if ($tags | Where-Object { $_ -match '^CTT' }) { $ctt++ }
  if ($tags | Where-Object { $_ -match '^CDA' }) { $cda++ }
  $o = "$($c.origin)"; if ([string]::IsNullOrWhiteSpace($o)) { $o = "?" }
  if ($origin.ContainsKey($o)) { $origin[$o]++ } else { $origin[$o] = 1 }
  foreach ($t in $tags) { if ($t) { if ($tagFreq.ContainsKey($t)) { $tagFreq[$t]++ } else { $tagFreq[$t] = 1 } } }
}

# ---- POR VENDEDORA (via conversas/atendimentos) ----
Write-Host "Puxando atendimentos por vendedora..."
$sessAll = @()
$page = 1
do {
  $surl = "https://api.wts.chat/chat/v2/session?CreatedAt.After=$([uri]::EscapeDataString($afterUtc))&CreatedAt.Before=$([uri]::EscapeDataString($beforeUtc))&IncludeDetails=AgentDetails&IncludeDetails=ContactDetails&PageSize=100&PageNumber=$page"
  $sr = Invoke-RestMethod -Uri $surl -Headers $headers -Method Get
  if ($sr.items) { $sessAll += $sr.items }
  $smore = [bool]$sr.hasMorePages
  $page++
} while ($smore -and $page -le 40)

# Leads da semana + quais sao qualificados (CTT) / desqualificados (CDA)
$weekContactIds = @{}
$cttContactIds  = @{}
$cdaContactIds  = @{}
foreach ($c in $all) {
  if ($c.id) {
    $weekContactIds[$c.id] = $true
    $tg = @($c.tagNames)
    if ($tg | Where-Object { $_ -match '^CTT' }) { $cttContactIds[$c.id] = $true }
    if ($tg | Where-Object { $_ -match '^CDA' }) { $cdaContactIds[$c.id] = $true }
  }
}

# So estas 4 vendedoras contam. Chave = trecho SEM acento do nome (evita bug de encoding)
$vendMap = [ordered]@{ 'Daiane' = 'Daiane'; 'Naiverth' = 'Ana'; 'Euz' = 'Ana Paula'; 'Brenda' = 'Brenda' }
function VendOf([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name)) { return $null }
  foreach ($k in $vendMap.Keys) { if ($name -match $k) { return $vendMap[$k] } }
  return $null
}

# Mapeia contato -> vendedora que ASSUMIU o lead (primeira conversa assumida, cronologicamente)
$contactVend = @{}
$contactVendTs = @{}
foreach ($s in $sessAll) {
  $cid = $s.contactId
  if (-not $cid) { continue }
  $an = $null
  if ($s.agentDetails -and $s.agentDetails.name) { $an = "$($s.agentDetails.name)" }
  $v = VendOf $an
  if (-not $v) { continue }
  $tsRaw = $s.startAt; if ([string]::IsNullOrWhiteSpace($tsRaw)) { $tsRaw = $s.createdAt }
  $ts = [datetime]::MaxValue
  [void][datetime]::TryParse($tsRaw, [ref]$ts)
  if (-not $contactVend.ContainsKey($cid)) { $contactVend[$cid] = $v; $contactVendTs[$cid] = $ts }
  elseif ($ts -lt $contactVendTs[$cid]) { $contactVend[$cid] = $v; $contactVendTs[$cid] = $ts }
}

# Sinal de interacao por contato (lead mandou mensagem OU vendedora respondeu = teve atendimento)
$flagInter = @{}
foreach ($s in $sessAll) {
  $cid = $s.contactId; if (-not $cid) { continue }
  if ((-not [string]::IsNullOrWhiteSpace("$($s.lastMessageIn)")) -or (-not [string]::IsNullOrWhiteSpace("$($s.firstResponseAt)"))) { $flagInter[$cid] = $true }
}
# Regra final: CDA = desqualificado; CTT = qualificado; Entrada/Oportunidade = qualificado se interagiu, senao desqualificado
function IsQualified($cid) {
  if ($cdaContactIds.ContainsKey($cid)) { return $false }
  if ($cttContactIds.ContainsKey($cid)) { return $true }
  return $flagInter.ContainsKey($cid)
}

# Funil (total da semana)
$qualificados = 0; $desqualificados = 0
foreach ($cid in $weekContactIds.Keys) {
  if (IsQualified $cid) { $qualificados++ } else { $desqualificados++ }
}

# Por vendedora: cada LEAD unico atendido = 1 atendimento; cada um e qualificado OU desqualificado
#   (qualificados + desqualificados = atendimentos, sempre)
$vendLeads = @{}
foreach ($v in @('Daiane','Ana','Brenda','Ana Paula')) { $vendLeads[$v] = @{} }
foreach ($s in $sessAll) {
  $an = $null; if ($s.agentDetails -and $s.agentDetails.name) { $an = "$($s.agentDetails.name)" }
  $v = VendOf $an
  if ($v -and $vendLeads.ContainsKey($v) -and $s.contactId) { $vendLeads[$v][$s.contactId] = $true }
}
$vend = [ordered]@{}
foreach ($v in @('Daiane','Ana','Brenda','Ana Paula')) {
  $q = 0; $d = 0
  foreach ($cid in $vendLeads[$v].Keys) {
    if (IsQualified $cid) { $q++ } else { $d++ }
  }
  $vend[$v] = [ordered]@{ atendimentos = $vendLeads[$v].Count; qualificados = $q; desqualificados = $d }
}

# ================= CLINICA EXPERTS (2 clinicas) =================
function VendOfCE([string]$a) {
  if ([string]::IsNullOrWhiteSpace($a)) { return $null }
  $a = $a.ToLower()
  if ($a -match 'daiane') { return 'Daiane' }
  if ($a -match 'brenda') { return 'Brenda' }
  if (($a -match 'euz') -or ($a -match 'ana paula')) { return 'Ana Paula' }
  if ($a -match 'ana') { return 'Ana' }
  return $null
}
# Biomedicas (profissional que atende consulta/avaliacao e fecha tratamento)
function BioOf([string]$n) {
  if ([string]::IsNullOrWhiteSpace($n)) { return $null }
  $a = $n.ToLower()
  if ($a -match 'camily') { return 'Kamile' }
  if ($a -match 'janaina') { return 'Janaina' }
  if ($a -match 'bruna') { return 'Bruna' }
  return $null
}
Write-Host "Puxando Clinica Experts (2 clinicas)..."
$ce = [ordered]@{ agendaram=0; compareceram=0; cancelaram=0; remarcaram=0; noshow=0; faturamento=0.0; sj_fat=0.0; jv_fat=0.0 }
$ceUnit = @{
  sao_jose  = [ordered]@{ agendaram=0;compareceram=0;cancelaram=0;remarcaram=0;noshow=0;fat=0.0 }
  joinville = [ordered]@{ agendaram=0;compareceram=0;cancelaram=0;remarcaram=0;noshow=0;fat=0.0 }
}
$ceVend = [ordered]@{}
foreach ($vn in @('Daiane','Ana','Brenda','Ana Paula')) { $ceVend[$vn] = [ordered]@{ agendaram=0; compareceram=0; cancelaram=0; remarcaram=0; noshow=0; faturamento=0.0 } }
$bio = [ordered]@{}
foreach ($bn in @('Kamile','Janaina','Bruna')) { $bio[$bn] = [ordered]@{ atendidas=0; fechados=$null; faturamento=$null } }
$cancelados = @()
$ceSemObs = @()
try {
  $ceCfg  = Get-Content (Join-Path $base "config/clinica-experts-tokens.json") -Raw | ConvertFrom-Json
  $ceBase = "https://api.clinicaexperts.com.br/api/v1"
  $ceAfter  = $start.ToString("yyyy-MM-dd") + "T00:00:00-03:00"
  $ceBefore = $end.ToString("yyyy-MM-dd")   + "T23:59:59-03:00"
  $consultaProcs = @('Consulta Inicial','Consulta Online','Avaliação Gratuita Presencial','Avaliação Capilar Gratuita')
  # NOVOS agendamentos = criados na semana (janela ampla por data da consulta + filtro pela data de criacao)
  $ceNovos = @{ total = 0; sao_jose = 0; joinville = 0 }
  $patVend = @{}    # paciente (nome) -> vendedora (pela observacao do agendamento)
  $vendas  = @()    # vendas coletadas p/ atribuir faturamento por vendedora (nome do paciente + valor)
  $bkBefore = $start.AddDays(180).ToString("yyyy-MM-dd") + "T23:59:59-03:00"
  $wkStart = [datetimeoffset]($start.ToString("yyyy-MM-dd") + "T00:00:00-03:00")
  $wkEnd   = [datetimeoffset]($end.ToString("yyyy-MM-dd")   + "T23:59:59-03:00")
  $dbgNovos = [ordered]@{}
  foreach ($u in @('sao_jose','joinville')) {
    $tok = $ceCfg.clinics.$u.token
    $h = @{ Authorization = "Bearer $tok"; Accept = "application/json" }
    # Agendamentos
    $p = 1
    do {
      $burl = "$ceBase/bookings?starts_at=$([uri]::EscapeDataString($ceAfter))&ends_at=$([uri]::EscapeDataString($ceBefore))&page=$p"
      $bj = Invoke-RestMethod -Uri $burl -Headers $h -Method Get
      foreach ($b in @($bj.data)) {
        $isC = $false
        foreach ($pr in @($b.procedures)) {
          $pnm = "$($pr.name)"
          if (($pnm -match 'Consulta Inicial') -or ($pnm -match 'Consulta Online') -or ($pnm -match 'Avalia')) { $isC = $true }
        }
        if (-not $isC) { continue }
        $ce.agendaram++; $ceUnit[$u].agendaram++
        if ($b.status -eq 'done') { $ce.compareceram++; $ceUnit[$u].compareceram++ }
        elseif ($b.status -eq 'canceled') { $ce.cancelaram++; $ceUnit[$u].cancelaram++ }
        elseif ($b.status -eq 'rescheduled') { $ce.remarcaram++; $ceUnit[$u].remarcaram++ }
        elseif ($b.status -eq 'noshow') { $ce.noshow++; $ceUnit[$u].noshow++ }
        # Biomedica: consultas/avaliacoes ATENDIDAS (compareceu) na semana
        if ($b.status -eq 'done') { $bnm = BioOf ("$($b.professional.name)"); if ($bnm -and $bio.Contains($bnm)) { $bio[$bnm].atendidas++ } }
        $vv = VendOfCE ("$($b.annotation)")
        if ($vv -and $ceVend.Contains($vv)) {
          $patVend[("$($b.patient.name)").ToLower().Trim()] = $vv
          if ($b.status -eq 'done')        { $ceVend[$vv].compareceram++ }
          if ($b.status -eq 'canceled')    { $ceVend[$vv].cancelaram++ }
          if ($b.status -eq 'rescheduled') { $ceVend[$vv].remarcaram++ }
          if ($b.status -eq 'noshow')      { $ceVend[$vv].noshow++ }
        } else {
          $nm2 = "$($b.patient.name)"; if (-not [string]::IsNullOrWhiteSpace($nm2)) { $ceSemObs += $nm2 }
        }
        if ($b.status -eq 'canceled') {
          $nm = "$($b.patient.name)"; $dt = "$($b.starts_at)"; if ($dt.Length -ge 10) { $dt = $dt.Substring(0,10) }
          $cancelados += ("{0} | {1} | {2}" -f $u, $nm, $dt)
        }
      }
      $lp = 1; if ($bj.meta -and $bj.meta.last_page) { $lp = [int]$bj.meta.last_page }
      $p++
    } while ($p -le $lp -and (@($bj.data)).Count -gt 0)
    # Faturamento (contas type Venda)
    $p = 1
    do {
      $burl2 = "$ceBase/bills?starts_at=$([uri]::EscapeDataString($ceAfter))&ends_at=$([uri]::EscapeDataString($ceBefore))&page=$p"
      $bj2 = Invoke-RestMethod -Uri $burl2 -Headers $h -Method Get
      foreach ($bb in @($bj2.data)) {
        if ($bb.type -eq 'Venda') {
          # Faturamento = RECEBIMENTO: soma so as parcelas efetivamente pagas (status 'received')
          $rec = 0.0
          foreach ($pm in @($bb.payment_methods)) {
            foreach ($pc in @($pm.parcels)) {
              if ("$($pc.status)" -eq 'received') { $rec += [double]$pc.final_amount / 100.0 }
            }
          }
          if ($rec -gt 0) {
            $ce.faturamento += $rec
            if ($u -eq 'sao_jose') { $ce.sj_fat += $rec } else { $ce.jv_fat += $rec }
            $vendas += @{ name = ("$($bb.person.name)").ToLower().Trim(); val = $rec }
          }
        }
      }
      $lp2 = 1; if ($bj2.meta -and $bj2.meta.last_page) { $lp2 = [int]$bj2.meta.last_page }
      $p++
    } while ($p -le $lp2 -and (@($bj2.data)).Count -gt 0)
    # NOVOS agendamentos criados na semana: varre em BLOCOS de 30 dias (evita limite de janela) e filtra por created_at
    $seenIds = @{}
    $uScan = 0; $uConsulta = 0; $uParsed = 0; $uNovos = 0; $sampleCa = @()
    for ($ci = 0; $ci -lt 7; $ci++) {
      $cs   = $start.AddDays($ci * 30)
      $cend = $cs.AddDays(29)
      $csS  = $cs.ToString("yyyy-MM-dd")   + "T00:00:00-03:00"
      $ceS2 = $cend.ToString("yyyy-MM-dd") + "T23:59:59-03:00"
      $p = 1
      do {
        $nurl = "$ceBase/bookings?starts_at=$([uri]::EscapeDataString($csS))&ends_at=$([uri]::EscapeDataString($ceS2))&per_page=100&page=$p"
        $nj = $null
        try { $nj = Invoke-RestMethod -Uri $nurl -Headers $h -Method Get } catch { break }
        $nrows = @($nj.data)
        if ($nrows.Count -eq 0) { break }
        foreach ($b in $nrows) {
          $bid = "$($b.id)"
          if ($bid -and $seenIds.ContainsKey($bid)) { continue }
          if ($bid) { $seenIds[$bid] = $true }
          $uScan++
          # mapeia paciente -> vendedora pela observacao de QUALQUER agendamento (consulta ou pacote), p/ o faturamento
          $vvAll = VendOfCE ("$($b.annotation)"); if ($vvAll -and $ceVend.Contains($vvAll)) { $patVend[("$($b.patient.name)").ToLower().Trim()] = $vvAll }
          $isC = $false
          foreach ($pr in @($b.procedures)) { $pnm = "$($pr.name)"; if (($pnm -match 'Consulta Inicial') -or ($pnm -match 'Consulta Online') -or ($pnm -match 'Avalia')) { $isC = $true } }
          if (-not $isC) { continue }
          $uConsulta++
          $caRaw = "$($b.created_at)"
          if ($sampleCa.Count -lt 6) { $sampleCa += $caRaw }
          $cdt = [datetimeoffset]::MinValue
          $ok = [datetimeoffset]::TryParse($caRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$cdt)
          if (-not $ok) { continue }
          $uParsed++
          if ($cdt -ge $wkStart -and $cdt -le $wkEnd) {
            $uNovos++; $ceNovos.total++; $ceNovos[$u]++
            $vv2 = VendOfCE ("$($b.annotation)")
            if ($vv2 -and $ceVend.Contains($vv2)) { $ceVend[$vv2].agendaram++; $patVend[("$($b.patient.name)").ToLower().Trim()] = $vv2 }
          }
        }
        $p++
      } while ($p -le 1000 -and $nrows.Count -gt 0)
    }
    $dbgNovos[$u] = [ordered]@{ scan = $uScan; consulta = $uConsulta; parsed = $uParsed; novos = $uNovos; samples = $sampleCa }
  }
  # Faturamento por vendedora: casa o paciente da venda com quem agendou (patVend)
  foreach ($vd in $vendas) {
    if ($patVend.ContainsKey($vd.name)) { $ceVend[$patVend[$vd.name]].faturamento += $vd.val }
  }
  Write-Host ""
  Write-Host "==== CLINICA EXPERTS (semana) ====" -ForegroundColor Green
  Write-Host ("Agendados p/ a semana {0} | Compareceram {1} | Cancelaram {2} | Remarcaram {3} | No-show {4}" -f $ce.agendaram,$ce.compareceram,$ce.cancelaram,$ce.remarcaram,$ce.noshow)
  Write-Host ("Novos agendamentos (criados na semana): {0}  (SJ {1} + JV {2})" -f $ceNovos.total,$ceNovos.sao_jose,$ceNovos.joinville)
  Write-Host ("Faturamento: R$ {0:N2}  (SJ {1:N2} + JV {2:N2})" -f $ce.faturamento,$ce.sj_fat,$ce.jv_fat)
  Write-Host "Por vendedora (agendaram/compareceram/no-show):"
  $ceVend.GetEnumerator() | ForEach-Object { Write-Host ("   {0}: {1}/{2}/{3}" -f $_.Key,$_.Value.agendaram,$_.Value.compareceram,$_.Value.noshow) }
  Write-Host ("Cancelados (repescagem): {0}" -f $cancelados.Count)
} catch {
  Write-Host ("ERRO ao puxar Clinica Experts: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# ===== Faturamento OFICIAL (recebido/extrato) - vem de config/faturamento.json (puxado da sessao do painel) =====
$fatFile = Join-Path $base "config/faturamento.json"
if (Test-Path $fatFile) {
  try {
    $fj = Get-Content $fatFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $fj.total) { $ce.faturamento = [double]$fj.total }
    if ($null -ne $fj.sj)    { $ce.sj_fat = [double]$fj.sj }
    if ($null -ne $fj.jv)    { $ce.jv_fat = [double]$fj.jv }
    foreach ($vn in @('Daiane','Ana','Brenda','Ana Paula')) {
      $val = $null
      if ($fj.por_vendedora -and ($null -ne $fj.por_vendedora.$vn)) { $val = [double]$fj.por_vendedora.$vn }
      $ceVend[$vn].faturamento = $val   # vem do vendedor da comanda (capturado); $null = ainda nao capturado ("-")
    }
    # Biomedicas: pacotes fechados + faturamento em tratamentos (capturados na captura semanal, via vendedor=biomedica)
    if ($fj.biomedicas) {
      foreach ($bn in @('Kamile','Janaina','Bruna')) {
        $bo = $fj.biomedicas.$bn
        if ($bo) {
          if ($null -ne $bo.pacotes)     { $bio[$bn].fechados     = [int]$bo.pacotes }
          if ($null -ne $bo.faturamento) { $bio[$bn].faturamento  = [double]$bo.faturamento }
        }
      }
    }
    Write-Host ("Faturamento OFICIAL (extrato): R$ {0:N2}  (SJ {1:N2} + JV {2:N2})" -f $ce.faturamento,$ce.sj_fat,$ce.jv_fat) -ForegroundColor Green
  } catch { Write-Host ("Falha lendo faturamento.json: {0}" -f $_.Exception.Message) -ForegroundColor Red }
}

Write-Host ""

$result = [ordered]@{
  atualizado_em        = $now.ToString("yyyy-MM-dd HH:mm")
  semana_inicio        = $start.ToString("yyyy-MM-dd")
  semana_fim           = $end.ToString("yyyy-MM-dd")
  leads_entraram       = $total
  qualificados         = $qualificados
  desqualificados      = $desqualificados
  por_origem           = $origin
  por_vendedora        = $vend
  ref_etiqueta_CTT     = $ctt
  ref_etiqueta_CDA     = $cda
  etiquetas_frequencia = $tagFreq
}
$outFile = Join-Path $base "config/Funil-PaperVines.json"
$result | ConvertTo-Json -Depth 6 | Out-File $outFile -Encoding UTF8

Write-Host ""
Write-Host "==== FUNIL PAPER VINES (semana) ====" -ForegroundColor Cyan
Write-Host ("Leads que entraram : {0}" -f $total)
Write-Host ("Qualificados       : {0}" -f $qualificados)
Write-Host ("Desqualificados    : {0}" -f $desqualificados)
Write-Host ("Salvo em: {0}" -f $outFile) -ForegroundColor Green
Write-Host ""
Write-Host ""
Write-Host "==== POR VENDEDORA (atendimentos / qualificados / desqualificados) ====" -ForegroundColor Cyan
$vend.GetEnumerator() | Sort-Object { $_.Value.atendimentos } -Descending | ForEach-Object {
  Write-Host ("   {0}: atendimentos {1} | qualificados {2} | desqualificados {3}" -f $_.Key, $_.Value.atendimentos, $_.Value.qualificados, $_.Value.desqualificados)
}
Write-Host ""
Write-Host "Etiquetas encontradas (pra identificarmos os parceiros e clinicas):"
$tagFreq.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 40 | ForEach-Object { Write-Host ("   {0} = {1}" -f $_.Key, $_.Value) }
Write-Host ""
# ================= GERAR O DASHBOARD (HTML) =================
try {
  $ic = [System.Globalization.CultureInfo]::InvariantCulture
  $pctMeta   = ([math]::Round(($ce.faturamento / 30023.0) * 100, 1)).ToString($ic)
  $pctComp   = if ($ce.agendaram -gt 0) { ([math]::Round($ce.compareceram / $ce.agendaram * 100,1)).ToString($ic) } else { "0" }
  $pctCanc   = if ($ce.agendaram -gt 0) { ([math]::Round($ce.cancelaram   / $ce.agendaram * 100,1)).ToString($ic) } else { "0" }
  $pctRemarc = if ($ce.agendaram -gt 0) { ([math]::Round($ce.remarcaram   / $ce.agendaram * 100,1)).ToString($ic) } else { "0" }
  $pctNs     = if ($ce.agendaram -gt 0) { ([math]::Round($ce.noshow       / $ce.agendaram * 100,1)).ToString($ic) } else { "0" }
  $fatFmt    = "{0:N0}" -f $ce.faturamento
  $sjFatFmt  = "{0:N0}" -f $ce.sj_fat
  $jvFatFmt  = "{0:N0}" -f $ce.jv_fat
  $campanha  = 0; if ($origin.ContainsKey('CREATED_FROM_HUB')) { $campanha = $origin['CREATED_FROM_HUB'] }
  $manuais   = $total - $campanha
  $pctQ      = if ($total -gt 0) { ([math]::Round($qualificados    / $total * 100,0)).ToString($ic) } else { "0" }
  $pctD      = if ($total -gt 0) { ([math]::Round($desqualificados / $total * 100,0)).ToString($ic) } else { "0" }
  $clinSJ = 0; $clinJV = 0
  foreach ($e in $tagFreq.GetEnumerator()) { if ($e.Key -match 'SJ') { $clinSJ += $e.Value } elseif ($e.Key -match 'JV') { $clinJV += $e.Value } }

  $parcRows = ""; $parcTot = 0; $parcTop = "Sem parcerias na semana"; $primeiro = $true
  foreach ($e in ($tagFreq.GetEnumerator() | Sort-Object Value -Descending)) {
    $k = "$($e.Key)"
    if (($k -match 'CTT') -or ($k -match 'CDA') -or ($k -match 'SJ') -or ($k -match 'JV') -or ($k -match 'SEM UNIDADE') -or ($k -match 'Venda perdida') -or ($k -match 'QUER') -or ($k -match 'tipo de atendimento')) { continue }
    $parcRows += '        <tr><td>' + $k + '</td><td class="num">' + $e.Value + '</td></tr>' + "`r`n"
    $parcTot += $e.Value
    if ($primeiro) { $parcTop = 'Parceiro ativo: ' + $k + ' (' + $e.Value + ')'; $primeiro = $false }
  }
  if ($parcRows -eq "") { $parcRows = '        <tr><td colspan="2" style="color:#6b7d7b">Nenhum lead de parceria nesta semana</td></tr>' + "`r`n" }
  $parcRows += '        <tr class="tot"><td>TOTAL PARCERIAS</td><td class="num">' + $parcTot + '</td></tr>'

  $sj = $ceUnit['sao_jose']; $jv = $ceUnit['joinville']
  $uniRows  = '        <tr><td><span class="pill sj">S&atilde;o Jos&eacute;</span></td><td class="num">' + $sj.agendaram + '</td><td class="num">' + $ceNovos.sao_jose + '</td><td class="num">' + $sj.compareceram + '</td><td class="num">' + $sj.cancelaram + '</td><td class="num">' + $sj.remarcaram + '</td><td class="num">' + $sj.noshow + '</td><td class="num">R$ ' + $sjFatFmt + '</td></tr>' + "`r`n"
  $uniRows += '        <tr><td><span class="pill jv">Joinville</span></td><td class="num">' + $jv.agendaram + '</td><td class="num">' + $ceNovos.joinville + '</td><td class="num">' + $jv.compareceram + '</td><td class="num">' + $jv.cancelaram + '</td><td class="num">' + $jv.remarcaram + '</td><td class="num">' + $jv.noshow + '</td><td class="num">R$ ' + $jvFatFmt + '</td></tr>' + "`r`n"
  $uniRows += '        <tr class="tot"><td>TOTAL</td><td class="num">' + $ce.agendaram + '</td><td class="num">' + $ceNovos.total + '</td><td class="num">' + $ce.compareceram + '</td><td class="num">' + $ce.cancelaram + '</td><td class="num">' + $ce.remarcaram + '</td><td class="num">' + $ce.noshow + '</td><td class="num">R$ ' + $fatFmt + '</td></tr>'

  $vendRows = ""; $tAt=0;$tQ=0;$tD=0;$tAg=0;$tCo=0;$tCa=0;$tRe=0;$tNs=0;$tFa=0.0; $anyFa=$false
  foreach ($v in @('Daiane','Ana','Brenda','Ana Paula')) {
    $at=$vend[$v].atendimentos; $q=$vend[$v].qualificados; $d=$vend[$v].desqualificados
    $ag=$ceVend[$v].agendaram; $co=$ceVend[$v].compareceram; $ca=$ceVend[$v].cancelaram; $re=$ceVend[$v].remarcaram; $ns=$ceVend[$v].noshow; $fa=$ceVend[$v].faturamento
    $faNum = 0; if ($null -ne $fa) { $faNum = [double]$fa }
    if (($at + $q + $d + $ag + $co + $ca + $re + $ns + $faNum) -le 0) { continue }  # oculta vendedora sem atividade na semana
    $tAt+=$at;$tQ+=$q;$tD+=$d;$tAg+=$ag;$tCo+=$co;$tCa+=$ca;$tRe+=$re;$tNs+=$ns
    $faDisp = '&mdash;'
    if ($null -ne $fa) { $faDisp = 'R$ ' + ("{0:N0}" -f [double]$fa); $tFa += [double]$fa; $anyFa = $true }
    $vendRows += '        <tr><td>' + $v + '</td><td class="num">' + $at + '</td><td class="num">' + $q + '</td><td class="num">' + $d + '</td><td class="num">' + $ag + '</td><td class="num">' + $co + '</td><td class="num">' + $ca + '</td><td class="num">' + $re + '</td><td class="num">' + $ns + '</td><td class="num">' + $faDisp + '</td></tr>' + "`r`n"
  }
  $tFaDisp = '&mdash;'; if ($anyFa) { $tFaDisp = 'R$ ' + ("{0:N0}" -f $tFa) }
  $vendRows += '        <tr class="tot"><td>Equipe</td><td class="num">' + $tAt + '</td><td class="num">' + $tQ + '</td><td class="num">' + $tD + '</td><td class="num">' + $tAg + '</td><td class="num">' + $tCo + '</td><td class="num">' + $tCa + '</td><td class="num">' + $tRe + '</td><td class="num">' + $tNs + '</td><td class="num">' + $tFaDisp + '</td></tr>'

  # ---- Biomedicas: atendidas (auto) + pacotes fechados + faturamento (captura semanal) + conversao ----
  $bioRows = ""; $bAt=0; $bFeSum=0; $bFaSum=0.0; $bAnyFe=$false; $bAnyFa=$false
  foreach ($bn in @('Kamile','Janaina','Bruna')) {
    $disp = $bn; if ($bn -eq 'Janaina') { $disp = 'Jana&iacute;na' } elseif ($bn -eq 'Kamile') { $disp = 'Camily' }
    $at = [int]$bio[$bn].atendidas
    $fe = $bio[$bn].fechados
    $fa = $bio[$bn].faturamento
    $feDisp = '&mdash;'; if ($null -ne $fe) { $feDisp = "$([int]$fe)"; $bFeSum += [int]$fe; $bAnyFe=$true }
    $faDisp = '&mdash;'; if ($null -ne $fa) { $faDisp = 'R$ ' + ("{0:N0}" -f [double]$fa); $bFaSum += [double]$fa; $bAnyFa=$true }
    $convDisp = '&mdash;'
    if (($null -ne $fe) -and $at -gt 0) { $convDisp = ([math]::Round([int]$fe / $at * 100,0)).ToString($ic) + '%' }
    $bAt += $at
    $bioRows += '        <tr><td>' + $disp + '</td><td class="num">' + $at + '</td><td class="num">' + $feDisp + '</td><td class="num">' + $convDisp + '</td><td class="num">' + $faDisp + '</td></tr>' + "`r`n"
  }
  $tFeDisp = '&mdash;'; if ($bAnyFe) { $tFeDisp = "$bFeSum" }
  $tBFaDisp = '&mdash;'; if ($bAnyFa) { $tBFaDisp = 'R$ ' + ("{0:N0}" -f $bFaSum) }
  $tConvDisp = '&mdash;'; if ($bAnyFe -and $bAt -gt 0) { $tConvDisp = ([math]::Round($bFeSum / $bAt * 100,0)).ToString($ic) + '%' }
  $bioRows += '        <tr class="tot"><td>Equipe</td><td class="num">' + $bAt + '</td><td class="num">' + $tFeDisp + '</td><td class="num">' + $tConvDisp + '</td><td class="num">' + $tBFaDisp + '</td></tr>'

  # ---- Conferencia do faturamento: Total = Vendedoras + Biomedicas + Outros ----
  if ($anyFa -and $bAnyFa) {
    $rv = [double]$tFa
    $rb = [double]$bFaSum
    $ro = [double]$ce.faturamento - $rv - $rb
    $roLabel = 'Outros/sem vendedor'
    $reconc = 'Confer&ecirc;ncia do faturamento: <b>Total R$ ' + ("{0:N0}" -f $ce.faturamento) + '</b> = Vendedoras R$ ' + ("{0:N0}" -f $rv) + ' + Biom&eacute;dicas R$ ' + ("{0:N0}" -f $rb) + ' + ' + $roLabel + ' R$ ' + ("{0:N0}" -f $ro) + '.'
    if ([math]::Abs($ro) -ge 50) { $reconc += ' <b style="color:var(--amarelo)">Confira o "Outros"</b> &mdash; venda sem vendedor ou de algu&eacute;m fora da lista.' }
  } else {
    $reconc = 'Confer&ecirc;ncia (Total = Vendedoras + Biom&eacute;dicas) aparece ap&oacute;s a captura de sexta.'
  }

  $repList = ""
  foreach ($c in $cancelados) {
    $pp = $c -split ' \| '
    $uni = "$($pp[0])"; $nm = "$($pp[1])"; $dt = "$($pp[2])"
    $pc = 'jv'; $pl = 'JV'; if ($uni -eq 'sao_jose') { $pc = 'sj'; $pl = 'SJ' }
    $dtBr = $dt; if ($dt -match '^\d{4}-(\d{2})-(\d{2})') { $dtBr = $Matches[2] + '/' + $Matches[1] }
    $repList += '          <div class="item"><span>' + $nm + ' <span class="pill ' + $pc + '">' + $pl + '</span></span><small>' + $dtBr + '</small></div>' + "`r`n"
  }
  if ($repList -eq "") { $repList = '          <div class="item">Nenhum cancelamento na semana</div>' }

  $semObs = ""
  if ($ceSemObs.Count -gt 0) { $semObs = ' A confirmar no CRM (agendamento sem vendedora na obs.): ' + (($ceSemObs | Select-Object -Unique) -join ', ') + '.' }

  # Motivos de encerramento (tabulacao) - lido de config/motivos.json (atualizado a partir do painel Paper Vines)
  $motHtml = ""
  $motPath = Join-Path $base "config/motivos.json"
  if (Test-Path $motPath) {
    try {
      $mot = Get-Content $motPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $colorMap = @{ verde = 'var(--verde)'; vermelho = 'var(--vermelho)'; azul = '#2b6cb0'; cinza = 'var(--cinza)' }
      $motHtml += '<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px">' + "`r`n"
      foreach ($g in $mot.grupos) {
        $col = 'var(--petroleo)'; if ($colorMap.ContainsKey("$($g.cor)")) { $col = $colorMap["$($g.cor)"] }
        $motHtml += '  <div style="border:1px solid var(--linha);border-radius:12px;padding:14px 16px">' + "`r`n"
        $motHtml += '    <div style="display:flex;justify-content:space-between;align-items:baseline;border-bottom:1px solid var(--linha);padding-bottom:8px;margin-bottom:8px"><span style="font-weight:700;color:' + $col + '">' + "$($g.nome)" + '</span><span style="font-size:22px;font-weight:800;color:' + $col + '">' + "$($g.total)" + '</span></div>' + "`r`n"
        foreach ($it in $g.itens) {
          $motHtml += '    <div style="display:flex;justify-content:space-between;font-size:13px;padding:3px 0"><span>' + "$($it.m)" + '</span><b>' + "$($it.n)" + '</b></div>' + "`r`n"
        }
        $motHtml += '  </div>' + "`r`n"
      }
      $motHtml += '</div>' + "`r`n"
      $motHtml += '<p style="font-size:12px;color:var(--cinza);margin-top:12px">' + "$($mot.nao_classificados)" + ' atendimentos ainda nao classificados no periodo. Fonte: ' + "$($mot.fonte)" + ' (periodo ' + "$($mot.periodo)" + '). Secao atualizada a partir do painel do Paper Vines.</p>' + "`r`n"
    } catch {
      $motHtml = '<p style="color:var(--cinza)">Nao foi possivel ler config/motivos.json.</p>'
    }
  } else {
    $motHtml = '<p style="color:var(--cinza)">Aguardando dados de motivos (config/motivos.json).</p>'
  }

  $tpl = Get-Content (Join-Path $base "Dashboard-template.html") -Raw -Encoding UTF8
  $tpl = $tpl.Replace('@@SEMANA@@', ($start.ToString('dd/MM') + ' - ' + $end.ToString('dd/MM')))
  $tpl = $tpl.Replace('@@ATUALIZADO@@', $now.ToString('dd/MM/yyyy HH:mm'))
  $tpl = $tpl.Replace('@@FAT@@', $fatFmt)
  $tpl = $tpl.Replace('@@PCTMETA@@', $pctMeta)
  $tpl = $tpl.Replace('@@AGEND@@', "$($ce.agendaram)")
  $tpl = $tpl.Replace('@@AGEND_CRIADOS@@', "$($ceNovos.total)")
  $tpl = $tpl.Replace('@@COMP@@', "$($ce.compareceram)")
  $tpl = $tpl.Replace('@@PCTCOMP@@', $pctComp)
  $tpl = $tpl.Replace('@@CANC@@', "$($ce.cancelaram)")
  $tpl = $tpl.Replace('@@PCTCANC@@', $pctCanc)
  $tpl = $tpl.Replace('@@REMARC@@', "$($ce.remarcaram)")
  $tpl = $tpl.Replace('@@PCTREMARC@@', $pctRemarc)
  $tpl = $tpl.Replace('@@NOSHOW@@', "$($ce.noshow)")
  $tpl = $tpl.Replace('@@PCTNS@@', $pctNs)
  $tpl = $tpl.Replace('@@UNIDADE_ROWS@@', $uniRows)
  $tpl = $tpl.Replace('@@VEND_ROWS@@', $vendRows)
  $tpl = $tpl.Replace('@@BIO_ROWS@@', $bioRows)
  $tpl = $tpl.Replace('@@RECONC@@', $reconc)
  $tpl = $tpl.Replace('@@REP_LIST@@', $repList)
  $tpl = $tpl.Replace('@@LEADS@@', "$total")
  $tpl = $tpl.Replace('@@CAMPANHA@@', "$campanha")
  $tpl = $tpl.Replace('@@MANUAIS@@', "$manuais")
  $tpl = $tpl.Replace('@@QUALIF@@', "$qualificados")
  $tpl = $tpl.Replace('@@PCTQ@@', $pctQ)
  $tpl = $tpl.Replace('@@DESQ@@', "$desqualificados")
  $tpl = $tpl.Replace('@@PCTD@@', $pctD)
  $tpl = $tpl.Replace('@@CLINSJ@@', "$clinSJ")
  $tpl = $tpl.Replace('@@CLINJV@@', "$clinJV")
  $tpl = $tpl.Replace('@@PARC_TOPO@@', $parcTop)
  $tpl = $tpl.Replace('@@PARC_ROWS@@', $parcRows)
  $tpl = $tpl.Replace('@@SEMOBS@@', $semObs)
  $tpl = $tpl.Replace('@@MOTIVOS@@', $motHtml)
  $tpl | Out-File (Join-Path $base "Dashboard-Comercial.html") -Encoding UTF8
  # Copia para site\index.html (pasta que a Cloudflare publica online)
  $siteDir = Join-Path $base "site"
  if (-not (Test-Path $siteDir)) { New-Item -ItemType Directory -Path $siteDir | Out-Null }
  try { if ($dbgNovos) { [System.IO.File]::WriteAllText((Join-Path $siteDir "debug-novos.json"), ($dbgNovos | ConvertTo-Json -Depth 6)) } } catch {}
  [System.IO.File]::WriteAllText((Join-Path $siteDir "index.html"), $tpl, (New-Object System.Text.UTF8Encoding($false)))
  # Forca o Netlify a servir como pagina HTML (evita mostrar o codigo como texto)
  [System.IO.File]::WriteAllText((Join-Path $siteDir "_headers"), "/*`r`n  Content-Type: text/html; charset=UTF-8`r`n")
  [System.IO.File]::WriteAllText((Join-Path $siteDir "netlify.toml"), "[[headers]]`r`n  for = `"/*`"`r`n  [headers.values]`r`n    Content-Type = `"text/html; charset=UTF-8`"`r`n")
  Write-Host ""
  Write-Host "Dashboard atualizado: Dashboard-Comercial.html (e site\index.html)" -ForegroundColor Green

  # Publica online no Netlify, se estiver configurado (token + site id)
  $nfTokenFile = Join-Path $base "config/netlify-token.txt"
  $nfSiteFile  = Join-Path $base "config/netlify-site.txt"
  if ((Test-Path $nfTokenFile) -and (Test-Path $nfSiteFile)) {
    try {
      $nfToken = (Get-Content $nfTokenFile -Raw).Trim()
      $nfSite  = (Get-Content $nfSiteFile -Raw).Trim()
      $zipPath = Join-Path $base "site.zip"
      if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
      Compress-Archive -Path (Join-Path $siteDir '*') -DestinationPath $zipPath -Force
      Write-Host "Publicando online (Netlify)..." -ForegroundColor DarkGray
      $nfHeaders = @{ Authorization = "Bearer $nfToken" }
      $r = Invoke-RestMethod -Uri "https://api.netlify.com/api/v1/sites/$nfSite/deploys" -Method Post -Headers $nfHeaders -ContentType "application/zip" -InFile $zipPath
      Write-Host ("Publicado online: {0}" -f $r.ssl_url) -ForegroundColor Green
      Remove-Item $zipPath -Force
    } catch {
      Write-Host ("Falha ao publicar online (Netlify): {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
  }
} catch {
  Write-Host ("ERRO ao gerar o dashboard: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

if (-not ($args -contains '-nopause') -and [Environment]::UserInteractive) { Read-Host "Pronto! Enter para fechar" }
