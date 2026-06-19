import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { afterEach, describe, expect, test } from "vitest";

import {
  resolveStateDatabasePath,
  resolveStateDatabasePaths,
} from "../../src/server/services/codex-thread-state-repository";

describe("resolveStateDatabasePath", () => {
  let roots: string[] = [];

  afterEach(async () => {
    await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })));
    roots = [];
  });

  test("prefers the new Codex sqlite state database over the legacy root database", async () => {
    const codexHome = await makeCodexHome();
    const sqliteDirectory = path.join(codexHome, "sqlite");
    const legacyPath = path.join(codexHome, "state_5.sqlite");
    const sqlitePath = path.join(sqliteDirectory, "state_5.sqlite");

    await mkdir(sqliteDirectory, { recursive: true });
    await writeFile(legacyPath, "");
    await writeFile(sqlitePath, "");

    expect(resolveStateDatabasePath(codexHome)).toBe(sqlitePath);
    expect(resolveStateDatabasePaths(codexHome)).toEqual([sqlitePath, legacyPath]);
  });

  test("falls back to the legacy root database when sqlite state is missing", async () => {
    const codexHome = await makeCodexHome();
    const legacyPath = path.join(codexHome, "state_5.sqlite");

    await writeFile(legacyPath, "");

    expect(resolveStateDatabasePath(codexHome)).toBe(legacyPath);
    expect(resolveStateDatabasePaths(codexHome)).toEqual([legacyPath]);
  });

  test("prefers sqlite state.db over a stale legacy root database", async () => {
    const codexHome = await makeCodexHome();
    const sqliteDirectory = path.join(codexHome, "sqlite");
    const sqlitePath = path.join(sqliteDirectory, "state.db");

    await mkdir(sqliteDirectory, { recursive: true });
    await writeFile(path.join(codexHome, "state_5.sqlite"), "");
    await writeFile(sqlitePath, "");

    expect(resolveStateDatabasePath(codexHome)).toBe(sqlitePath);
    expect(resolveStateDatabasePaths(codexHome)).toEqual([
      sqlitePath,
      path.join(codexHome, "state_5.sqlite"),
    ]);
  });

  test("chooses the highest state version within the selected location", async () => {
    const codexHome = await makeCodexHome();
    const sqliteDirectory = path.join(codexHome, "sqlite");
    const newestPath = path.join(sqliteDirectory, "state_7.sqlite");

    await mkdir(sqliteDirectory, { recursive: true });
    await writeFile(path.join(sqliteDirectory, "state_5.sqlite"), "");
    await writeFile(newestPath, "");

    expect(resolveStateDatabasePath(codexHome)).toBe(newestPath);
  });

  async function makeCodexHome() {
    const root = await mkdtemp(path.join(tmpdir(), "codex-thread-state-"));
    roots.push(root);
    const codexHome = path.join(root, ".codex");
    await mkdir(codexHome, { recursive: true });
    return codexHome;
  }
});
