#!/usr/bin/env node
import { createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { open, mkdir, readFile, unlink } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const host = process.env.COORDKIT_RELAY_HOST || "127.0.0.1";
const port = numberEnv("COORDKIT_RELAY_PORT", 8787, 1, 65535);
const dataDir = resolve(process.env.COORDKIT_RELAY_DATA || "./data");
const maxBody = numberEnv("COORDKIT_RELAY_MAX_BODY", 1_048_576, 1024, 16_777_216);
const maxEvents = numberEnv("COORDKIT_RELAY_MAX_EVENTS", 500, 1, 5000);
const insecure = process.env.COORDKIT_RELAY_INSECURE === "1";
const grants = loadGrants();
const rooms = new Map();
const roomLoads = new Map();
let lockHandle;
let shuttingDown = false;

function numberEnv(name, fallback, min, max) {
  const value = Number.parseInt(process.env[name] || "", 10);
  return Number.isInteger(value) && value >= min && value <= max ? value : fallback;
}

function loadGrants() {
  const result = new Map();
  const single = process.env.COORDKIT_RELAY_TOKEN;
  if (single) result.set(single, new Set(["*"]));
  const raw = process.env.COORDKIT_RELAY_TOKENS;
  if (raw) {
    let parsed;
    try { parsed = JSON.parse(raw); } catch { throw new Error("COORDKIT_RELAY_TOKENS must be valid JSON"); }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("COORDKIT_RELAY_TOKENS must map bearer tokens to room arrays");
    }
    for (const [token, allowed] of Object.entries(parsed)) {
      if (!token || !Array.isArray(allowed) || allowed.some((room) => typeof room !== "string")) {
        throw new Error("Each relay token grant must be a non-empty token mapped to string rooms");
      }
      result.set(token, new Set(allowed));
    }
  }
  if (result.size === 0 && !insecure) {
    throw new Error("Set COORDKIT_RELAY_TOKEN or COORDKIT_RELAY_TOKENS; use COORDKIT_RELAY_INSECURE=1 only for local development");
  }
  return result;
}

function safeEqual(a, b) {
  const left = Buffer.from(a); const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

function authorized(req, room) {
  if (insecure && grants.size === 0) return true;
  const header = req.headers.authorization || "";
  if (!header.startsWith("Bearer ")) return false;
  const supplied = header.slice(7);
  for (const [token, allowed] of grants) {
    if (safeEqual(supplied, token) && (allowed.has("*") || allowed.has(room))) return true;
  }
  return false;
}

function roomFrom(req) {
  const value = req.headers["x-coord-room"];
  return typeof value === "string" && value.length > 0 && value.length <= 200 && !/[\r\n]/.test(value) ? value : null;
}

function roomFile(room) {
  const key = createHash("sha256").update(room).digest("hex");
  return join(dataDir, "rooms", `${key}.ndjson`);
}

function canonicalEventContent(value) {
  if (Array.isArray(value)) return value.map(canonicalEventContent);
  if (!value || typeof value !== "object") return value;
  const sorted = {};
  for (const key of Object.keys(value).filter((key) => key !== "eid" && key !== "sig").sort()) {
    sorted[key] = canonicalEventContent(value[key]);
  }
  return sorted;
}

function eidContent(event) {
  return JSON.stringify(canonicalEventContent(event));
}

async function loadRoomState(room) {
  const state = { room, cursor: 0, records: [], eids: new Map(), queue: Promise.resolve(), waiters: new Set() };
  const file = roomFile(room);
  try {
    const raw = await readFile(file, "utf8");
    for (const line of raw.split("\n")) {
      if (!line) continue;
      try {
        const record = JSON.parse(line);
        if (!Number.isInteger(record.cursor) || record.cursor <= 0 || !record.event || typeof record.event !== "object") continue;
        state.records.push(record); state.cursor = Math.max(state.cursor, record.cursor);
        if (typeof record.event.eid === "string") {
          state.eids.set(record.event.eid, { cursor: record.cursor, content: eidContent(record.event) });
        }
      } catch { /* tolerate a torn trailing record; it is never served */ }
    }
    state.records.sort((a, b) => a.cursor - b.cursor);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return state;
}

function roomState(room) {
  if (rooms.has(room)) return Promise.resolve(rooms.get(room));
  if (!roomLoads.has(room)) {
    const pending = loadRoomState(room)
      .then((state) => {
        rooms.set(room, state);
        return state;
      })
      .finally(() => roomLoads.delete(room));
    roomLoads.set(room, pending);
  }
  return roomLoads.get(room);
}

function enqueue(state, operation) {
  const next = state.queue.then(operation, operation);
  state.queue = next.catch(() => {});
  return next;
}

async function appendEvent(state, event) {
  return enqueue(state, async () => {
    const prior = state.eids.get(event.eid);
    const content = eidContent(event);
    if (prior) {
      if (prior.content !== content) {
        throw Object.assign(new Error("eid already exists with different event content"), { status: 409 });
      }
      return { cursor: prior.cursor, duplicate: true };
    }
    const record = { cursor: state.cursor + 1, event };
    const file = roomFile(state.room);
    await mkdir(dirname(file), { recursive: true });
    const handle = await open(file, "a", 0o600);
    try { await handle.write(`${JSON.stringify(record)}\n`); await handle.sync(); }
    finally { await handle.close(); }
    state.cursor = record.cursor; state.records.push(record);
    state.eids.set(event.eid, { cursor: record.cursor, content });
    for (const wake of state.waiters) wake();
    state.waiters.clear();
    return { cursor: record.cursor, duplicate: false };
  });
}

async function readBody(req) {
  const chunks = []; let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBody) { const error = new Error("request body too large"); error.status = 413; throw error; }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseEvents(body) {
  const lines = body.split("\n").filter(Boolean);
  if (lines.length === 0) throw Object.assign(new Error("empty event body"), { status: 400 });
  if (lines.length > maxEvents) throw Object.assign(new Error("too many events"), { status: 413 });
  return lines.map((line) => {
    let event;
    try { event = JSON.parse(line); } catch { throw Object.assign(new Error("invalid NDJSON event"), { status: 400 }); }
    if (!event || typeof event !== "object" || Array.isArray(event) || typeof event.eid !== "string" || event.eid.length === 0) {
      throw Object.assign(new Error("each event must be an object with a non-empty eid"), { status: 422 });
    }
    return event;
  });
}

function sendJson(res, status, body) {
  const payload = `${JSON.stringify(body)}\n`;
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(payload), "cache-control": "no-store" });
  res.end(payload);
}

async function waitForEvent(state, milliseconds) {
  if (milliseconds <= 0) return;
  await new Promise((resolveWait) => {
    const timer = setTimeout(() => { state.waiters.delete(wake); resolveWait(); }, milliseconds);
    const wake = () => { clearTimeout(timer); resolveWait(); };
    state.waiters.add(wake);
  });
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  if (url.pathname === "/healthz" && req.method === "GET") return sendJson(res, 200, { ok: true });
  if (url.pathname !== "/v1/events") return sendJson(res, 404, { error: "not found" });
  const room = roomFrom(req);
  if (!room) return sendJson(res, 400, { error: "X-Coord-Room is required" });
  if (!authorized(req, room)) return sendJson(res, 401, { error: "unauthorized" });
  const state = await roomState(room);

  if (req.method === "POST") {
    const events = parseEvents(await readBody(req));
    let accepted = 0; let duplicates = 0; let cursor = state.cursor;
    for (const event of events) {
      const result = await appendEvent(state, event); cursor = Math.max(cursor, result.cursor);
      if (result.duplicate) duplicates += 1; else accepted += 1;
    }
    return sendJson(res, 202, { accepted, duplicates, cursor });
  }

  if (req.method === "GET") {
    const since = Math.max(0, Number.parseInt(url.searchParams.get("since") || "0", 10) || 0);
    const limit = Math.min(1000, Math.max(1, Number.parseInt(url.searchParams.get("limit") || "200", 10) || 200));
    const wait = Math.min(25_000, Math.max(0, Number.parseInt(url.searchParams.get("wait") || "0", 10) || 0));
    if (state.cursor <= since && wait > 0) await waitForEvent(state, wait);
    const records = state.records.filter((record) => record.cursor > since).slice(0, limit);
    const cursor = records.length ? records.at(-1).cursor : since;
    const more = state.cursor > cursor;
    const payload = records.map((record) => JSON.stringify(record.event)).join("\n") + (records.length ? "\n" : "");
    res.writeHead(200, {
      "content-type": "application/x-ndjson",
      "content-length": Buffer.byteLength(payload),
      "cache-control": "no-store",
      "x-coord-cursor": String(cursor),
      "x-coord-latest": String(state.cursor),
      "x-coord-more": more ? "1" : "0"
    });
    return res.end(payload);
  }

  return sendJson(res, 405, { error: "method not allowed" });
}

async function acquireProcessLock() {
  await mkdir(dataDir, { recursive: true });
  const file = join(dataDir, "server.lock");
  try {
    lockHandle = await open(file, "wx", 0o600);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    let stale = false;
    try {
      const pid = Number.parseInt(await readFile(file, "utf8"), 10);
      if (!Number.isInteger(pid)) stale = true;
      else { try { process.kill(pid, 0); } catch { stale = true; } }
    } catch { stale = true; }
    if (!stale) throw new Error(`another coordkit relay owns ${file}`);
    await unlink(file).catch(() => {});
    lockHandle = await open(file, "wx", 0o600);
  }
  await lockHandle.write(`${process.pid}\n`); await lockHandle.sync();
  return file;
}

const lockFile = await acquireProcessLock();
const server = createServer((req, res) => {
  handle(req, res).catch((error) => {
    console.error(error);
    if (!res.headersSent) sendJson(res, error.status || 500, { error: error.status ? error.message : "internal error" });
    else res.destroy();
  });
});
server.requestTimeout = 30_000;
server.headersTimeout = 35_000;
server.listen(port, host, () => console.log(`coordkit relay listening on http://${host}:${port}/v1/events`));

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await new Promise((resolveClose) => {
    const timer = setTimeout(() => {
      server.closeAllConnections();
      resolveClose();
    }, 5000);
    server.close(() => { clearTimeout(timer); resolveClose(); });
  });
  await Promise.allSettled([...roomLoads.values()]);
  await Promise.all([...rooms.values()].map((state) => state.queue.catch(() => {})));
  if (lockHandle) await lockHandle.close().catch(() => {});
  await unlink(lockFile).catch(() => {});
}
process.once("SIGINT", () => shutdown().finally(() => process.exit(0)));
process.once("SIGTERM", () => shutdown().finally(() => process.exit(0)));
