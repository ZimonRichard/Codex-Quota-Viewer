import type {
  OfficialRepairStats,
  SessionOfficialIssueCode,
  SessionOfficialState,
  SessionRecord,
} from "../../shared/contracts";
import {
  CodexSessionIndexRepository,
  type CodexSessionIndexEntry,
} from "./codex-session-index-repository";
import {
  CodexThreadStateRepositorySet,
  type CodexThreadRecord,
  type CodexThreadUpsert,
} from "./codex-thread-state-repository";
import { readSessionMetaSnapshot } from "./jsonl-session-parser";
import { pathExists } from "./session-manager-helpers";

const DEFAULT_SANDBOX_POLICY = "workspace-write";
const DEFAULT_APPROVAL_MODE = "default";

export class CodexOfficialThreadBridge {
  private readonly threads: CodexThreadStateRepositorySet;
  private readonly sessionIndex: CodexSessionIndexRepository;

  constructor(codexHome: string) {
    this.threads = new CodexThreadStateRepositorySet(codexHome);
    this.sessionIndex = new CodexSessionIndexRepository(codexHome);
  }

  async inspectSession(record: SessionRecord): Promise<SessionOfficialState> {
    this.threads.refresh();
    const thread = this.threads.getThread(record.id);
    const indexEntry = await this.sessionIndex.getEntry(record.id);
    const desired = buildDesiredProjection(record, thread, indexEntry);

    if (!desired) {
      const issueCodes = [
        thread ? "snapshot_thread_still_present" : null,
        indexEntry ? "snapshot_recent_conversation_still_present" : null,
      ].filter((issue): issue is SessionOfficialIssueCode => Boolean(issue));

      return {
        status: issueCodes.length > 0 ? "repair_needed" : "hidden",
        canAppearInCodex: false,
        issueCodes,
      };
    }

    const threadRowPresent = Boolean(thread);
    const sessionIndexPresent = Boolean(indexEntry);
    const rolloutPathMatches = thread?.rolloutPath === desired.rolloutPath;
    const archivedFlagMatches = thread?.archived === desired.archived;
    const sessionIndexMatches =
      indexEntry?.threadName === desired.threadName &&
      indexEntry.updatedAt === desired.updatedAt;
    const issueCodes = [
      !threadRowPresent ? "missing_thread" : null,
      threadRowPresent && !rolloutPathMatches ? "wrong_rollout_path" : null,
      threadRowPresent && !archivedFlagMatches ? "archived_flag_mismatch" : null,
      !sessionIndexPresent ? "missing_recent_conversation" : null,
      sessionIndexPresent && !sessionIndexMatches ? "stale_recent_conversation" : null,
    ].filter((issue): issue is SessionOfficialIssueCode => Boolean(issue));

    return {
      status: issueCodes.length > 0 ? "repair_needed" : "synced",
      canAppearInCodex: true,
      issueCodes,
    };
  }

  async repairSessions(
    records: SessionRecord[],
    options: {
      sessionIds?: string[];
      cleanupBroken?: boolean;
    } = {},
  ): Promise<OfficialRepairStats> {
    this.threads.refresh();
    const selectedIds = new Set(options.sessionIds ?? records.map((record) => record.id));
    const selectedRecords = records.filter((record) => selectedIds.has(record.id));
    const sessionIndexMap = new Map(
      (await this.sessionIndex.listEntries()).map((entry) => [entry.id, entry]),
    );
    const stats = createEmptyStats();

    for (const record of selectedRecords) {
      const currentThread = this.threads.getThread(record.id);
      const currentIndexEntry = sessionIndexMap.get(record.id) ?? null;
      const desired = buildDesiredProjection(record, currentThread, currentIndexEntry);

      if (!desired) {
        const removedThread = this.threads.deleteThread(record.id);
        const removedIndex = sessionIndexMap.delete(record.id);

        if (removedThread || removedIndex) {
          stats.hiddenSnapshotOnlySessions += 1;
        }

        if (removedIndex) {
          stats.updatedSessionIndexEntries += 1;
        }

        continue;
      }

      const nextThread = await this.buildThreadUpsert(record, desired, currentThread);
      const threadResult = this.threads.upsertThread(nextThread);
      const sessionIndexResult = upsertSessionIndexEntry(sessionIndexMap, {
        id: desired.id,
        threadName: desired.threadName,
        updatedAt: desired.updatedAt,
      });

      if (threadResult === "created") {
        stats.createdThreads += 1;
      } else if (threadResult === "updated") {
        stats.updatedThreads += 1;
      }

      if (sessionIndexResult === "created" || sessionIndexResult === "updated") {
        stats.updatedSessionIndexEntries += 1;
      }
    }

    if (options.cleanupBroken) {
      await this.cleanupBrokenOfficialThreads(records, sessionIndexMap, stats);
    }

    await this.sessionIndex.replaceEntries(sessionIndexMap.values());

    return stats;
  }

  async removeSession(sessionId: string) {
    this.threads.refresh();
    const removedThread = this.threads.deleteThread(sessionId);
    const removedIndex = await this.sessionIndex.deleteEntry(sessionId);

    return {
      removedThread,
      removedIndex,
    };
  }

  private async buildThreadUpsert(
    record: SessionRecord,
    desired: DesiredProjection,
    existing: CodexThreadRecord | null,
  ): Promise<CodexThreadUpsert> {
    const meta = await readSessionMetaSnapshot(desired.rolloutPath);
    const createdAt = existing?.createdAt ?? toUnixSeconds(record.startedAt);
    const updatedAt = toUnixSeconds(desired.updatedAt);

    return {
      id: record.id,
      rolloutPath: desired.rolloutPath,
      createdAt,
      updatedAt,
      createdAtMs:
        existing?.createdAtMs ??
        toUnixMilliseconds(record.startedAt) ??
        createdAt * 1000,
      updatedAtMs: toUnixMilliseconds(desired.updatedAt) ?? updatedAt * 1000,
      source: serializeThreadSource(meta?.source ?? existing?.source ?? record.source),
      threadSource: resolveThreadSource(
        meta?.threadSource ?? existing?.threadSource ?? meta?.source ?? existing?.source ?? record.source,
      ),
      modelProvider: meta?.modelProvider ?? existing?.modelProvider ?? record.modelProvider,
      cwd: record.cwd,
      title: desired.threadName,
      preview: resolveThreadPreview(record, existing),
      sandboxPolicy: meta?.sandboxPolicy ?? existing?.sandboxPolicy ?? DEFAULT_SANDBOX_POLICY,
      approvalMode: meta?.approvalMode ?? existing?.approvalMode ?? DEFAULT_APPROVAL_MODE,
      archived: desired.archived,
      archivedAt:
        desired.archived === 1
          ? existing?.archivedAt ?? updatedAt
          : null,
      cliVersion: meta?.cliVersion ?? existing?.cliVersion ?? record.cliVersion,
      firstUserMessage: resolveFirstUserMessage(record, existing, desired.threadName),
      memoryMode: meta?.memoryMode ?? existing?.memoryMode ?? "enabled",
      model: meta?.model ?? existing?.model ?? null,
      reasoningEffort: meta?.reasoningEffort ?? existing?.reasoningEffort ?? null,
      agentPath: meta?.agentPath ?? existing?.agentPath ?? null,
      hasUserEvent: record.userPromptExcerpt.trim().length > 0
        ? true
        : existing?.hasUserEvent ?? true,
    };
  }

  private async cleanupBrokenOfficialThreads(
    records: SessionRecord[],
    sessionIndexMap: Map<string, CodexSessionIndexEntry>,
    stats: OfficialRepairStats,
  ) {
    const managedIds = new Set(records.map((record) => record.id));
    const officialThreads = this.threads.listThreads();

    for (const thread of officialThreads) {
      if (managedIds.has(thread.id)) {
        continue;
      }

      if (await pathExists(thread.rolloutPath)) {
        continue;
      }

      if (this.threads.deleteThread(thread.id)) {
        stats.removedBrokenThreads += 1;
      }

      if (sessionIndexMap.delete(thread.id)) {
        stats.updatedSessionIndexEntries += 1;
      }
    }

    const officialThreadIds = new Set(this.threads.listThreads().map((thread) => thread.id));

    for (const entry of sessionIndexMap.values()) {
      if (officialThreadIds.has(entry.id)) {
        continue;
      }

      const managed = records.find((record) => record.id === entry.id);

      if (managed && buildDesiredProjection(managed)) {
        continue;
      }

      if (sessionIndexMap.delete(entry.id)) {
        stats.updatedSessionIndexEntries += 1;
      }
    }
  }
}

type DesiredProjection = {
  id: string;
  rolloutPath: string;
  archived: 0 | 1;
  threadName: string;
  updatedAt: string;
};

function buildDesiredProjection(
  record: SessionRecord,
  existingThread?: CodexThreadRecord | null,
  existingIndexEntry?: CodexSessionIndexEntry | null,
): DesiredProjection | null {
  if (record.status === "restorable") {
    return null;
  }

  const rolloutPath = record.activePath ?? record.archivePath;

  if (!rolloutPath) {
    return null;
  }

  return {
    id: record.id,
    rolloutPath,
    archived: record.status === "active" ? 0 : 1,
    threadName: resolveDesiredThreadName(record, existingThread, existingIndexEntry),
    updatedAt: resolveDesiredUpdatedAt(record, existingThread, existingIndexEntry),
  };
}

function resolveDesiredThreadName(
  record: SessionRecord,
  existingThread?: CodexThreadRecord | null,
  existingIndexEntry?: CodexSessionIndexEntry | null,
) {
  const defaultName = buildThreadName(record);
  const existingTitle = existingThread?.title.trim() ?? "";
  const indexTitle = existingIndexEntry?.threadName.trim() ?? "";
  const existingFirstUserMessage = existingThread?.firstUserMessage.trim() ?? "";

  if (
    existingTitle.length > 0 &&
    existingTitle !== defaultName &&
    existingTitle !== existingFirstUserMessage &&
    (existingTitle === indexTitle || indexTitle === defaultName)
  ) {
    return existingTitle;
  }

  if (
    indexTitle.length > 0 &&
    indexTitle !== defaultName &&
    indexTitle !== existingFirstUserMessage &&
    existingTitle === defaultName
  ) {
    return indexTitle;
  }

  return defaultName;
}

function resolveDesiredUpdatedAt(
  record: SessionRecord,
  existingThread?: CodexThreadRecord | null,
  existingIndexEntry?: CodexSessionIndexEntry | null,
) {
  if (Number.isFinite(Date.parse(record.updatedAt))) {
    return record.updatedAt;
  }

  const candidates = [
    existingIndexEntry?.updatedAt,
    existingThread ? new Date(existingThread.updatedAt * 1000).toISOString() : null,
  ].filter((value): value is string => Boolean(value));

  if (candidates.length === 0) {
    return record.startedAt;
  }

  return candidates.reduce((latest, candidate) =>
    Date.parse(candidate) > Date.parse(latest) ? candidate : latest,
  );
}

function buildThreadName(record: Pick<SessionRecord, "id" | "userPromptExcerpt" | "latestAgentMessageExcerpt">) {
  const preferred = record.userPromptExcerpt.trim();

  if (preferred.length > 0) {
    return preferred;
  }

  const fallback = record.latestAgentMessageExcerpt.trim();
  return fallback.length > 0 ? fallback : record.id;
}

function resolveFirstUserMessage(
  record: Pick<SessionRecord, "userPromptExcerpt">,
  existing: Pick<CodexThreadRecord, "firstUserMessage"> | null,
  fallback: string,
) {
  const preferred = record.userPromptExcerpt.trim();

  if (preferred.length > 0) {
    return preferred;
  }

  const existingValue = existing?.firstUserMessage.trim() ?? "";
  return existingValue.length > 0 ? existingValue : fallback;
}

function serializeThreadSource(value: unknown) {
  if (typeof value === "string" && value.length > 0) {
    return value;
  }

  if (value && typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return "vscode";
    }
  }

  return "vscode";
}

function resolveThreadSource(value: unknown) {
  if (typeof value === "string") {
    const trimmed = value.trim();

    if (trimmed === "subagent") {
      return "subagent";
    }

    if (trimmed === "user") {
      return "user";
    }

    if (trimmed.startsWith("{")) {
      try {
        return resolveThreadSource(JSON.parse(trimmed) as unknown);
      } catch {
        return "user";
      }
    }

    return "user";
  }

  if (value && typeof value === "object" && "subagent" in value) {
    return "subagent";
  }

  return "user";
}

function resolveThreadPreview(
  record: Pick<SessionRecord, "latestAgentMessageExcerpt" | "userPromptExcerpt">,
  existing: Pick<CodexThreadRecord, "preview"> | null,
) {
  const latestAgent = record.latestAgentMessageExcerpt.trim();

  if (latestAgent.length > 0) {
    return latestAgent;
  }

  const firstUser = record.userPromptExcerpt.trim();

  if (firstUser.length > 0) {
    return firstUser;
  }

  return existing?.preview ?? "";
}

function createEmptyStats(): OfficialRepairStats {
  return {
    createdThreads: 0,
    updatedThreads: 0,
    updatedSessionIndexEntries: 0,
    removedBrokenThreads: 0,
    hiddenSnapshotOnlySessions: 0,
  };
}

function toUnixSeconds(value: string) {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? Math.floor(timestamp / 1000) : Math.floor(Date.now() / 1000);
}

function toUnixMilliseconds(value: string) {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function upsertSessionIndexEntry(
  entries: Map<string, CodexSessionIndexEntry>,
  nextEntry: CodexSessionIndexEntry,
) {
  const existing = entries.get(nextEntry.id);

  if (
    existing &&
    existing.threadName === nextEntry.threadName &&
    existing.updatedAt === nextEntry.updatedAt
  ) {
    return "unchanged" as const;
  }

  entries.set(nextEntry.id, nextEntry);
  return existing ? ("updated" as const) : ("created" as const);
}
