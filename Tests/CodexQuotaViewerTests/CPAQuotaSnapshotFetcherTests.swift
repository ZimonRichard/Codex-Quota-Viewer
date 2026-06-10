import Testing

@testable import CodexQuotaViewer

@Test
func cpaQuotaSnapshotFetcherDefaultCommandUsesCurrentQinOpsPath() {
    #expect(CPAQuotaSnapshotFetcher.defaultRemoteCommand == "sudo -n /home/ubuntu/Qin/ops/cpa/show-cpa-pool-quota.py --json 300")
    #expect(!CPAQuotaSnapshotFetcher.defaultRemoteCommand.contains("/home/ubuntu/Qin/cpa/bin/"))
}

@Test
func cpaQuotaSnapshotFetcherDefaultTimeoutCoversServerBridgeTimeout() {
    #expect(CPAQuotaSnapshotFetcher.defaultTimeout == 15)
}
