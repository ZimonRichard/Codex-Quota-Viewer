import Foundation
import Testing

@testable import CodexQuotaViewer

private actor CPAQuotaBridgeCallRecorder {
    private(set) var host: String?
    private(set) var command: String?
    private(set) var timeout: TimeInterval?

    func record(host: String, command: String, timeout: TimeInterval) {
        self.host = host
        self.command = command
        self.timeout = timeout
    }

    func snapshot() -> (String?, String?, TimeInterval?) {
        (host, command, timeout)
    }
}

@Test
func cpaQuotaSnapshotFetcherDefaultCommandUsesCurrentQinOpsPath() {
    #expect(CPAQuotaSnapshotFetcher.defaultRemoteCommand == "sudo -n /home/ubuntu/Qin/ops/cpa/show-cpa-pool-quota.py --json 300")
    #expect(!CPAQuotaSnapshotFetcher.defaultRemoteCommand.contains("/home/ubuntu/Qin/cpa/bin/"))
}

@Test
func cpaQuotaSnapshotFetcherDefaultTimeoutCoversServerBridgeTimeout() {
    #expect(CPAQuotaSnapshotFetcher.defaultTimeout == 15)
}

@Test
func cpaQuotaSnapshotFetcherKeepsAuthFilePlaceholdersWithoutLiveRecords() async throws {
    let runtimeMaterial = makeTestRuntimeMaterial(
        id: "svip",
        authMode: .apiKey,
        apiBaseURL: "http://127.0.0.1:3001/v1"
    )
    let response = """
    {
      "records_saved": 0,
      "current": null,
      "latest": [],
      "accounts": [
        {
          "id": "codex_plus_1.json",
          "display_name": "codex_plus_1",
          "auth_file": "codex_plus_1.json",
          "auth_index": null,
          "source_hint": "st***@mail.com",
          "is_current_route": false,
          "latest": null
        },
        {
          "id": "codex_plus_2.json",
          "display_name": "codex_plus_2",
          "auth_file": "codex_plus_2.json",
          "auth_index": null,
          "source_hint": "he***@mail.com",
          "is_current_route": false,
          "latest": null
        }
      ]
    }
    """
    let recorder = CPAQuotaBridgeCallRecorder()
    let fetcher = CPAQuotaSnapshotFetcher(
        environment: [
            "CODEX_QUOTA_VIEWER_CPA_SSH_HOST": "test-host",
            "CODEX_QUOTA_VIEWER_CPA_QUOTA_COMMAND": "test-command",
            "CODEX_QUOTA_VIEWER_CPA_TIMEOUT_SECONDS": "9",
        ],
        bridgeCommandRunner: { host, command, timeout in
            await recorder.record(host: host, command: command, timeout: timeout)
            return Data(response.utf8)
        }
    )

    let result = try await fetcher.fetchResult(
        runtimeMaterial: runtimeMaterial,
        displayName: "svip",
        timeout: 3
    )
    let call = await recorder.snapshot()

    #expect(call.0 == "test-host")
    #expect(call.1 == "test-command")
    #expect(call.2 == 3)
    #expect(result.snapshot.account.email == "svip")
    #expect(quotaDisplayWindows(from: result.snapshot).isEmpty)
    #expect(result.poolSnapshots.map(\.displayName) == ["codex_plus_1", "codex_plus_2"])
    #expect(result.poolSnapshots.map(\.authFile) == ["codex_plus_1.json", "codex_plus_2.json"])
    #expect(result.poolSnapshots.allSatisfy { quotaDisplayWindows(from: $0.snapshot).isEmpty })
}

@Test
func cpaQuotaSnapshotFetcherUsesScheduledRouteForParentSnapshotBeforeLegacyCurrentRecord() async throws {
    let runtimeMaterial = makeTestRuntimeMaterial(
        id: "svip",
        authMode: .apiKey,
        apiBaseURL: "http://127.0.0.1:3001/v1"
    )
    let response = """
    {
      "records_saved": 0,
      "current": {
        "timestamp": "2026-06-10T14:20:01Z",
        "auth_file": "codex_plus_1.json",
        "model": "quota-probe",
        "reasoning_effort": "read-only",
        "status_code": null,
        "codex_headers": {
          "X-Codex-Primary-Used-Percent": ["18"],
          "X-Codex-Primary-Window-Minutes": ["300"],
          "X-Codex-Primary-Reset-At": ["1800000360"],
          "X-Codex-Secondary-Used-Percent": ["91"],
          "X-Codex-Secondary-Window-Minutes": ["10080"],
          "X-Codex-Secondary-Reset-At": ["1800086400"]
        }
      },
      "latest": [],
      "accounts": [
        {
          "id": "codex_plus_1.json",
          "display_name": "codex_plus_1",
          "auth_file": "codex_plus_1.json",
          "is_current_route": false,
          "is_route_preferred": false,
          "latest": {
            "timestamp": "2026-06-10T14:20:01Z",
            "auth_file": "codex_plus_1.json",
            "model": "quota-probe",
            "reasoning_effort": "read-only",
            "status_code": null,
            "codex_headers": {
              "X-Codex-Primary-Used-Percent": ["18"],
              "X-Codex-Primary-Window-Minutes": ["300"],
              "X-Codex-Primary-Reset-At": ["1800000360"],
              "X-Codex-Secondary-Used-Percent": ["91"],
              "X-Codex-Secondary-Window-Minutes": ["10080"],
              "X-Codex-Secondary-Reset-At": ["1800086400"]
            }
          }
        },
        {
          "id": "codex_plus_2.json",
          "display_name": "codex_plus_2",
          "auth_file": "codex_plus_2.json",
          "is_current_route": false,
          "is_route_preferred": true,
          "latest": {
            "timestamp": "2026-06-10T14:20:02Z",
            "auth_file": "codex_plus_2.json",
            "model": "quota-probe",
            "reasoning_effort": "read-only",
            "status_code": null,
            "codex_headers": {
              "X-Codex-Primary-Used-Percent": ["58"],
              "X-Codex-Primary-Window-Minutes": ["300"],
              "X-Codex-Primary-Reset-At": ["1800000360"],
              "X-Codex-Secondary-Used-Percent": ["49"],
              "X-Codex-Secondary-Window-Minutes": ["10080"],
              "X-Codex-Secondary-Reset-At": ["1800086400"]
            }
          }
        }
      ]
    }
    """
    let fetcher = CPAQuotaSnapshotFetcher(
        environment: [
            "CODEX_QUOTA_VIEWER_CPA_SSH_HOST": "test-host",
            "CODEX_QUOTA_VIEWER_CPA_QUOTA_COMMAND": "test-command",
        ],
        bridgeCommandRunner: { _, _, _ in Data(response.utf8) }
    )

    let result = try await fetcher.fetchResult(
        runtimeMaterial: runtimeMaterial,
        displayName: "svip"
    )
    let parentWindows = quotaDisplayWindows(from: result.snapshot)

    #expect(parentWindows.map(\.window.usedPercent) == [58, 49])
    #expect(result.poolSnapshots.map(\.isRoutePreferred) == [false, true])
    #expect(result.poolSnapshots.first(where: \.isRoutePreferred)?.displayName == "codex_plus_2")
}
