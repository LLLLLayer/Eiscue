import Foundation
import Testing
@testable import EiscueDeviceBackend

#if DEBUG
@Suite struct MediaSessionDiagnosticTests {
    @Test func exportsOnlyValidatedCompleteOrFailedQueryMetadata() throws {
        let summary = complete()
        let bytes = try NCMMediaSessionDiagnostic(data: data(summary)).record(startedAt: 100, elapsedSeconds: 0.2)
        let record = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let exported = try #require(record["summary"] as? [String: Any])
        #expect(exported["sessionUUIDMatchCount"] as? Int == 1)
        #expect(exported["clientSessionPairMatchCount"] as? Int == 1)
        #expect(exported["opaqueDataPresent"] as? Bool == false)
        var failed = summary
        for key in ["rootIsDictionary", "serverInfoPresent", "serverInfoIsDictionary", "sessionsPresent", "sessionsIsArray", "sessionCount", "opaqueDataPresent", "sessionUUIDMatchCount", "callUUIDMatchCount", "streamConfigCount", "localSSRCFieldCount", "remoteSSRCFieldCount", "streamPairMatchCount", "correlatedSessionMatchCount", "clientSessionPairMatchCount"] { failed[key] = NSNull() }
        failed.merge(["querySucceeded": false, "queryTimedOut": true, "failureStage": 10, "failureCause": 2,
            "scanComplete": false, "visitedNodeCount": 0, "visitedByteCount": 0]) { _, new in new }
        _ = try NCMMediaSessionDiagnostic(data: data(failed))
    }

    @Test func rejectsUnknownFieldsStringsInvalidTypesAndOutOfBoundsCounts() throws {
        let mutations: [(String, Any)] = [("peerName", "PRIVATE-SENTINEL"), ("sessionUUIDMatchCount", "PRIVATE-SENTINEL"),
            ("querySucceeded", 1), ("sessionCount", true), ("visitedByteCount", 1_048_577),
            ("streamPairMatchCount", 4097), ("clientSessionPairMatchCount", "PRIVATE-SENTINEL"), ("callUUIDMatchCount", 0.5), ("version", 2)]
        for (key, value) in mutations {
            var invalid = complete(); invalid[key] = value
            #expect(throws: NativeBackendError.malformedEvent) { try NCMMediaSessionDiagnostic(data: data(invalid)) }
        }
        var missing = complete(); missing.removeValue(forKey: "callUUIDMatchCount")
        #expect(throws: NativeBackendError.malformedEvent) { try NCMMediaSessionDiagnostic(data: data(missing)) }
    }

    @Test func incompleteScansCannotExportPartialMatches() throws {
        var truncated = complete(); truncated["truncated"] = true; truncated["scanComplete"] = false
        #expect(throws: NativeBackendError.malformedEvent) { try NCMMediaSessionDiagnostic(data: data(truncated)) }
        for key in ["sessionCount", "opaqueDataPresent", "sessionUUIDMatchCount", "callUUIDMatchCount", "streamConfigCount", "localSSRCFieldCount", "remoteSSRCFieldCount", "streamPairMatchCount", "correlatedSessionMatchCount", "clientSessionPairMatchCount"] { truncated[key] = NSNull() }
        _ = try NCMMediaSessionDiagnostic(data: data(truncated))
    }

    @Test func readOnlyRefusalsExcludeLossAndUnknownDeliveryAndReplaceStaleSummary() throws {
        #expect(NCMMediaSessionDiagnostic.isRefusal(stage: 10, cause: 5))
        #expect(NCMMediaSessionDiagnostic.isRefusal(stage: 10, cause: 6))
        let rejected: [(UInt32, UInt32)] = [(12, 6), (10, 7), (10, 2), (11, 6)]
        for (stage, cause) in rejected {
            #expect(!NCMMediaSessionDiagnostic.isRefusal(stage: stage, cause: cause))
        }
        let bytes = try NCMMediaSessionDiagnostic.issueRecord(startedAt: 100, elapsedSeconds: 0.2, refusal: (10, 6))
        let record = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(record["refused"] as? Bool == true)
        #expect(record["summary"] is NSNull)
    }

    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func complete() -> [String: Any] {
        ["version": 1, "querySucceeded": true, "queryTimedOut": false, "failureStage": NSNull(), "failureCause": NSNull(),
         "mediaHealthy": true, "rootIsDictionary": true, "serverInfoPresent": false, "serverInfoIsDictionary": false,
         "sessionsPresent": true, "sessionsIsArray": true, "sessionCount": 1, "scanComplete": true, "truncated": false,
         "visitedNodeCount": 12, "visitedByteCount": 140, "opaqueDataPresent": false, "sessionUUIDMatchCount": 1,
         "callUUIDMatchCount": 0, "streamConfigCount": 1, "localSSRCFieldCount": 1, "remoteSSRCFieldCount": 1, "streamPairMatchCount": 1, "correlatedSessionMatchCount": 0, "clientSessionPairMatchCount": 1]
    }
}
#endif
