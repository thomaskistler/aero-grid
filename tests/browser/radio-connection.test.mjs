// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const source = (await readFile(new URL("../../docs/javascripts/radio-storage.mjs", import.meta.url), "utf8"))
  .replace(/^export /gm, "");

function environment(locks) {
  const handles = new Map();
  const session = new Map();
  const context = vm.createContext({
    console,
    navigator: locks ? { locks } : {},
    crypto: { randomUUID: () => "connection-1" },
    sessionStorage: {
      getItem: (key) => session.get(key) ?? null,
      setItem: (key, value) => session.set(key, value),
      removeItem: (key) => session.delete(key),
    },
    indexedDB: {
      open() {
        const request = {};
        queueMicrotask(() => {
          request.result = {
            close() {},
            transaction() {
              const transaction = {
                objectStore: () => ({
                  get(key) { return complete(handles.get(key)); },
                  put(handle, key) { handles.set(key, handle); return complete(key); },
                  delete(key) { handles.delete(key); return complete(); },
                }),
              };
              function complete(result) {
                queueMicrotask(() => transaction.oncomplete());
                return { result };
              }
              return transaction;
            },
          };
          request.onsuccess();
        });
        return request;
      },
    },
  });
  vm.runInContext(source, context);
  const create = () => vm.runInContext("new RadioStorage(undefined, true)", context);
  return { create, session, handles };
}

function directory(name, children = []) {
  return { name, kind: "directory", async *entries() { yield* children; } };
}

function radioRoot() {
  const metadata = {
    kind: "file",
    async getFile() { return { size: 40, text: async () => "board: tx16s\nsemver: 2.12.0\n" }; },
  };
  return Object.assign(directory("Radio SD", [
    ["RADIO", directory("RADIO", [["radio.yml", metadata]])],
    ["MODELS", directory("MODELS")],
    ["WIDGETS", directory("WIDGETS")],
  ]), { queryPermission: async () => "granted" });
}

test("radio handle survives page instances without reopening the folder picker", async () => {
  const { create } = environment();
  const root = radioRoot();
  const firstPage = create();
  firstPage.picker = async () => root;
  await firstPage.connect();
  const installer = create();
  installer.picker = () => { throw new Error("Picker must not reopen during navigation."); };
  assert.equal(await installer.restore(), true);
  assert.equal(installer.root, root);
  assert.equal((await installer.inspect()).radio.board, "tx16s");
  const nextPage = create();
  assert.equal(await nextPage.restore(), true);
  assert.equal(nextPage.root, root);
});

test("explicit disconnect prevents restoration on another page", async () => {
  const { create, session } = environment();
  const connected = create();
  connected.picker = async () => radioRoot();
  await connected.connect();
  connected.disconnect();
  assert.equal(session.size, 0);
  const next = create();
  assert.equal(await next.restore(), false);
  assert.equal(next.root, null);
});

test("lost permission or unavailable radio never restores a connected state", async () => {
  for (const unavailable of ["permission", "unplugged"]) {
    const { create, session } = environment();
    const root = radioRoot();
    const connected = create();
    connected.picker = async () => root;
    await connected.connect();
    if (unavailable === "permission") root.queryPermission = async () => "prompt";
    else root.entries = async function* () { throw new Error("Drive unavailable"); };
    const next = create();
    await assert.rejects(next.restore(), /Unable to restore the radio connection/);
    assert.equal(next.root, null);
    assert.equal(session.size, 0);
  }
});

test("restored page instances share the write lock and release busy state after contention", async () => {
  let held = false;
  const locks = {
    async request(name, options, callback) {
      assert.equal(name, "aerogrid-radio-write");
      assert.equal(options.ifAvailable, true);
      if (held) return callback(null);
      held = true;
      try {
        return await callback({});
      } finally {
        held = false;
      }
    },
  };
  const { create } = environment(locks);
  const first = create();
  first.picker = async () => radioRoot();
  await first.connect();
  const second = create();
  await second.restore();
  let finish;
  const running = first.exclusive(() => new Promise((resolve) => { finish = resolve; }));
  await assert.rejects(second.exclusive(() => assert.fail("Concurrent operation ran")), /Another AeroGrid page/);
  assert.equal(second.busy, false);
  finish();
  await running;
  assert.equal(await second.exclusive(() => "available"), "available");
});
