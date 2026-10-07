"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const page =
  process.env.BLOCK_CONSOLE_HTML ||
  path.resolve(__dirname, "../../tools/block-console/index.html");
const html = fs.readFileSync(page, "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const address = (n) => "0x" + n.toString(16).padStart(40, "0");
const PARTY = address(100),
  SECOND_PARTY = address(101),
  QUEUE = address(102);
const ORIGINATOR = address(103),
  OWNER = address(104),
  OMITTED_OWNER = address(105),
  OMITTED_ORIGINATOR = address(106);
const word = (n) => BigInt(n).toString(16).padStart(64, "0");
const range = (count) => Array.from({ length: count }, (_, i) => i + 1);

function harness(active) {
  const elements = new Map();
  const calls = [];
  const copied = [];
  let detailGate;
  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        hidden: true,
        value: "",
        checked: false,
        textContent: "",
        innerHTML: "",
        listeners: new Map(),
        addEventListener(event, listener) {
          this.listeners.set(event, listener);
        },
        querySelectorAll() {
          return [];
        },
      });
    }
    return elements.get(id);
  };
  const context = vm.createContext({
    document: { getElementById: element, querySelectorAll: () => [] },
    navigator: { clipboard: { writeText: async (text) => copied.push(text) } },
    setTimeout: () => {},
    fetch: async (url, options) => {
      assert.equal(url, "dummy:queue");
      const request = JSON.parse(options.body);
      assert.equal(
        request.method,
        "eth_call",
        "only read methods are permitted",
      );
      assert.equal(request.params[0].to, QUEUE);
      assert.equal(request.params[1], "latest");
      const data = request.params[0].data;
      const selector = data.slice(0, 10);
      const words = data.slice(10).match(/.{64}/g) || [];
      let result;
      if (selector === "0x6e634bb2") {
        const party = "0x" + words[0].slice(24);
        const cursor = Number(BigInt("0x" + words[1]));
        const limit = Number(BigInt("0x" + words[2]));
        assert.equal(limit, 200);
        const ids = active.get(party) || [];
        const part = ids.slice(cursor, cursor + limit);
        const next =
          cursor + part.length < ids.length ? cursor + part.length : 0;
        result =
          "0x" +
          word(64) +
          word(next) +
          word(part.length) +
          part.map(word).join("");
        calls.push({ selector, party, cursor, next });
      } else if (selector === "0xc58343ef") {
        if (detailGate) {
          detailGate.entered();
          await detailGate.promise;
        }
        const id = Number(BigInt("0x" + words[0]));
        result =
          "0x" +
          [
            10n ** 18n,
            1700000000,
            1700086400,
            id === 8001 ? OMITTED_ORIGINATOR : ORIGINATOR,
            id === 8001 ? OMITTED_OWNER : OWNER,
            PARTY,
            0,
            0,
            0,
            1,
            0,
          ]
            .map(word)
            .join("");
        calls.push({ selector, id });
      } else {
        assert.equal(selector, "0x48b1738d", "unexpected call");
        result = "0x" + word(0);
        calls.push({ selector });
      }
      return {
        ok: true,
        json: async () => ({ jsonrpc: "2.0", id: request.id, result }),
      };
    },
  });
  vm.runInContext(
    script +
      `
    globalThis.app = {
      idsForAddresses, loadRequests, generate,
      setContext(value) { CTX = value; },
      rows() { return ROWS; },
      select(ids) { SELECTED.clear(); ids.forEach((id) => SELECTED.add(id)); render(); },
      selected() { return [...SELECTED]; }
    };
  `,
    context,
    { filename: page },
  );
  context.app.setContext({
    rpc: "dummy:queue",
    queue: QUEUE,
    last: 8001,
    paused: false,
  });
  element("fAddr").value = PARTY;
  element("fStatus").value = "queued";
  element("action").value = "freeze";
  return {
    app: context.app,
    element,
    calls,
    copied,
    holdDetailReads() {
      let release, entered;
      const promise = new Promise((resolve) => {
        release = resolve;
      });
      const waiting = new Promise((resolve) => {
        entered = resolve;
      });
      detailGate = { promise, entered };
      return {
        entered: waiting,
        release() {
          detailGate = undefined;
          release();
        },
      };
    },
  };
}

test("empty and small address reads preserve IDs without a partial warning", async () => {
  for (const ids of [[], [3, 1, 2]]) {
    const h = harness(new Map([[PARTY, ids]]));
    await h.app.loadRequests();
    assert.deepEqual(
      Array.from(h.app.rows(), (row) => row.id),
      [...ids].sort((a, b) => a - b),
    );
    assert.equal(h.element("partialRead").hidden, true);
    assert.equal(
      h.calls.filter((call) => call.selector === "0x6e634bb2").length,
      1,
    );
  }
});

test("exactly 8000 active IDs finish pagination at the page cap", async () => {
  const h = harness(new Map([[PARTY, range(8000)]]));
  await h.app.loadRequests();
  assert.equal(h.app.rows().length, 8000);
  assert.equal(h.element("partialRead").hidden, true);
  const pages = h.calls.filter((call) => call.selector === "0x6e634bb2");
  assert.equal(pages.length, 40);
  assert.equal(pages.at(-1).next, 0);
});

test("8001 IDs expose the incomplete read while preserving rows and selected calldata", async () => {
  const h = harness(new Map([[PARTY, range(8001)]]));
  await h.app.loadRequests();
  assert.equal(h.app.rows().length, 8000);
  assert.equal(h.app.rows().at(-1).id, 8000);
  assert.equal(
    h.element("partialRead").hidden,
    false,
    "a nonterminal capped read must warn",
  );
  assert.match(h.element("partialAddresses").textContent, new RegExp(PARTY));
  assert.match(h.element("count").textContent, /8000 requests shown/);
  const pages = h.calls.filter((call) => call.selector === "0x6e634bb2");
  assert.equal(pages.length, 40);
  assert.equal(pages.at(-1).next, 8000);

  h.element("selAll").listeners.get("change")({ target: { checked: true } });
  assert.equal(h.app.selected().length, 8000);
  h.app.select([8000, 1]);
  assert.equal(h.element("freezeRecv").checked, false);
  assert.ok(!h.element("selParties").innerHTML.includes(OMITTED_OWNER));
  assert.ok(!h.element("selParties").innerHTML.includes(OMITTED_ORIGINATOR));
  const reads = h.calls.length;
  h.app.generate();
  const data = h
    .element("callOut")
    .innerHTML.match(/<pre id="cd">([^<]+)<\/pre>/)[1];
  assert.equal(
    data,
    "0x9c5ec771" +
      word(96) +
      word(0) +
      word(0) +
      word(2) +
      word(1) +
      word(8000),
  );
  assert.match(h.element("callOut").innerHTML, /#1, #8000/);
  assert.equal(
    h.element("partialRead").hidden,
    false,
    "warning must remain during generation",
  );
  assert.equal(
    h.calls.length,
    reads,
    "generation must not submit or make RPC calls",
  );
  await h.element("copy").listeners.get("click")();
  assert.deepEqual(h.copied, [data]);
  assert.equal(h.calls.length, reads);
});

test("a later complete address cannot hide an earlier capped address", async () => {
  const h = harness(
    new Map([
      [PARTY, range(8001)],
      [SECOND_PARTY, [8002, 1]],
    ]),
  );
  h.element("fAddr").value = `${PARTY}, ${SECOND_PARTY}`;
  await h.app.loadRequests();
  assert.equal(h.app.rows().length, 8001);
  assert.equal(h.app.rows().at(-1).id, 8002);
  assert.equal(h.element("partialRead").hidden, false);
  assert.equal(h.element("partialAddresses").textContent, PARTY);
});

test("a successful complete filtered refresh clears the cap warning and prunes only absent selections", async () => {
  const active = new Map([[PARTY, range(8001)]]);
  const h = harness(active);
  await h.app.loadRequests();
  assert.equal(h.element("partialRead").hidden, false);
  h.app.select([1, 8000]);
  active.set(PARTY, [1, 2]);
  await h.app.loadRequests();
  assert.equal(h.element("partialRead").hidden, true);
  assert.deepEqual(
    Array.from(h.app.rows(), (row) => row.id),
    [1, 2],
  );
  assert.deepEqual(Array.from(h.app.selected()), [1]);
});

test("a successful unfiltered read clears a previous cap warning", async () => {
  const h = harness(new Map([[PARTY, range(8001)]]));
  await h.app.loadRequests();
  assert.equal(h.element("partialRead").hidden, false);
  h.element("fAddr").value = "";
  await h.app.loadRequests();
  assert.equal(h.app.rows().length, 8001);
  assert.equal(h.element("partialRead").hidden, true);
});

test("pending detail reads retain the warning for the displayed partial rows", async () => {
  const active = new Map([[PARTY, range(8001)]]);
  const h = harness(active);
  await h.app.loadRequests();
  assert.equal(h.element("partialRead").hidden, false);
  active.set(PARTY, [1, 2]);
  const held = h.holdDetailReads();
  const pending = h.app.loadRequests();
  await held.entered;
  try {
    assert.equal(
      h.element("partialRead").hidden,
      false,
      "old partial rows still need their warning",
    );
    assert.equal(h.element("count").textContent, "8000 requests shown");
  } finally {
    held.release();
    await pending;
  }
  assert.equal(h.element("partialRead").hidden, true);
  assert.equal(h.element("count").textContent, "2 requests shown");
});

test("the warning is visible outside tabs and explicitly qualifies selected calldata", () => {
  const header = html.slice(
    html.indexOf("<header>"),
    html.indexOf("</header>"),
  );
  assert.match(header, /id="partialRead"[^>]*role="alert"[^>]*hidden/);
  assert.match(header, /More matching requests remain/);
  assert.match(header, /calldata covers only your selected shown requests/);
});
