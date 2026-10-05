"""
Gera os 3 modelos de página do Panorama Econômico (2480 x 3508 px, A4 a 300 dpi):

  capa.png             capa com título e composição geométrica
  fundo-dados.png      plano de fundo para dados (foto em duotone azul)
  pagina-conteudo.png  página de conteúdo (cabeçalho tecnológico + logos)

Uso:  python gerar.py   (requer Pillow e Playwright com o Chrome instalado)
Os textos da capa ficam em capa.html; edite e rode de novo.
"""
import base64, math, pathlib, random
from PIL import Image, ImageEnhance, ImageFilter
from playwright.sync_api import sync_playwright

AQUI = pathlib.Path(__file__).resolve().parent
SAIDA = AQUI.parent
W, H = 2480, 3508

AZUL_ESC, AZUL, AZUL_CLARO = '#0B3C8C', '#0050A2', '#1F73D1'
VERDE, VERDE_CLARO, AMARELO = '#00A651', '#5DBB46', '#FFCB05'

FONTE = '<link href="https://fonts.googleapis.com/css2?family=Raleway:wght@400;500;600;700;800&display=block" rel="stylesheet">'
BASE_CSS = f'html,body{{margin:0;width:{W}px;height:{H}px;overflow:hidden;background:#fff;font-family:Raleway,sans-serif;}}'


# ---------------------------------------------------------------- capa
def composicao_geometrica():
    """Mosaico de quadrados, quartos de círculo e triângulos (canto inferior direito)
    com feixe de linhas finas em onda, como no modelo."""
    rnd = random.Random(23)
    cel, c0, r0 = 300, W - 300 * 5, H - 300 * 6
    # ocupação em escada: linha -> colunas preenchidas (0 = esquerda)
    ocup = {0: [4], 1: [3, 4], 2: [3, 4], 3: [2, 3, 4], 4: [1, 2, 3, 4], 5: [0, 1, 2, 3, 4]}
    fundos = [AZUL_ESC, AZUL, AZUL, AZUL_CLARO, VERDE, VERDE_CLARO, AMARELO, AMARELO, '#fff', '#fff']
    formas = ['quarto', 'quarto', 'quarto', 'triangulo', 'triangulo', 'meio', 'vazio']
    out = []

    # feixe de ondas (atrás do mosaico)
    for feixe, (cor, base) in enumerate([(AZUL, 0), (VERDE, 1)]):
        for i in range(14):
            k = i + feixe * 16
            x0, y1 = 380 + k * 30, 2250 + k * 30
            out.append(f'<path d="M{x0},{H} C{x0 + 300},{H - 700 - k * 4} {1350 + k * 8},{y1 + 240} {W},{y1}" '
                       f'fill="none" stroke="{cor}" stroke-width="4.5" opacity="{0.45 + (i % 3) * 0.2:.2f}"/>')

    anterior = None
    for r, cols in ocup.items():
        for c in cols:
            x, y = c0 + c * cel, r0 + r * cel
            fundo = rnd.choice([f for f in fundos if f != anterior])
            anterior = fundo
            forma = rnd.choice(formas)
            cor = rnd.choice([f for f in fundos if f not in (fundo, '#fff')])
            if fundo != '#fff':
                out.append(f'<rect x="{x}" y="{y}" width="{cel}" height="{cel}" fill="{fundo}"/>')
            canto = rnd.randrange(4)
            cx, cy = x + (cel if canto in (1, 2) else 0), y + (cel if canto >= 2 else 0)
            if forma == 'quarto':
                sx, sy = (1 if canto in (0, 3) else -1), (1 if canto in (0, 1) else -1)
                out.append(f'<path d="M{cx},{cy} L{cx + sx * cel},{cy} A{cel},{cel} 0 0 {1 if sx * sy > 0 else 0} {cx},{cy + sy * cel} Z" fill="{cor}"/>')
            elif forma == 'triangulo':
                pts = [(x, y), (x + cel, y), (x + cel, y + cel), (x, y + cel)]
                del pts[canto]
                out.append('<polygon points="' + ' '.join(f'{a},{b}' for a, b in pts) + f'" fill="{cor}"/>')
            elif forma == 'meio':
                out.append(f'<path d="M{x},{y + cel} A{cel / 2},{cel / 2} 0 0 1 {x + cel},{y + cel} Z" fill="{cor}"/>')
            elif forma == 'quadrado':
                m = cel * 0.25
                out.append(f'<rect x="{x + m}" y="{y + m}" width="{cel - 2 * m}" height="{cel - 2 * m}" fill="{cor}"/>')
            elif forma == 'circulo':
                out.append(f'<circle cx="{x + cel / 2}" cy="{y + cel / 2}" r="{cel * 0.38}" fill="{cor}"/>')
    # peças soltas acima da escada (como os quadrados destacados do modelo)
    out.append(f'<rect x="{c0 + 2 * cel + 90}" y="{r0 + 1 * cel + 90}" width="{cel * 0.4}" height="{cel * 0.4}" fill="{VERDE}"/>')
    out.append(f'<rect x="{c0 + 1 * cel + 150}" y="{r0 + 3 * cel + 150}" width="{cel * 0.5}" height="{cel * 0.5}" fill="{AZUL}"/>')
    return f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" style="position:absolute;inset:0">{"".join(out)}</svg>'


def html_capa():
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>Capa · Panorama Econômico</title>{FONTE}<style>{BASE_CSS}
  .titulos{{position:absolute;left:0;right:0;top:980px;text-align:center;color:#1F2937;}}
  h1{{margin:0;font-size:178px;font-weight:700;letter-spacing:1px;white-space:nowrap;color:{AZUL_ESC};}}
  .sub{{margin-top:40px;font-size:112px;font-weight:500;line-height:1.22;}}
  .data{{margin-top:70px;font-size:92px;font-weight:600;}}
</style></head><body>
  {composicao_geometrica()}
  <div class="titulos">
    <h1>PANORAMA ECONÔMICO</h1>
    <div class="sub">relatório quinzenal com os principais<br>movimentos do varejo.</div>
    <div class="data">Outubro / 2026</div>
  </div>
</body></html>'''


# ---------------------------------------------------------------- página de conteúdo
def circuito(largura, altura):
    """Trilhas de placa de circuito em ciano, mais densas e brilhantes no centro."""
    rnd = random.Random(11)
    linhas, nos = [], []
    for _ in range(95):
        x = rnd.randrange(-100, largura, 20)
        y = rnd.randrange(30, altura - 30, 20)
        centro = 1 - abs((x + 300) / largura - 0.45) * 1.5
        op = max(0.15, min(1, centro + rnd.uniform(-0.2, 0.25)))
        d = f'M{x},{y}'
        for _ in range(rnd.randint(1, 3)):
            x += rnd.randrange(80, 420, 20)
            d += f' L{x},{y}'
            if rnd.random() < 0.7:
                dy = rnd.choice([-1, 1]) * rnd.randrange(40, 140, 20)
                if 20 < y + dy < altura - 20:
                    x += abs(dy); y += dy
                    d += f' L{x},{y}'
        larg = rnd.choice([2.5, 3, 4, 5])
        linhas.append(f'<path d="{d}" stroke-width="{larg}" opacity="{op:.2f}"/>')
        nos.append(f'<circle cx="{x}" cy="{y}" r="{rnd.choice([7, 9, 11])}" stroke-width="{larg}" opacity="{op:.2f}"/>')
    pontos = ''.join(f'<circle cx="{rnd.randrange(largura)}" cy="{rnd.randrange(altura)}" r="{rnd.choice([3, 4, 5])}" opacity="{rnd.uniform(.2, .8):.2f}"/>' for _ in range(70))
    return f'''<svg width="{largura}" height="{altura}" viewBox="0 0 {largura} {altura}" style="position:absolute;inset:0">
  <defs>
    <radialGradient id="luz" cx="45%" cy="50%" r="60%"><stop offset="0" stop-color="#1D6FD8" stop-opacity=".85"/><stop offset="1" stop-color="#1D6FD8" stop-opacity="0"/></radialGradient>
    <filter id="brilho" x="-20%" y="-50%" width="140%" height="200%"><feGaussianBlur stdDeviation="6" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  </defs>
  <rect width="{largura}" height="{altura}" fill="url(#luz)"/>
  <g fill="none" stroke="#5CC8FF" stroke-linecap="round" stroke-linejoin="round" filter="url(#brilho)">{"".join(linhas)}{"".join(nos)}</g>
  <g fill="#8FDBFF" filter="url(#brilho)">{pontos}</g>
</svg>'''


def html_conteudo(logo_b64):
    social = {
        'instagram': '<rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4"/><circle cx="17.5" cy="6.5" r="1" fill="#fff" stroke="none"/>',
        'facebook': '<path d="M14 8h3V4h-3a4 4 0 0 0-4 4v3H7v4h3v6h4v-6h3l1-4h-4V8z"/>',
        'linkedin': '<path d="M4 9h4v11H4zM6 3.5a2 2 0 1 1 0 4 2 2 0 0 1 0-4zM10 9h4v1.6c.6-1 2-1.9 3.6-1.9 3 0 3.4 2 3.4 4.6V20h-4v-5.8c0-1.3 0-2.9-1.8-2.9S13 12.7 13 14.1V20h-3z"/>',
        'youtube': '<rect x="2.5" y="5.5" width="19" height="13" rx="4"/><path d="M10 9v6l5-3z" fill="#fff" stroke="none"/>',
        'site': '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    }
    icones = ''.join(f'<span class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{v}</svg></span>' for v in social.values())
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>Página de conteúdo · Panorama Econômico</title>{FONTE}<style>{BASE_CSS}
  .topo{{position:absolute;left:0;top:0;width:{W}px;height:520px;overflow:hidden;background:linear-gradient(100deg,#041A47 0%,#0A2F78 45%,#0B3C8C 70%,#062463 100%);}}
  .aba{{position:absolute;right:0;top:0;width:900px;height:520px;}}
  .logo{{position:absolute;right:150px;top:205px;width:560px;}}
  .faixa{{position:absolute;left:0;top:520px;width:{W}px;height:18px;background:linear-gradient(90deg,{AZUL_ESC} 0%,{AZUL} 60%,{VERDE} 82%,{AMARELO} 100%);}}
  .regua{{position:absolute;left:180px;right:180px;top:880px;height:16px;border-radius:8px;background:linear-gradient(90deg,{AZUL_ESC} 0%,{AZUL} 55%,{VERDE} 80%,{AMARELO} 100%);}}
  .rodape{{position:absolute;right:0;bottom:0;width:1180px;height:300px;background:#EEF1F5;}}
  .rodape::before{{content:'';position:absolute;left:0;right:0;top:0;height:14px;background:linear-gradient(90deg,{AZUL_ESC},{AZUL} 50%,{VERDE} 80%,{AMARELO});}}
  .icones{{position:absolute;right:180px;bottom:100px;display:flex;gap:28px;}}
  .ic{{width:92px;height:92px;border-radius:50%;background:{AZUL_ESC};display:flex;align-items:center;justify-content:center;}}
  .ic svg{{width:50px;height:50px;}}
</style></head><body>
  <div class="topo">{circuito(W, 520)}</div>
  <svg class="aba" viewBox="0 0 900 520">
    <path d="M220,0 H900 V520 H150 Q60,520 88,434 Z" fill="#fff"/>
    <path d="M150,508 Q72,508 96,436 L238,0" fill="none" stroke="url(#borda)" stroke-width="16"/>
    <defs><linearGradient id="borda" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="{AMARELO}"/><stop offset=".5" stop-color="{VERDE}"/><stop offset="1" stop-color="{AZUL}"/></linearGradient></defs>
  </svg>
  <img class="logo" src="data:image/png;base64,{logo_b64}" alt="NIM | CDL Cuiabá">
  <div class="faixa"></div>
  <div class="regua"></div>
  <div class="rodape"><div class="icones">{icones}</div></div>
</body></html>'''


# ---------------------------------------------------------------- fundo para dados (duotone)
def fundo_dados():
    foto = Image.open(AQUI / 'foto-supermercado.jpg').convert('L')
    fw, fh = foto.size
    alvo = W / H
    cw = int(fh * alvo)
    x0 = int((fw - cw) * 0.5)
    foto = foto.crop((x0, 0, x0 + cw, fh)).resize((W, H), Image.LANCZOS)
    foto = ImageEnhance.Contrast(foto).enhance(1.15)
    escuro, claro = (3, 16, 46), (92, 132, 196)
    lut = [tuple(int(escuro[k] + (claro[k] - escuro[k]) * (i / 255) ** 1.35) for k in range(3)) for i in range(256)]
    rgb = Image.merge('RGB', [foto.point([c[k] for c in lut]) for k in range(3)])
    # vinheta suave para os dados respirarem no centro
    vinheta = Image.radial_gradient('L').resize((W, H)).filter(ImageFilter.GaussianBlur(60))
    sombra = Image.new('RGB', (W, H), (3, 16, 44))
    rgb = Image.composite(sombra, rgb, vinheta.point(lambda v: int(v * 0.55)))
    rgb.save(SAIDA / 'fundo-dados.png', optimize=True)


def main():
    logo_b64 = base64.b64encode((AQUI / 'logo-nim-cdl.png').read_bytes()).decode()
    (AQUI / 'capa.html').write_text(html_capa(), encoding='utf-8')
    (AQUI / 'pagina-conteudo.html').write_text(html_conteudo(logo_b64), encoding='utf-8')
    with sync_playwright() as p:
        nav = p.chromium.launch(channel='chrome')
        pg = nav.new_page(viewport={'width': W, 'height': H})
        for nome in ['capa', 'pagina-conteudo']:
            pg.goto((AQUI / f'{nome}.html').as_uri())
            pg.evaluate('document.fonts.ready')
            pg.wait_for_timeout(800)
            pg.screenshot(path=str(SAIDA / f'{nome}.png'), full_page=False)
        nav.close()
    fundo_dados()
    print('ok')


if __name__ == '__main__':
    main()
