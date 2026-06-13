import { existsSync, readdirSync } from "node:fs";
import path from "node:path";

import Database from "better-sqlite3";

export type CodexThreadRecord = {
  id: string;
  rolloutPath: string;
  createdAt: number;
  updatedAt: number;
  createdAtMs: number | null;
  updatedAtMs: number | null;
  source: string;
  threadSource: string | null;
  modelProvider: string;
  cwd: string;
  title: string;
  preview: string;
  sandboxPolicy: string;
  approvalMode: string;
  hasUserEvent: boolean;
  archived: 0 | 1;
  archivedAt: number | null;
  cliVersion: string;
  firstUserMessage: string;
  memoryMode: string;
  model: string | null;
  reasoningEffort: string | null;
  agentPath: string | null;
};

export type CodexThreadUpsert = Omit<CodexThreadRecord, "hasUserEvent"> & {
  hasUserEvent?: boolean;
};

export class CodexThreadStateRepository {
  private readonly db: Database.Database | null;
  private readonly columns: Set<string>;

  constructor(codexHome: string) {
    const databasePath = resolveStateDatabasePath(codexHome);

    if (!databasePath) {
      this.db = null;
      this.columns = new Set();
      return;
    }

    const db = new Database(databasePath);

    if (
      !db
        .prepare(
          `
            select 1
            from sqlite_master
            where type = 'table' and name = 'threads'
          `,
        )
        .get()
    ) {
      db.close();
      this.db = null;
      this.columns = new Set();
      return;
    }

    this.db = db;
    this.columns = readTableColumns(db, "threads");
  }

  listThreads() {
    if (!this.db) {
      return [] as CodexThreadRecord[];
    }

    const rows = this.db
      .prepare(
        `
          select
            ${this.selectColumns()}
          from threads
          order by updated_at desc, id asc
        `,
      )
      .all() as ThreadRow[];

    return rows.map(mapThreadRow);
  }

  getThread(threadId: string) {
    if (!this.db) {
      return null;
    }

    const row = this.db
      .prepare(
        `
          select
            ${this.selectColumns()}
          from threads
          where id = ?
        `,
      )
      .get(threadId) as ThreadRow | undefined;

    return row ? mapThreadRow(row) : null;
  }

  upsertThread(input: CodexThreadUpsert) {
    if (!this.db) {
      return "skipped" as const;
    }

    const existing = this.getThread(input.id);
    const next = buildThreadRecord(input, existing);

    if (existing && areSameThread(existing, next, this.columns)) {
      return "unchanged" as const;
    }

    if (existing) {
      const updates = writableColumnMappings(this.columns)
        .filter(([column]) => column !== "id")
        .map(([column, param]) => `${column} = @${param}`)
        .join(",\n                ");

      this.db
        .prepare(
          `
            update threads
            set ${updates}
            where id = @id
          `,
        )
        .run(toDatabaseParams(next));

      return "updated" as const;
    }

    const mappings = writableColumnMappings(this.columns);
    const columns = mappings.map(([column]) => column).join(",\n            ");
    const values = mappings.map(([, param]) => `@${param}`).join(",\n            ");

    this.db
      .prepare(
        `
          insert into threads (
            ${columns}
          ) values (
            ${values}
          )
        `,
      )
      .run(toDatabaseParams(next));

    return "created" as const;
  }

  deleteThread(threadId: string) {
    if (!this.db) {
      return false;
    }

    const result = this.db.prepare("delete from threads where id = ?").run(threadId);
    return result.changes > 0;
  }

  private selectColumns() {
    return [
      "id",
      "rollout_path as rolloutPath",
      "created_at as createdAt",
      "updated_at as updatedAt",
      this.selectOptionalColumn("created_at_ms", "createdAtMs", "null"),
      this.selectOptionalColumn("updated_at_ms", "updatedAtMs", "null"),
      "source",
      this.selectOptionalColumn("thread_source", "threadSource", "null"),
      "model_provider as modelProvider",
      "cwd",
      "title",
      this.selectOptionalColumn("preview", "preview", "''"),
      "sandbox_policy as sandboxPolicy",
      "approval_mode as approvalMode",
      "has_user_event as hasUserEvent",
      "archived",
      "archived_at as archivedAt",
      "cli_version as cliVersion",
      "first_user_message as firstUserMessage",
      "memory_mode as memoryMode",
      "model",
      "reasoning_effort as reasoningEffort",
      "agent_path as agentPath",
    ].join(",\n            ");
  }

  private selectOptionalColumn(column: string, alias: string, fallback: string) {
    return this.columns.has(column)
      ? `${column} as ${alias}`
      : `${fallback} as ${alias}`;
  }
}

type ThreadRow = {
  id: string;
  rolloutPath: string;
  createdAt: number;
  updatedAt: number;
  createdAtMs: number | null;
  updatedAtMs: number | null;
  source: string;
  threadSource: string | null;
  modelProvider: string;
  cwd: string;
  title: string;
  preview: string | null;
  sandboxPolicy: string;
  approvalMode: string;
  hasUserEvent: number;
  archived: number;
  archivedAt: number | null;
  cliVersion: string;
  firstUserMessage: string;
  memoryMode: string;
  model: string | null;
  reasoningEffort: string | null;
  agentPath: string | null;
};

type DatabaseThreadParams = ReturnType<typeof toDatabaseParams>;
type ColumnMapping = [column: string, param: keyof DatabaseThreadParams];

const BASE_WRITE_COLUMN_MAPPINGS: ColumnMapping[] = [
  ["id", "id"],
  ["rollout_path", "rolloutPath"],
  ["created_at", "createdAt"],
  ["updated_at", "updatedAt"],
  ["source", "source"],
  ["model_provider", "modelProvider"],
  ["cwd", "cwd"],
  ["title", "title"],
  ["sandbox_policy", "sandboxPolicy"],
  ["approval_mode", "approvalMode"],
  ["has_user_event", "hasUserEvent"],
  ["archived", "archived"],
  ["archived_at", "archivedAt"],
  ["cli_version", "cliVersion"],
  ["first_user_message", "firstUserMessage"],
  ["memory_mode", "memoryMode"],
  ["model", "model"],
  ["reasoning_effort", "reasoningEffort"],
  ["agent_path", "agentPath"],
];

const OPTIONAL_WRITE_COLUMN_MAPPINGS: ColumnMapping[] = [
  ["created_at_ms", "createdAtMs"],
  ["updated_at_ms", "updatedAtMs"],
  ["thread_source", "threadSource"],
  ["preview", "preview"],
];

function buildThreadRecord(input: CodexThreadUpsert, existing: CodexThreadRecord | null) {
  return {
    id: input.id,
    rolloutPath: input.rolloutPath,
    createdAt: input.createdAt,
    updatedAt: input.updatedAt,
    createdAtMs: input.createdAtMs ?? existing?.createdAtMs ?? input.createdAt * 1000,
    updatedAtMs: input.updatedAtMs ?? input.updatedAt * 1000,
    source: input.source,
    threadSource: normalizeThreadSource(input.threadSource ?? existing?.threadSource),
    modelProvider: input.modelProvider,
    cwd: input.cwd,
    title: input.title,
    preview: input.preview,
    sandboxPolicy: input.sandboxPolicy,
    approvalMode: input.approvalMode,
    hasUserEvent: input.hasUserEvent ?? existing?.hasUserEvent ?? true,
    archived: input.archived,
    archivedAt: input.archived === 1 ? input.archivedAt ?? existing?.archivedAt ?? input.updatedAt : null,
    cliVersion: input.cliVersion,
    firstUserMessage: input.firstUserMessage,
    memoryMode: input.memoryMode,
    model: input.model,
    reasoningEffort: input.reasoningEffort,
    agentPath: input.agentPath,
  } satisfies CodexThreadRecord;
}

function areSameThread(
  left: CodexThreadRecord,
  right: CodexThreadRecord,
  columns: Set<string>,
) {
  const baseMatches =
    left.rolloutPath === right.rolloutPath &&
    left.createdAt === right.createdAt &&
    left.updatedAt === right.updatedAt &&
    left.source === right.source &&
    left.modelProvider === right.modelProvider &&
    left.cwd === right.cwd &&
    left.title === right.title &&
    left.sandboxPolicy === right.sandboxPolicy &&
    left.approvalMode === right.approvalMode &&
    left.hasUserEvent === right.hasUserEvent &&
    left.archived === right.archived &&
    left.archivedAt === right.archivedAt &&
    left.cliVersion === right.cliVersion &&
    left.firstUserMessage === right.firstUserMessage &&
    left.memoryMode === right.memoryMode &&
    left.model === right.model &&
    left.reasoningEffort === right.reasoningEffort &&
    left.agentPath === right.agentPath;

  if (!baseMatches) {
    return false;
  }

  return (
    (!columns.has("created_at_ms") || left.createdAtMs === right.createdAtMs) &&
    (!columns.has("updated_at_ms") || left.updatedAtMs === right.updatedAtMs) &&
    (!columns.has("thread_source") || left.threadSource === right.threadSource) &&
    (!columns.has("preview") || left.preview === right.preview)
  );
}

function toDatabaseParams(record: CodexThreadRecord) {
  return {
    ...record,
    hasUserEvent: record.hasUserEvent ? 1 : 0,
  };
}

function mapThreadRow(row: ThreadRow): CodexThreadRecord {
  return {
    ...row,
    archived: row.archived === 1 ? 1 : 0,
    hasUserEvent: row.hasUserEvent === 1,
    preview: row.preview ?? "",
  };
}

function writableColumnMappings(columns: Set<string>) {
  return [
    ...BASE_WRITE_COLUMN_MAPPINGS,
    ...OPTIONAL_WRITE_COLUMN_MAPPINGS.filter(([column]) => columns.has(column)),
  ];
}

function readTableColumns(db: Database.Database, tableName: string) {
  const rows = db.prepare(`pragma table_info(${tableName})`).all() as Array<{ name: string }>;
  return new Set(rows.map((row) => row.name));
}

function normalizeThreadSource(value: string | null | undefined) {
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : "user";
}

export function resolveStateDatabasePath(codexHome: string) {
  const sqliteDirectory = path.join(codexHome, "sqlite");
  const sqliteCandidates = listStateDatabaseCandidates(sqliteDirectory);

  if (sqliteCandidates.length > 0) {
    return sqliteCandidates[0];
  }

  const sqliteStateDb = path.join(sqliteDirectory, "state.db");

  if (existsSync(sqliteStateDb)) {
    return sqliteStateDb;
  }

  const directCandidates = listStateDatabaseCandidates(codexHome);

  if (directCandidates.length > 0) {
    return directCandidates[0];
  }

  return null;
}

function listStateDatabaseCandidates(codexHome: string) {
  try {
    return readdirSync(codexHome, { withFileTypes: true })
      .filter(
        (entry): entry is typeof entry & { name: string } =>
          entry.isFile() && /^state_(\d+)\.sqlite$/.test(entry.name),
      )
      .sort((left, right) => extractStateVersion(right.name) - extractStateVersion(left.name))
      .map((entry) => path.join(codexHome, entry.name));
  } catch {
    return [];
  }
}

function extractStateVersion(fileName: string) {
  const match = fileName.match(/^state_(\d+)\.sqlite$/);
  return match ? Number(match[1]) : -1;
}
