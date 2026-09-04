#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Gera site/analise-historica.html — analise comercial de N semanas
da Clinica Cabelo & Saude (Sao Jose + Joinville), a partir da API
do Clinica Experts.

Metrica central: a AVALIACAO e a entrada do funil, venha de consulta
avulsa ou inclusa em pacote promocional. E ela que abre a oportunidade
de upsell de alto ticket para a biomedica.

Sem dependencias externas (somente biblioteca padrao do Python 3).

Uso:
    python3 gerar-analise-historica.py
    python3 gerar-analise-historica.py --selftest    (valida a logica, nao acessa a rede)

Config esperada: config/clinica-experts-tokens.json
Saida:           site/analise-historica.html
"""

import json
import os
import re
import sys
import time
import datetime
import traceback
import unicodedata
import urllib.request
import urllib.parse
import urllib.error

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
API_BASE = "https://api.clinicaexperts.com.br/api/v1"
META_SEMANAL = 30023.0
N_SEMANAS = 11
TIMEOUT = 60

# Procedimentos que representam uma AVALIACAO (entrada de funil).
# Vale para as duas unidades: o nome varia entre SJ e JV.
PROC_AVALIACAO = {
    "Consulta Inicial",
    "Consulta Online",
    "Avaliação Gratuita Presencial",
    "Avaliação Capilar Gratuita",
    "Avaliação Gratuita Online",
}

# Vendas de alto ticket (fechadas pelas biomedicas).
RE_ALTO = re.compile(r"terapia combinada|protocolo premium|monoterapia", re.IGNORECASE)

UNIDADES = [("sao_jose", "São José", "sj"), ("joinville", "Joinville", "jv")]

# Ordem importa: 'janaina' contem a substring 'ana' e seria capturada
# pela regra generica de 'Ana' se testada depois.
REGRAS_VENDEDORA = [
    ("Daiane", ("daiane",)),
    ("Brenda", ("brenda",)),
    ("Janaína", ("janain", "janaín")),
    ("Ana Paula", ("ana paula", "euz")),
    ("Marília", ("maril", "maríl")),
    ("Eduardo", ("eduardo",)),
    ("Ana", ("ana",)),
]
VENDEDORAS_PRINCIPAIS = ["Daiane", "Brenda", "Ana", "Ana Paula"]


# --------------------------------------------------------------------------
# utilidades
# --------------------------------------------------------------------------

def normalizar(txt):
    if not txt:
        return ""
    t = unicodedata.normalize("NFD", str(txt))
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return " ".join(t.lower().split())


def vendedora_de(anotacao):
    """Le 'Vendedora X' no campo annotation do agendamento."""
    if not anotacao:
        return None
    a = str(anotacao).lower()
    for nome, chaves in REGRAS_VENDEDORA:
        if any(k in a for k in chaves):
            return nome
    return None


def eh_avaliacao(procedimentos):
    return any(p in PROC_AVALIACAO for p in procedimentos)


def eh_alto_ticket(descricao):
    return bool(RE_ALTO.search(descricao or ""))


def brl(valor):
    return "R$ " + format(int(round(valor)), ",d").replace(",", ".")


def num(valor, casas=1):
    return format(valor, ".%df" % casas).replace(".", ",")


def pct(parte, todo):
    return int(round(parte / todo * 100)) if todo else 0


# --------------------------------------------------------------------------
# janela de semanas (sexta -> quinta, fuso America/Sao_Paulo)
# --------------------------------------------------------------------------

def inicio_semana_corrente(hoje):
    """
    Semana comercial = sexta -> quinta. Sexta-feira = weekday 4.

    Na SEXTA a semana que interessa e a que acabou de fechar (sexta anterior
    ate ontem, quinta), porque e o dia da reuniao de fechamento. Tratar a
    sexta como inicio de semana nova faria a serie terminar num periodo de
    um dia so, justamente na hora de apresentar.

    De sabado a quinta, usa a sexta mais recente (semana corrente parcial).
    """
    delta = (hoje.weekday() - 4) % 7
    if delta == 0:  # e sexta: volta para a semana fechada
        delta = 7
    return hoje - datetime.timedelta(days=delta)


def montar_semanas(hoje, quantas=N_SEMANAS):
    """Retorna [(inicio, fim)] em ordem cronologica, terminando na semana corrente."""
    fim_ancora = inicio_semana_corrente(hoje)
    out = []
    for i in range(quantas - 1, -1, -1):
        ini = fim_ancora - datetime.timedelta(days=7 * i)
        out.append((ini, ini + datetime.timedelta(days=6)))
    return out


def iso(d):
    return d.strftime("%Y-%m-%d")


def ddmm(d):
    return d.strftime("%d/%m")


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

# Alguns servicos rejeitam o User-Agent padrao do urllib ("Python-urllib/3.x").
# Pelo navegador a mesma chamada funciona, entao identificamos o cliente.
CABECALHOS = {
    "Accept": "application/json",
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
}


def _abrir(url, token, ref=None, tentativas=3):
    """GET com retry e mensagem de erro que inclui o corpo da resposta da API.

    'ref' e o Clinic-Reference da unidade. Desde a migracao multiclinicas do
    Clinica Experts (28/08/2026) a API EXIGE esse cabecalho: sem ele Sao Jose
    responde 403 (codigo CORN1Z1). Joinville hoje responde 200 com ou sem, mas
    o cabecalho e enviado sempre nas duas, porque o comportamento de JV pode
    mudar do mesmo jeito que o de SJ mudou.
    """
    ultimo = None
    for t in range(tentativas):
        cab = dict(CABECALHOS)
        cab["Authorization"] = "Bearer " + token
        if ref:
            cab["Clinic-Reference"] = ref
        try:
            req = urllib.request.Request(url, headers=cab)
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            corpo = ""
            try:
                corpo = e.read().decode("utf-8", "replace")[:400]
            except Exception:
                pass
            ultimo = "HTTP %s (%s) — resposta da API: %s" % (e.code, e.reason, corpo)
            transitorio = e.code in (408, 429, 500, 502, 503, 504)
            if not transitorio:
                raise RuntimeError(ultimo)
        except Exception as e:
            ultimo = "%s: %s" % (type(e).__name__, e)
        if t < tentativas - 1:
            espera = 3 * (t + 1)
            print("   tentativa %d falhou (%s). Nova tentativa em %ds..." % (t + 1, ultimo, espera))
            time.sleep(espera)
    raise RuntimeError(ultimo or "falha desconhecida")


def buscar(token, recurso, inicio, fim, ref=None, max_paginas=60):
    """GET paginado num intervalo. Devolve lista de registros."""
    registros = []
    pagina = 1
    while pagina <= max_paginas:
        qs = urllib.parse.urlencode({
            "starts_at": inicio + "T00:00:00-03:00",
            "ends_at": fim + "T23:59:59-03:00",
            "page": pagina,
        })
        dados = _abrir("%s/%s?%s" % (API_BASE, recurso, qs), token, ref)
        lote = dados.get("data") or []
        if not lote:
            break
        registros.extend(lote)
        ultima = (dados.get("meta") or {}).get("last_page") or 1
        if pagina >= ultima:
            break
        pagina += 1
    return registros


def buscar_em_blocos(token, recurso, inicio, fim, ref=None, meses=4):
    """
    Quebra o intervalo em blocos menores. A API recusa periodos maiores que
    1 ano; blocos curtos tambem reduzem timeout e paginacao longa.
    Deduplica pelo uuid, porque os blocos podem se sobrepor na borda.
    """
    d_ini = datetime.date(*[int(x) for x in inicio.split("-")])
    d_fim = datetime.date(*[int(x) for x in fim.split("-")])
    vistos, saida = set(), []
    atual = d_ini
    while atual <= d_fim:
        # avanca ~meses*30 dias
        prox = min(atual + datetime.timedelta(days=meses * 30), d_fim)
        lote = buscar(token, recurso, atual.strftime("%Y-%m-%d"), prox.strftime("%Y-%m-%d"), ref)
        novos = 0
        for r in lote:
            chave = r.get("uuid") or json.dumps(r, sort_keys=True)[:200]
            if chave in vistos:
                continue
            vistos.add(chave)
            saida.append(r)
            novos += 1
        print("   %s..%s -> %d registros (%d novos)" % (atual, prox, len(lote), novos))
        if prox >= d_fim:
            break
        atual = prox + datetime.timedelta(days=1)
    return saida


def coletar(cfg, semanas):
    """Puxa avaliacoes e vendas das duas unidades."""
    primeiro = iso(semanas[0][0])
    ultimo = iso(semanas[-1][1])
    # Agendamentos: janela de 1 ano (limite da API) para capturar avaliacoes
    # criadas agora com data marcada para meses a frente.
    ano_ini = "%d-01-01" % semanas[0][0].year
    ano_fim = "%d-12-31" % semanas[0][0].year

    avaliacoes, vendas = [], []
    for chave, rotulo, _ in UNIDADES:
        unidade = (cfg.get("clinics") or {}).get(chave)
        if not unidade or not unidade.get("token"):
            raise RuntimeError("Token ausente para a unidade '%s' em config/clinica-experts-tokens.json" % chave)
        token = unidade["token"]
        # Clinic-Reference: obrigatorio desde a migracao multiclinicas (28/08/2026).
        # Sem ele Sao Jose responde 403 (CORN1Z1) e o script inteiro morre com codigo 3.
        ref = (unidade.get("clinic_reference") or "").strip()
        if not ref or ref.upper() == "PENDENTE":
            raise RuntimeError(
                "clinic_reference ausente ou PENDENTE para a unidade '%s' em "
                "config/clinica-experts-tokens.json. A API exige o cabecalho "
                "Clinic-Reference desde 28/08/2026; sem ele Sao Jose responde 403 "
                "(CORN1Z1)." % chave
            )
        print(" %s: buscando agendamentos de %s a %s... (Clinic-Reference: %s)"
              % (rotulo, ano_ini, ano_fim, ref))

        for b in buscar_em_blocos(token, "bookings", ano_ini, ano_fim, ref):
            procs = [p.get("name") for p in (b.get("procedures") or [])]
            if not eh_avaliacao(procs):
                continue
            paciente = (b.get("patient") or {}).get("name") or ""
            avaliacoes.append({
                "unidade": rotulo,
                "status": b.get("status"),
                "criado": (b.get("created_at") or "")[:10],
                "data": (b.get("starts_at") or "")[:10],
                "anotacao": b.get("annotation") or "",
                "paciente": paciente,
            })

        print(" %s: buscando contas de %s a %s..." % (rotulo, primeiro, ultimo))
        for c in buscar_em_blocos(token, "bills", primeiro, ultimo, ref):
            if c.get("type") != "Venda":
                continue
            centavos = c.get("final_amount") or 0
            if centavos <= 0:
                continue  # conta de atendimento sem cobranca
            vendas.append({
                "unidade": rotulo,
                "data": (c.get("created_at") or "")[:10],
                "valor": centavos / 100.0,
                "descricao": c.get("description") or "",
                "paciente": (c.get("person") or {}).get("name") or "",
            })
    return avaliacoes, vendas


# --------------------------------------------------------------------------
# agregacao
# --------------------------------------------------------------------------

def mapear_paciente_vendedora(avaliacoes):
    """Paciente -> vendedora que agendou a avaliacao dele."""
    mapa = {}
    for a in avaliacoes:
        v = vendedora_de(a["anotacao"])
        chave = normalizar(a["paciente"])
        if v and chave and chave not in mapa:
            mapa[chave] = v
    return mapa


def agregar(avaliacoes, vendas, semanas):
    mapa = mapear_paciente_vendedora(avaliacoes)
    linhas = []
    for ini, fim in semanas:
        a, b = iso(ini), iso(fim)
        criadas = [x for x in avaliacoes if a <= x["criado"] <= b]
        agendadas = [x for x in avaliacoes if a <= x["data"] <= b]
        realizadas = [x for x in agendadas if x["status"] == "done"]
        canceladas = [x for x in agendadas if x["status"] == "canceled"]

        do_periodo = [v for v in vendas if a <= v["data"] <= b]
        alto = [v for v in do_periodo if eh_alto_ticket(v["descricao"])]
        promo = [v for v in do_periodo if not eh_alto_ticket(v["descricao"])]

        por_vend = {}
        for x in criadas:
            k = vendedora_de(x["anotacao"]) or "S/ obs."
            por_vend[k] = por_vend.get(k, 0) + 1

        receita_vend = {}
        for v in promo:
            k = mapa.get(normalizar(v["paciente"]), "Sem dono")
            receita_vend[k] = receita_vend.get(k, 0.0) + v["valor"]

        r_alto = sum(v["valor"] for v in alto)
        r_promo = sum(v["valor"] for v in promo)
        linhas.append({
            "ini": ini, "fim": fim,
            "criadas": len(criadas),
            "agendadas": len(agendadas),
            "realizadas": len(realizadas),
            "canceladas": len(canceladas),
            "pct_comp": pct(len(realizadas), len(agendadas)),
            "pct_canc": pct(len(canceladas), len(agendadas)),
            "alto_n": len(alto), "alto_r": r_alto,
            "promo_n": len(promo), "promo_r": r_promo,
            "total_r": r_alto + r_promo,
            "upsell": pct(len(alto), len(realizadas)),
            "por_vend": por_vend,
            "receita_vend": receita_vend,
        })
    return linhas


def resumo(linhas, corte=2):
    """Compara as semanas de base com as ultimas `corte` semanas."""
    base, recente = linhas[:-corte], linhas[-corte:]
    if not base:
        base = linhas

    def media(grupo, campo):
        return sum(l[campo] for l in grupo) / float(len(grupo))

    def variacao(campo):
        antes, depois = media(base, campo), media(recente, campo)
        return antes, depois, (int(round((depois / antes - 1) * 100)) if antes else 0)

    r = {"n_base": len(base), "n_recente": len(recente)}
    for campo in ("criadas", "realizadas", "promo_r", "alto_r", "total_r"):
        r[campo] = variacao(campo)
    tot_real_base = sum(l["realizadas"] for l in base)
    tot_alto_base = sum(l["alto_n"] for l in base)
    tot_real_rec = sum(l["realizadas"] for l in recente)
    tot_alto_rec = sum(l["alto_n"] for l in recente)
    r["upsell_base"] = pct(tot_alto_base, tot_real_base)
    r["upsell_recente"] = pct(tot_alto_rec, tot_real_rec)
    r["rpa_base"] = (sum(l["total_r"] for l in base) / tot_real_base) if tot_real_base else 0
    r["rpa_recente"] = (sum(l["total_r"] for l in recente) / tot_real_rec) if tot_real_rec else 0
    return r


# --------------------------------------------------------------------------
# graficos (SVG inline, sem biblioteca)
# --------------------------------------------------------------------------

def grafico_linhas(linhas):
    x0, x1, y0, y1 = 60, 880, 20, 240
    passo = (x1 - x0) / float(max(1, len(linhas) - 1))
    topo = max([l["alto_r"] for l in linhas] + [l["promo_r"] for l in linhas] + [1])
    escala = (int(topo / 8000) + 1) * 8000

    def ponto(i, valor):
        return "%.1f,%.1f" % (x0 + i * passo, y1 - (valor / escala) * (y1 - y0))

    p_alto = " ".join(ponto(i, l["alto_r"]) for i, l in enumerate(linhas))
    p_promo = " ".join(ponto(i, l["promo_r"]) for i, l in enumerate(linhas))

    grades, rotulos_y = [], []
    for k in range(5):
        v = escala * k / 4.0
        y = y1 - (v / escala) * (y1 - y0)
        grades.append('<line x1="%d" y1="%.1f" x2="900" y2="%.1f"></line>' % (x0, y, y))
        rotulos_y.append('<text x="55" y="%.1f">%dk</text>' % (y + 3, int(round(v / 1000))))

    bolas_a = "".join('<circle cx="%.1f" cy="%.1f" r="3"></circle>' % (
        x0 + i * passo, y1 - (l["alto_r"] / escala) * (y1 - y0)) for i, l in enumerate(linhas))
    bolas_p = "".join('<circle cx="%.1f" cy="%.1f" r="3"></circle>' % (
        x0 + i * passo, y1 - (l["promo_r"] / escala) * (y1 - y0)) for i, l in enumerate(linhas))

    rotulos_x = "".join(
        '<text x="%.1f" y="258"%s>%s</text>' % (
            x0 + i * passo,
            ' fill="#c0392b" font-weight="700"' if i >= len(linhas) - 2 else "",
            ddmm(l["ini"]))
        for i, l in enumerate(linhas))

    destaque_x = x0 + (len(linhas) - 2.5) * passo
    return """<svg viewBox="0 0 900 275" style="width:100%%;height:auto">
  <rect x="%.1f" y="20" width="%.1f" height="220" fill="#c0392b" opacity="0.07"></rect>
  <g stroke="#dfeae8" stroke-width="1">%s</g>
  <g fill="#6b7d7b" font-size="10" text-anchor="end">%s</g>
  <polyline fill="none" stroke="#0e4d49" stroke-width="2.5" stroke-linejoin="round" points="%s"></polyline>
  <polyline fill="none" stroke="#1f9e8f" stroke-width="2.5" stroke-linejoin="round" points="%s"></polyline>
  <g fill="#0e4d49">%s</g><g fill="#1f9e8f">%s</g>
  <g fill="#6b7d7b" font-size="10" text-anchor="middle">%s</g>
</svg>""" % (destaque_x, 900 - destaque_x, "".join(grades), "".join(rotulos_y),
             p_alto, p_promo, bolas_a, bolas_p, rotulos_x)


def grafico_barras(linhas):
    x0, base_y, altura = 60, 130, 110
    passo = 820 / float(max(1, len(linhas) - 1))
    topo = max([l["criadas"] for l in linhas] + [1])
    barras, valores, rotulos = [], [], []
    for i, l in enumerate(linhas):
        h = (l["criadas"] / float(topo)) * altura
        cx = x0 + i * passo
        y = base_y - h
        cor = "#c0392b" if i >= len(linhas) - 2 else "#1f9e8f"
        barras.append('<rect x="%.1f" y="%.1f" width="44" height="%.1f" fill="%s" rx="3"></rect>' % (cx - 22, y, h, cor))
        valores.append('<text x="%.1f" y="%.1f"%s>%d</text>' % (
            cx, y - 6, ' fill="#c0392b"' if i >= len(linhas) - 2 else "", l["criadas"]))
        rotulos.append('<text x="%.1f" y="147"%s>%s</text>' % (
            cx, ' fill="#c0392b" font-weight="700"' if i >= len(linhas) - 2 else "", ddmm(l["ini"])))
    return """<svg viewBox="0 0 900 165" style="width:100%%;height:auto">
  <line x1="30" y1="130" x2="900" y2="130" stroke="#dfeae8"></line>
  <g>%s</g>
  <g fill="#0e4d49" font-size="12" font-weight="700" text-anchor="middle">%s</g>
  <g fill="#6b7d7b" font-size="10" text-anchor="middle">%s</g>
</svg>""" % ("".join(barras), "".join(valores), "".join(rotulos))


# --------------------------------------------------------------------------
# HTML
# --------------------------------------------------------------------------

CSS = """:root{--petroleo:#0e4d49;--petroleo2:#12615c;--verde:#1f9e8f;--claro:#e8f3f1;
--texto:#173b39;--cinza:#6b7d7b;--linha:#dfeae8;--amarelo:#e6b800;--vermelho:#c0392b;--bg:#f4f8f7;--card:#fff}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,-apple-system,Arial,sans-serif;background:var(--bg);color:var(--texto);line-height:1.4}
.wrap{max-width:1180px;margin:0 auto;padding:24px}
header.top{background:linear-gradient(120deg,var(--petroleo),var(--verde));color:#fff;border-radius:16px;padding:24px 28px;
display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px;box-shadow:0 6px 24px rgba(14,77,73,.18)}
header.top h1{font-size:24px;font-weight:700}header.top .sub{opacity:.9;font-size:13px;margin-top:4px}
.badge{background:rgba(255,255,255,.18);padding:8px 14px;border-radius:999px;font-size:13px;font-weight:600}
h2.sec{font-size:15px;text-transform:uppercase;letter-spacing:1px;color:var(--petroleo);margin:30px 0 14px;display:flex;align-items:center;gap:8px}
h2.sec::before{content:"";width:6px;height:18px;background:var(--verde);border-radius:3px;display:inline-block}
.card{background:var(--card);border:1px solid var(--linha);border-radius:14px;padding:18px 20px;box-shadow:0 2px 10px rgba(14,77,73,.05)}
table{width:100%;border-collapse:collapse;font-size:14px}
th,td{text-align:left;padding:11px 12px;border-bottom:1px solid var(--linha)}
th{font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:var(--cinza);font-weight:700}
td.num,th.num{text-align:center}tr:last-child td{border-bottom:none}
.tot td{font-weight:800;color:var(--petroleo);background:var(--claro)}
.alerta{background:#fdecea;border:1px solid #f3b8b0;border-left:5px solid var(--vermelho);border-radius:12px;
padding:14px 18px;margin-top:16px;font-size:13px;color:#7a2018}
.nota{font-size:12px;color:var(--cinza);margin-top:10px}
.rec{background:#fdecea}
footer{margin-top:28px;text-align:center;color:var(--cinza);font-size:12px}"""


# Classes que a analise usa e que o template do painel semanal nao tem.
# Vao junto quando as secoes sao injetadas no index.html.
CSS_EXTRA = """<style>
.alerta{background:#fdecea;border:1px solid #f3b8b0;border-left:5px solid #c0392b;border-radius:12px;
padding:14px 18px;margin-top:16px;font-size:13px;color:#7a2018}
.nota{font-size:12px;color:#6b7d7b;margin-top:10px}
.rec{background:#fdecea}
</style>"""


def montar_html(linhas, res, gerado_em, somente_secoes=False):
    ini, fim = linhas[0]["ini"], linhas[-1]["fim"]

    # --- tabela semanal ---
    tr_sem = []
    for i, l in enumerate(linhas):
        cls = ' class="rec"' if i >= len(linhas) - 2 else ""
        tr_sem.append(
            "<tr%s><td>%s &ndash; %s</td><td class=\"num\">%d</td><td class=\"num\">%d</td>"
            "<td class=\"num\">%d</td><td class=\"num\">%d%%</td><td class=\"num\">%d%%</td>"
            "<td class=\"num\">%d</td><td class=\"num\">%d%%</td><td class=\"num\">%s</td>"
            "<td class=\"num\">%s</td><td class=\"num\">%s</td></tr>" % (
                cls, ddmm(l["ini"]), ddmm(l["fim"]), l["criadas"], l["agendadas"], l["realizadas"],
                l["pct_comp"], l["pct_canc"], l["alto_n"], l["upsell"],
                brl(l["promo_r"]), brl(l["alto_r"]), brl(l["total_r"])))

    base = linhas[:-2] or linhas
    n = float(len(base))
    tot_ag = sum(l["agendadas"] for l in base)
    tot_re = sum(l["realizadas"] for l in base)
    tot_ca = sum(l["canceladas"] for l in base)
    tot_al = sum(l["alto_n"] for l in base)
    tr_sem.append(
        "<tr class=\"tot\"><td>Média das %d primeiras</td><td class=\"num\">%s</td><td class=\"num\">%s</td>"
        "<td class=\"num\">%s</td><td class=\"num\">%d%%</td><td class=\"num\">%d%%</td>"
        "<td class=\"num\">%s</td><td class=\"num\">%d%%</td><td class=\"num\">%s</td>"
        "<td class=\"num\">%s</td><td class=\"num\">%s</td></tr>" % (
            len(base), num(sum(l["criadas"] for l in base) / n), num(tot_ag / n), num(tot_re / n),
            pct(tot_re, tot_ag), pct(tot_ca, tot_ag), num(tot_al / n), pct(tot_al, tot_re),
            brl(sum(l["promo_r"] for l in base) / n), brl(sum(l["alto_r"] for l in base) / n),
            brl(sum(l["total_r"] for l in base) / n)))

    # --- avaliacoes por vendedora ---
    nomes = list(VENDEDORAS_PRINCIPAIS)
    extras = sorted({k for l in linhas for k in l["por_vend"]
                     if k not in nomes and k != "S/ obs."})
    colunas = nomes + (["Outros"] if extras else []) + ["S/ obs."]

    def valor_vend(l, col):
        if col == "Outros":
            return sum(v for k, v in l["por_vend"].items() if k in extras)
        return l["por_vend"].get(col, 0)

    tr_vend = []
    for i, l in enumerate(linhas):
        cls = ' class="rec"' if i >= len(linhas) - 2 else ""
        celulas = "".join('<td class="num">%d</td>' % valor_vend(l, c) for c in colunas)
        tr_vend.append("<tr%s><td>%s</td>%s<td class=\"num\">%d</td></tr>" % (
            cls, ddmm(l["ini"]), celulas, l["criadas"]))
    for rotulo, grupo in (("Média das %d primeiras" % len(base), base), ("Média últimas 2", linhas[-2:])):
        m = float(len(grupo))
        celulas = "".join('<td class="num">%s</td>' % num(sum(valor_vend(l, c) for l in grupo) / m) for c in colunas)
        tr_vend.append("<tr class=\"tot\"><td>%s</td>%s<td class=\"num\">%s</td></tr>" % (
            rotulo, celulas, num(sum(l["criadas"] for l in grupo) / m)))

    # --- receita promocional por vendedora ---
    col_rec = nomes + ["Sem dono"]
    tr_rec = []
    for i, l in enumerate(linhas):
        cls = ' class="rec"' if i >= len(linhas) - 2 else ""
        celulas = "".join(
            '<td class="num">%s</td>' % (brl(l["receita_vend"][c]) if l["receita_vend"].get(c) else "&mdash;")
            for c in col_rec)
        tr_rec.append("<tr%s><td>%s</td>%s<td class=\"num\">%s</td></tr>" % (
            cls, ddmm(l["ini"]), celulas, brl(l["promo_r"])))

    cri_a, cri_d, cri_v = res["criadas"]
    rea_a, rea_d, rea_v = res["realizadas"]
    pro_a, pro_d, pro_v = res["promo_r"]
    alt_a, alt_d, alt_v = res["alto_r"]
    tot_a, tot_d, _ = res["total_r"]
    perdidas = rea_a - rea_d

    alerta = (
        "<b>O que a série mostra:</b> o pacote promocional <b>inclui avaliação</b>, então ele é uma entrada de funil "
        "igual à consulta — a mesma oportunidade de upsell para a biomédica. Medindo assim, a conversão está saudável: "
        "<b>taxa de upsell de %d%% na base contra %d%% nas últimas 2 semanas</b>. <b>As biomédicas não converteram pior.</b> "
        "O que mudou foi o <b>volume de avaliações realizadas: %s/semana para %s/semana (%+d%%)</b>. "
        "O alto ticket caiu %+d%% porque não há mais para quem vender. "
        "<b>O gargalo é geração de avaliação — que é o output das vendedoras (%+d%%).</b>" % (
            res["upsell_base"], res["upsell_recente"], num(rea_a), num(rea_d), rea_v, alt_v, cri_v))

    partes = ["""<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Análise Comercial — Cabelo &amp; Saúde</title><style>%s</style></head><body><div class="wrap">
<header class="top"><div><h1>Análise Comercial &mdash; %d semanas</h1>
<div class="sub">Clínica Cabelo &amp; Saúde &middot; São José + Joinville &middot; Gerado automaticamente</div></div>
<div style="text-align:right"><div class="badge">%s a %s</div>
<div class="sub" style="margin-top:8px">Atualizado em: %s</div></div></header>""" % (CSS, len(linhas), ddmm(ini), ddmm(fim), gerado_em)]

    partes.append('<div class="alerta">%s</div>' % alerta)

    partes.append("""<h2 class="sec">Receita por classe de produto</h2><div class="card">
<div style="display:flex;gap:22px;align-items:center;margin-bottom:6px;font-size:12px;font-weight:700">
<span><span style="display:inline-block;width:22px;height:3px;background:#0e4d49;vertical-align:middle;margin-right:6px"></span>Alto ticket (biomédicas)</span>
<span><span style="display:inline-block;width:22px;height:3px;background:#1f9e8f;vertical-align:middle;margin-right:6px"></span>Promocional (vendedoras)</span>
<span style="color:var(--cinza);font-weight:600">Faixa vermelha = 2 semanas mais recentes</span></div>
%s</div>""" % grafico_linhas(linhas))

    partes.append("""<h2 class="sec">Avaliações criadas por semana (output das vendedoras)</h2><div class="card">%s
<p class="nota">Média das %d primeiras semanas: <b>%s/semana</b>. Últimas 2: <b>%s</b> (%+d%%). Avaliação criada hoje
vira consulta realizada em 2 a 4 semanas — por isso a queda aqui antecipa a queda de receita.</p></div>""" % (
        grafico_barras(linhas), res["n_base"], num(cri_a), num(cri_d), cri_v))

    partes.append("""<h2 class="sec">Funil real — a avaliação é a entrada, venha de consulta ou de pacote</h2>
<div class="card" style="overflow-x:auto"><table>
<thead><tr><th>Período</th><th class="num">Avaliações criadas /sem</th><th class="num">Realizadas /sem</th>
<th class="num">Vendas alto ticket /sem</th><th class="num">Taxa de upsell</th>
<th class="num">Receita por avaliação realizada</th></tr></thead><tbody>
<tr><td>Base (%d semanas)</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td>
<td class="num">%d%%</td><td class="num">%s</td></tr>
<tr class="rec"><td><b>Últimas 2 semanas</b></td><td class="num"><b>%s</b></td><td class="num"><b>%s</b></td>
<td class="num"><b>%s</b></td><td class="num">%d%%</td><td class="num">%s</td></tr>
</tbody></table>
<p class="nota"><b>A avaliação inclusa no pacote promocional é a mesma oportunidade de upsell que a consulta.</b>
A entrada de funil conta as duas: Consulta Inicial, Consulta Online, Avaliação Gratuita Presencial,
Avaliação Capilar Gratuita e Avaliação Gratuita Online. Cada avaliação realizada vale em média
<b>%s</b> de receita total (promocional + alto ticket). As <b>%s avaliações/semana</b> a menos valem
<b>%s por semana</b>.</p></div>""" % (
        res["n_base"], num(cri_a), num(rea_a),
        num(sum(l["alto_n"] for l in base) / n), res["upsell_base"], brl(res["rpa_base"]),
        num(cri_d), num(rea_d), num(sum(l["alto_n"] for l in linhas[-2:]) / 2.0),
        res["upsell_recente"], brl(res["rpa_recente"]),
        brl(res["rpa_base"]), num(perdidas), brl(perdidas * res["rpa_base"])))

    partes.append("""<h2 class="sec">Tabela semanal completa</h2><div class="card" style="overflow-x:auto"><table>
<thead><tr><th>Semana</th><th class="num">Aval. criadas</th><th class="num">Agendadas</th><th class="num">Realizadas</th>
<th class="num">%% Comp.</th><th class="num">%% Canc.</th><th class="num">Alto tkt (n)</th><th class="num">Upsell</th>
<th class="num">Promo (vend.)</th><th class="num">Alto ticket</th><th class="num">Total</th></tr></thead>
<tbody>%s</tbody></table>
<p class="nota"><b>Alto ticket</b> = Terapia Combinada, Protocolo Premium e Monoterapia Injetável (biomédicas).
<b>Promo</b> = atendimento, microagulhamento promocional, Lavieen e venda personalizada (vendedoras).
Classificação feita pela descrição da conta. Contas do tipo Venda com valor zero são registros de atendimento
sem cobrança e ficam de fora.</p></div>""" % "".join(tr_sem))

    partes.append("""<h2 class="sec">Avaliações criadas por vendedora</h2><div class="card" style="overflow-x:auto"><table>
<thead><tr><th>Semana</th>%s<th class="num">Total</th></tr></thead><tbody>%s</tbody></table>
<p class="nota">Atribuição pela observação "Vendedora X" no agendamento. Comparar uma vendedora com outra numa
semana só é ruído; comparar cada uma com o próprio histórico é sinal. <b>Este é o indicador de performance
das vendedoras</b> — não a receita promocional, que subestima a contribuição delas.</p></div>""" % (
        "".join('<th class="num">%s</th>' % c for c in colunas), "".join(tr_vend)))

    partes.append("""<h2 class="sec">Receita promocional por vendedora</h2><div class="card" style="overflow-x:auto"><table>
<thead><tr><th>Semana</th>%s<th class="num">Total promo</th></tr></thead><tbody>%s</tbody></table>
<p class="nota"><b>Esta tabela subestima a contribuição das vendedoras e não deve ser usada como placar delas.</b>
A avaliação que elas geram é o que abre a porta para o upsell da biomédica — boa parte do alto ticket só existiu
porque uma vendedora colocou aquele paciente na cadeira.<br><br><b>Ressalva de método:</b> o Clínica Experts
não tem campo de vendedor na conta a receber. A venda promocional foi atribuída casando o paciente com a
vendedora que agendou a avaliação dele. É inferência, não dado nativo.</p></div>""" % (
        "".join('<th class="num">%s</th>' % c for c in col_rec), "".join(tr_rec)))

    if somente_secoes:
        # partes[0] e o cabecalho da pagina propria; fora dele sobram o alerta
        # e as secoes, que e o que entra no painel semanal.
        return CSS_EXTRA + "\n" + "\n".join(partes[1:])

    partes.append("""<footer>Gerado automaticamente &middot; Clínica Experts (São José + Joinville) &middot;
Série de %d semanas (sexta a quinta), %s a %s &middot; Meta semanal %s</footer></div></body></html>""" % (
        len(linhas), ini.strftime("%d/%m/%Y"), fim.strftime("%d/%m/%Y"), brl(META_SEMANAL)))

    return "\n".join(partes)


def injetar_no_painel(caminho_index, secoes):
    """
    Enxerta a analise no painel semanal, para tudo ficar num link so.
    O painel e regenerado a cada execucao pelo script antigo, entao esta
    injecao precisa acontecer depois dele — e roda de novo toda vez.
    """
    if not os.path.exists(caminho_index):
        return "index.html nao existe — nada a injetar"
    with open(caminho_index, encoding="utf-8") as fh:
        pagina = fh.read()

    marca = "<!--ANALISE-HISTORICA-->"
    if marca in pagina:
        return "index.html ja continha a analise (execucao repetida) — nada a fazer"

    bloco = "\n%s\n%s\n" % (marca, secoes)

    for ancora in ("  <footer>", "<footer>", "</body>"):
        if ancora in pagina:
            pagina = pagina.replace(ancora, bloco + ancora, 1)
            with open(caminho_index, "w", encoding="utf-8") as fh:
                fh.write(pagina)
            return "analise injetada no index.html antes de '%s'" % ancora.strip()
    return "AVISO: nao achei onde injetar no index.html — a analise ficou so na pagina propria"


# --------------------------------------------------------------------------
# selftest
# --------------------------------------------------------------------------

def selftest():
    falhas = []

    def checar(rotulo, obtido, esperado):
        if obtido != esperado:
            falhas.append("%s: obtido %r, esperado %r" % (rotulo, obtido, esperado))

    # normalizacao de vendedora — 'Janaina' NAO pode virar 'Ana'
    checar("Vendedora Ana", vendedora_de("Vendedora Ana - avaliação grátis"), "Ana")
    checar("Vendedor Janaina", vendedora_de("Vendedor Janaina"), "Janaína")
    checar("Ana Paula/euz", vendedora_de("Vendedora Ana Euzebio"), "Ana Paula")
    checar("Daiane maiuscula", vendedora_de("VENDEDORA DAIANE"), "Daiane")
    checar("Marilia", vendedora_de("vendedor Marilia"), "Marília")
    checar("vazio", vendedora_de(""), None)
    checar("sem nome", vendedora_de("PEGAR ASSINATURA"), None)

    # classificacao de produto
    checar("alto 1", eh_alto_ticket("Terapia Combinada 6 sessões + 3 consultas"), True)
    checar("alto 2", eh_alto_ticket("Protocolo Premium Combinado: 20 sessões"), True)
    checar("alto 3", eh_alto_ticket("Monoterapia Injetável – 9 sessões"), True)
    checar("promo 1", eh_alto_ticket("3 Sessões Microagulhamento (Promocional)"), False)
    checar("promo 2", eh_alto_ticket("Atendimento de Fulano"), False)

    # avaliacao vinda de pacote promocional conta como entrada
    checar("aval em pacote", eh_avaliacao(["Avaliação Gratuita Presencial", "Microagulhamento (promocional)"]), True)
    checar("aval online", eh_avaliacao(["Avaliação Gratuita Online"]), True)
    checar("sessao nao e aval", eh_avaliacao(["Sessão de Tratamento"]), False)

    # semanas sexta->quinta
    sexta = datetime.date(2026, 8, 14)
    # numa quinta, a semana corrente e a que comecou na sexta anterior
    checar("quinta", inicio_semana_corrente(datetime.date(2026, 8, 20)), sexta)
    checar("sabado", inicio_semana_corrente(datetime.date(2026, 8, 15)), sexta)
    checar("segunda", inicio_semana_corrente(datetime.date(2026, 8, 17)), sexta)
    # na SEXTA (dia da reuniao) a serie tem que terminar na semana ja fechada,
    # e nao abrir uma semana nova de um dia so
    checar("sexta usa semana fechada", inicio_semana_corrente(datetime.date(2026, 8, 21)), sexta)

    sems = montar_semanas(datetime.date(2026, 8, 20), 11)
    checar("qtd semanas", len(sems), 11)
    checar("primeira semana", sems[0][0], datetime.date(2026, 6, 5))
    checar("ultima semana", sems[-1], (datetime.date(2026, 8, 14), datetime.date(2026, 8, 20)))

    # rodando na sexta 21/08, a ultima semana continua sendo 14/08-20/08
    sems_sexta = montar_semanas(datetime.date(2026, 8, 21), 11)
    checar("sexta: ultima semana", sems_sexta[-1],
           (datetime.date(2026, 8, 14), datetime.date(2026, 8, 20)))
    checar("sexta: mesma janela da quinta", sems_sexta, sems)

    # agregacao ponta a ponta
    avals = [
        {"unidade": "São José", "status": "done", "criado": "2026-08-14", "data": "2026-08-17",
         "anotacao": "Vendedora Daiane", "paciente": "Fulano Silva"},
        {"unidade": "São José", "status": "canceled", "criado": "2026-08-14", "data": "2026-08-18",
         "anotacao": "Vendedora Brenda", "paciente": "Ciclano Souza"},
        {"unidade": "Joinville", "status": "done", "criado": "2026-08-18", "data": "2026-09-30",
         "anotacao": "Vendedora Daiane", "paciente": "Beltrano Lima"},
    ]
    vendas = [
        {"unidade": "São José", "data": "2026-08-17", "valor": 3000.0,
         "descricao": "Terapia Combinada 6 sessões", "paciente": "Fulano Silva"},
        {"unidade": "São José", "data": "2026-08-17", "valor": 900.0,
         "descricao": "3 Sessões Microagulhamento (Promocional)", "paciente": "Fulano Silva"},
    ]
    linhas = agregar(avals, vendas, montar_semanas(datetime.date(2026, 8, 20), 2))
    ult = linhas[-1]
    checar("criadas", ult["criadas"], 3)          # as 3 foram criadas na semana
    checar("agendadas", ult["agendadas"], 2)      # so 2 tem data na semana
    checar("realizadas", ult["realizadas"], 1)
    checar("canceladas", ult["canceladas"], 1)
    checar("alto_n", ult["alto_n"], 1)
    checar("alto_r", ult["alto_r"], 3000.0)
    checar("promo_r", ult["promo_r"], 900.0)
    checar("upsell", ult["upsell"], 100)
    checar("por_vend Daiane", ult["por_vend"].get("Daiane"), 2)
    checar("promo atribuida", ult["receita_vend"].get("Daiane"), 900.0)

    # formatacao
    checar("brl", brl(10473.92), "R$ 10.474")
    checar("brl milhar", brl(1234567), "R$ 1.234.567")
    checar("num", num(31.44), "31,4")

    # html gera sem quebrar e fecha as tags
    res = resumo(linhas, corte=1)
    pagina = montar_html(linhas, res, "20/08/2026")
    for tag in ("html", "body", "table", "tbody", "thead", "svg"):
        a = pagina.count("<%s" % tag)
        f = pagina.count("</%s>" % tag)
        if a != f:
            falhas.append("tag <%s> desbalanceada: %d aberturas, %d fechamentos" % (tag, a, f))

    if falhas:
        print("SELFTEST FALHOU (%d):" % len(falhas))
        for f in falhas:
            print("  -", f)
        return 1
    print("SELFTEST OK — todas as verificações passaram.")
    return 0


# --------------------------------------------------------------------------

def main():
    if "--selftest" in sys.argv:
        return selftest()

    caminho_cfg = os.path.join(BASE_DIR, "config", "clinica-experts-tokens.json")
    if not os.path.exists(caminho_cfg):
        print("ERRO: nao encontrei %s" % caminho_cfg)
        return 2
    with open(caminho_cfg, encoding="utf-8") as fh:
        cfg = json.load(fh)

    hoje = datetime.datetime.now().date()
    semanas = montar_semanas(hoje, N_SEMANAS)
    print("Janela: %s a %s (%d semanas)" % (iso(semanas[0][0]), iso(semanas[-1][1]), len(semanas)))

    unidades_cfg = list((cfg.get("clinics") or {}).keys())
    print("Unidades na config: %s" % (unidades_cfg or "NENHUMA — config invalida"))

    try:
        avaliacoes, vendas = coletar(cfg, semanas)
    except Exception as e:
        print("ERRO ao consultar a API: %s" % e)
        print("--- rastreamento completo ---")
        traceback.print_exc(file=sys.stdout)
        return 3

    print("Avaliacoes: %d | Vendas com valor: %d" % (len(avaliacoes), len(vendas)))
    if not avaliacoes:
        print("ERRO: nenhuma avaliacao retornada — nao vou gerar pagina vazia.")
        return 4

    linhas = agregar(avaliacoes, vendas, semanas)
    res = resumo(linhas)
    pagina = montar_html(linhas, res, hoje.strftime("%d/%m/%Y"))

    destino_dir = os.path.join(BASE_DIR, "site")
    os.makedirs(destino_dir, exist_ok=True)
    destino = os.path.join(destino_dir, "analise-historica.html")
    with open(destino, "w", encoding="utf-8") as fh:
        fh.write(pagina)
    print("Gerado: %s (%d bytes)" % (destino, len(pagina)))

    secoes = montar_html(linhas, res, hoje.strftime("%d/%m/%Y"), somente_secoes=True)
    print(injetar_no_painel(os.path.join(destino_dir, "index.html"), secoes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
