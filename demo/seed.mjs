// Fill a fresh demo Documenso (demo/up.sh) with an invented world for screenshots.
//
//   node demo/seed.mjs            (the stack must be running and empty; `demo/up.sh down` then `up` resets it)
//
// Everything here is invented: people and companies are fictional, addresses are on example.org, and the
// only thing it talks to is the throwaway stack on 127.0.0.1. See demo/README.md for the cast.
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const APP = process.env.DEMO_APP_URL ?? 'http://127.0.0.1:3190';
const MAIL = process.env.DEMO_MAIL_URL ?? 'http://127.0.0.1:8125';
const PASSWORD = 'Harbor-Light-2026!';

if (!/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(APP)) {
  throw new Error(`Refusing to seed ${APP}: the demo seed only runs against a local stack.`);
}

const CAST = {
  maya: { name: 'Maya Okafor', email: 'maya@example.org' },
  tomas: { name: 'Tomas Reyes', email: 'tomas@example.org' },
  priya: { name: 'Priya Nandakumar', email: 'priya@example.org' },
  jonas: { name: 'Jonas Albrecht', email: 'jonas@example.org' },
  lena: { name: 'Lena Moreau', email: 'lena@example.org' },
};

// Signup is limited to 3 per 3 hours per address. The demo database is throwaway, so clear the counter
// instead of waiting. This only ever touches the demo stack's own database container.
function resetSignupLimit() {
  execFileSync('docker', ['exec', process.env.DEMO_DB_CONTAINER ?? 'documenso-demo-database-1', 'psql', '-U', 'demo', '-d', 'demo', '-c', 'DELETE FROM "RateLimit"'], {
    stdio: 'ignore',
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Client {
  constructor() {
    this.jar = new Map();
  }
  cookie() {
    return [...this.jar].map(([k, v]) => `${k}=${v}`).join('; ');
  }
  async req(path, { method = 'GET', json, form, headers = {} } = {}) {
    const h = { origin: APP, cookie: this.cookie(), ...headers };
    let body;
    if (json !== undefined) {
      h['content-type'] = 'application/json';
      body = JSON.stringify(json);
    } else if (form) {
      body = form;
    }
    const res = await fetch(APP + path, { method, headers: h, body, redirect: 'manual' });
    for (const c of res.headers.getSetCookie()) {
      const [kv] = c.split(';');
      const i = kv.indexOf('=');
      this.jar.set(kv.slice(0, i), kv.slice(i + 1));
    }
    const text = await res.text();
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    return { status: res.status, data };
  }
  // tRPC procedures take and return superjson envelopes; plain objects pass straight through.
  async trpc(path, input, { query = false } = {}) {
    const res = query
      ? await this.req(`/api/trpc/${path}${input ? `?input=${encodeURIComponent(JSON.stringify({ json: input }))}` : ''}`)
      : await this.req(`/api/trpc/${path}`, { method: 'POST', json: { json: input } });
    if (res.status >= 400) throw new Error(`${path} failed: ${res.status} ${JSON.stringify(res.data).slice(0, 300)}`);
    return res.data?.result?.data?.json ?? res.data;
  }
}

async function verificationToken(email) {
  for (let i = 0; i < 40; i++) {
    const list = await (await fetch(`${MAIL}/api/v1/messages`)).json();
    for (const m of list.messages ?? []) {
      if (m.To?.[0]?.Address !== email || !/confirm/i.test(m.Subject)) continue;
      const full = await (await fetch(`${MAIL}/api/v1/message/${m.ID}`)).json();
      const hit = full.Text.match(/verify-email\/([a-f0-9]+)/);
      if (hit) return hit[1];
    }
    await sleep(1500);
  }
  throw new Error(`No confirmation email for ${email}`);
}

async function signIn(client, email) {
  const { data } = await client.req('/api/auth/csrf');
  return client.req('/api/auth/email-password/authorize', {
    method: 'POST',
    json: { email, password: PASSWORD, csrfToken: data.csrfToken },
  });
}

async function createUser({ name, email }) {
  const client = new Client();
  resetSignupLimit();
  const signup = await client.req('/api/auth/email-password/signup', { method: 'POST', json: { name, email, password: PASSWORD } });
  if (signup.status >= 400) console.log(`  ${email}: signup said ${signup.status}, trying to sign in`);
  let res = await signIn(client, email);
  if (res.status >= 400) {
    const token = await verificationToken(email);
    await client.req('/api/auth/email-password/verify-email', { method: 'POST', json: { token } });
    res = await signIn(client, email);
  }
  if (res.status >= 400) throw new Error(`Cannot sign in as ${email}: ${res.status}`);
  const orgs = await client.trpc('organisation.internal.getOrganisationSession', undefined, { query: true });
  client.team = orgs[0].teams[0];
  const tok = await client.trpc('apiToken.create', { teamId: client.team.id, tokenName: 'demo-seed', expirationDate: null });
  client.apiToken = tok.token;
  return client;
}

// A one-page PDF with plain text, so the seed needs no files and no libraries.
function pdf(title, lines) {
  const esc = (s) => s.replace(/[\\()]/g, '\\$&');
  let content = `BT /F1 22 Tf 72 720 Td (${esc(title)}) Tj ET\n`;
  lines.forEach((l, i) => {
    content += `BT /F1 12 Tf 72 ${680 - i * 20} Td (${esc(l)}) Tj ET\n`;
  });
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${content.length} >>\nstream\n${content}endstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  let out = '%PDF-1.4\n';
  const offsets = [];
  objs.forEach((o, i) => {
    offsets.push(out.length);
    out += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  offsets.forEach((o) => {
    out += `${String(o).padStart(10, '0')} 00000 n \n`;
  });
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}

async function createEnvelope(sender, { title, lines, recipients }) {
  const payload = {
    title,
    type: 'DOCUMENT',
    recipients: recipients.map((r, i) => ({
      name: r.name,
      email: r.email,
      role: 'SIGNER',
      signingOrder: i + 1,
      fields: [
        { type: 'SIGNATURE', identifier: 0, page: 1, positionX: 10, positionY: 70, width: 35, height: 7 },
        { type: 'DATE', identifier: 0, page: 1, positionX: 55, positionY: 70, width: 25, height: 4 },
      ],
    })),
  };
  const form = new FormData();
  form.append('payload', JSON.stringify(payload));
  form.append('files', new Blob([pdf(title, lines)], { type: 'application/pdf' }), `${title}.pdf`);
  const res = await sender.req('/api/v2/envelope/create', { method: 'POST', form, headers: { authorization: sender.apiToken } });
  if (res.status >= 400) throw new Error(`create ${title}: ${res.status} ${JSON.stringify(res.data).slice(0, 400)}`);
  return res.data.id;
}

async function api(sender, path, init = {}) {
  const res = await sender.req(`/api/v2${path}`, { ...init, headers: { authorization: sender.apiToken, ...(init.headers ?? {}) } });
  if (res.status >= 400) throw new Error(`${path}: ${res.status} ${JSON.stringify(res.data).slice(0, 400)}`);
  return res.data;
}

// The container reports healthy before the web server answers, so wait for a real page.
async function waitForApp() {
  for (let i = 0; i < 90; i++) {
    try {
      if ((await fetch(`${APP}/signin`)).ok) return;
    } catch {}
    await sleep(2000);
  }
  throw new Error(`${APP} did not answer`);
}

async function main() {
  await waitForApp();
  console.log('Creating people');
  const people = {};
  for (const key of ['maya', 'tomas', 'priya']) {
    people[key] = await createUser(CAST[key]);
    console.log(`  ${CAST[key].email} (team ${people[key].team.id})`);
  }
  const maya = people.maya;

  console.log('Creating documents');
  const completedId = await createEnvelope(maya, {
    title: 'Studio Services Agreement',
    lines: ['Harbor Light Studio and Brightwell Dental agree to the services described here.', 'This is a sample document with invented parties.'],
    recipients: [CAST.priya],
  });
  const pendingId = await createEnvelope(maya, {
    title: 'Photography Release',
    lines: ['Albrecht Bakery grants Harbor Light Studio permission to photograph its shop.', 'This is a sample document with invented parties.'],
    recipients: [CAST.jonas],
  });
  await createEnvelope(maya, {
    title: 'Statement of Work Q1',
    lines: ['Moreau Florals engages Harbor Light Studio for the first quarter.', 'This is a sample document with invented parties.'],
    recipients: [CAST.lena],
  });

  console.log('Sending two of them');
  await api(maya, '/envelope/distribute', { method: 'POST', json: { envelopeId: completedId } });
  await api(maya, '/envelope/distribute', { method: 'POST', json: { envelopeId: pendingId } });

  console.log('Signing the first as Priya');
  const env = await api(maya, `/envelope/${completedId}`);
  const recipient = env.recipients.find((r) => r.email === CAST.priya.email);
  const anon = new Client();
  for (const f of env.fields.filter((x) => x.recipientId === recipient.id)) {
    const value = f.type === 'SIGNATURE' ? CAST.priya.name : '';
    await anon.trpc('field.signFieldWithToken', { token: recipient.token, fieldId: f.id, value, isBase64: false });
  }
  await anon.trpc('recipient.completeDocumentWithToken', { token: recipient.token, documentId: Number(String(env.secondaryId).replace(/\D/g, '')) });

  writeFileSync(new URL('./seed-result.json', import.meta.url), JSON.stringify({ completedId, pendingId, password: PASSWORD }, null, 2));
  console.log('Done. Sign in at', APP, 'as maya@example.org with the demo password in demo/seed.mjs.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
