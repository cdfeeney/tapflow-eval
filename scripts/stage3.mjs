// Real Chrome on the Mac opens the dashboard's device view on localhost. Counts stream frames, taps
// through the canvas, and checks those taps against the app's own log.
import { chromium } from 'playwright-core'
import WebSocket from 'ws'
import { execSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs'

const OUT = process.env.OUT
mkdirSync(OUT, { recursive: true })
const log = (s) => { console.log(s); appendFileSync(`${OUT}/stream.txt`, s + '\n') }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const pct = (a, p) => [...a].sort((x, y) => x - y)[Math.floor((a.length - 1) * p)]
const events = () => {
  try {
    const box = execSync('xcrun simctl get_app_container tapflow-probe dev.probe.tapflow data', { timeout: 20000 }).toString().trim()
    return readFileSync(`${box}/Documents/events.log`, 'utf8').trim().split('\n').map((l) => l.split(' ').slice(1).join(' '))
  } catch (e) { return [`events-unreadable: ${e.message.slice(0, 80)}`] }
}

const listed = await new Promise((resolve, reject) => {
  const ws = new WebSocket('ws://localhost:4000')
  ws.on('open', () => ws.send(JSON.stringify({ type: 'agents:list' })))
  ws.on('message', (d, bin) => { if (bin) return; const m = JSON.parse(d.toString()); if (m.type === 'agents:listed') { ws.close(); resolve(m.sessions) } })
  ws.on('error', reject)
  setTimeout(() => reject(new Error('agents:list timed out')), 30000)
})
const device = listed.flatMap((a) => a.devices).find((d) => d.name === 'tapflow-probe')
log(`device: ${JSON.stringify(device)}`)

const browser = await chromium.launch({ channel: 'chrome', headless: true })
const context = await browser.newContext({ viewport: { width: 1400, height: 1100 } })
const page = await context.newPage()
const frames = []
page.on('websocket', (ws) => ws.on('framereceived', (f) => { if (typeof f.payload !== 'string') frames.push({ t: Date.now(), n: f.payload.length }) }))
page.on('console', (m) => { if (m.type() === 'error') appendFileSync(`${OUT}/console-errors.txt`, m.text().slice(0, 300) + '\n') })

const login = await page.request.post('http://localhost:4000/api/v1/auth/login', { data: { email: 'eval@example.com', password: process.env.ADMIN_PW } })
log(`login http=${login.status()}`)
const started = Date.now()
await page.goto(`http://localhost:4000/app-center/build?${new URLSearchParams({ id: '1', session: device.sessionId, device: device.id })}`)
await sleep(5000)
await page.screenshot({ path: `${OUT}/01-page-5s.png` })
await page.getByRole('button', { name: 'Start again' }).click({ timeout: 30000 }).catch((e) => log(`no restart button: ${e.message.slice(0, 80)}`))

let canvas = null
for (let i = 0; i < 200 && !canvas; i++) {
  for (const c of await page.locator('canvas').all()) {
    const b = await c.boundingBox().catch(() => null)
    if (b && b.width > 100 && b.height > 200) { canvas = b; break }
  }
  if (!canvas) await sleep(3000)
}
log(`canvas: ${JSON.stringify(canvas)} after ${Date.now() - started}ms; frames so far ${frames.length}`)
await page.screenshot({ path: `${OUT}/02-page-canvas.png` })
log(`first frame after ${frames.length ? frames[0].t - started : 'NONE'}ms`)
if (!canvas) { await browser.close(); process.exit(0) }
for (let i = 0; i < 100 && !frames.length; i++) await sleep(3000)
log(`first frame after ${frames.length ? frames[0].t - started : 'NONE'}ms`)
await sleep(30000) // install and launch finish behind the first frame
await page.screenshot({ path: `${OUT}/02b-page-settled.png` })

const rate = (from, to) => {
  const w = frames.filter((f) => f.t >= from && f.t < to)
  return `${(w.length / ((to - from) / 1000)).toFixed(1)}fps ${(w.reduce((s, f) => s + f.n, 0) / 1024 / ((to - from) / 1000)).toFixed(0)}KB/s (${w.length} frames)`
}
const at = (x, y) => [canvas.x + canvas.width * x, canvas.y + canvas.height * y]

let t = Date.now(); await sleep(15000); log(`idle: ${rate(t, Date.now())}`)

// Taps on Form Save, each timed to the next frame out of the stream.
const before = events().filter((e) => e === 'form-save').length
const lat = []
for (let i = 0; i < 12; i++) {
  await sleep(4000)
  const t0 = Date.now(), seen = frames.length
  await page.mouse.click(...at(0.2, 0.269))
  while (frames.length === seen && Date.now() - t0 < 4000) await sleep(5)
  lat.push(Date.now() - t0)
}
await sleep(2000)
const after = events().filter((e) => e === 'form-save').length
log(`taps sent=12 reached app=${after - before}; tap-to-next-frame p50=${pct(lat, 0.5)}ms p95=${pct(lat, 0.95)}ms all=${lat.join(',')}`)
await page.screenshot({ path: `${OUT}/03-after-taps.png` })

// Into the list, then keep it moving: this is what a person feels while scrolling.
await page.mouse.click(...at(0.2, 0.877))
await sleep(5000)
await page.screenshot({ path: `${OUT}/04-list.png` })
t = Date.now()
while (Date.now() - t < 30000) {
  await page.mouse.move(...at(0.5, 0.7)); await page.mouse.down()
  for (let i = 1; i <= 12; i++) { await page.mouse.move(...at(0.5, 0.7 - i * 0.04)); await sleep(25) }
  await page.mouse.up(); await sleep(400)
}
log(`scrolling: ${rate(t, Date.now())}`)
await page.screenshot({ path: `${OUT}/05-after-scroll.png` })
log(`events tail: ${events().slice(-5).join(',')}`)
writeFileSync(`${OUT}/frame-times.json`, JSON.stringify(frames))
await browser.close()
log('stream test finished')
