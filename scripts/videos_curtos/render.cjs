// Renderiza os vídeos curtos (1080x1920, 30 fps, H.264) a partir de cenas.html.
// Uso:  node render.cjs "<pasta de saída>" [id ...]        (sem ids: todos)
// Requer: puppeteer-core (PUPPETEER_DIR aponta para node_modules/puppeteer-core se não estiver instalado aqui),
//         ffmpeg (FFMPEG = caminho do executável) e Microsoft Edge ou Chrome (NAVEGADOR = caminho do executável).
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const puppeteer = require(process.env.PUPPETEER_DIR || 'puppeteer-core');

const FPS = 30;
const NAVEGADOR = process.env.NAVEGADOR || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const FFMPEG = process.env.FFMPEG || 'ffmpeg';
const ORDEM = ['home', 'dashboard', 'clipping', 'relatorios', 'banco', 'pesquisas', 'whatsapp', 'campanhas', 'usuarios', 'inadimplencia', 'estoque'];
const NOMES = { home: 'home', dashboard: 'dashboard', clipping: 'clipping_news', relatorios: 'relatorios', banco: 'banco_de_dados', pesquisas: 'pesquisas',
  whatsapp: 'whatsapp', campanhas: 'campanhas', usuarios: 'usuarios', inadimplencia: 'inadimplencia', estoque: 'controle_de_estoque' };

(async () => {
  const saida = path.resolve(process.argv[2] || '.');
  const ids = process.argv.length > 3 ? process.argv.slice(3) : ORDEM;
  fs.mkdirSync(saida, { recursive: true });
  const nav = await puppeteer.launch({ executablePath: NAVEGADOR, headless: true, args: ['--hide-scrollbars', '--force-color-profile=srgb'] });
  const pag = await nav.newPage();
  await pag.setViewport({ width: 1080, height: 1920, deviceScaleFactor: 1 });
  const url = 'file:///' + path.join(__dirname, 'cenas.html').replace(/\\/g, '/');
  for (const id of ids) {
    await pag.goto(`${url}?v=${id}`, { waitUntil: 'networkidle0' });
    await pag.evaluate(() => document.fonts.ready);
    const dur = await pag.evaluate(() => window.DURACAO);
    const n = Math.round(dur * FPS);
    const arq = path.join(saida, `dataload_${String(ORDEM.indexOf(id) + 1).padStart(2, '0')}_${NOMES[id]}.mp4`);
    const ff = spawn(FFMPEG, ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-r', String(FPS), arq], { stdio: ['pipe', 'inherit', 'inherit'] });
    const t0 = Date.now();
    for (let i = 0; i < n; i++) {
      await pag.evaluate(t => window.renderFrame(t), i / FPS);
      const img = await pag.screenshot({ type: 'jpeg', quality: 93, optimizeForSpeed: true });
      if (!ff.stdin.write(img)) await new Promise(r => ff.stdin.once('drain', r));
    }
    ff.stdin.end();
    await new Promise((r, j) => ff.on('close', c => c ? j(new Error('ffmpeg ' + c)) : r()));
    console.log(`${path.basename(arq)}  ${dur.toFixed(1)} s  ${n} quadros  ${((Date.now() - t0) / 1000).toFixed(0)} s de render`);
  }
  await nav.close();
})().catch(e => { console.error(e); process.exit(1); });
