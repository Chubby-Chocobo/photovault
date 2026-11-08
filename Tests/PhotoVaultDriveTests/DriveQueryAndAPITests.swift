import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

@Suite struct DriveQueryTests {
    @Test func escapesBackslashAndQuote() {
        #expect(DriveQuery.literal(#"it's a \ b"#) == #"'it\'s a \\ b'"#)
        #expect(DriveQuery.all.name(#"x' or name='y"#).q == #"name='x\' or name=\'y'"#)
    }

    @Test func buildsAppListingQuery() {
        let q = DriveQuery.all.appCreated.notTrashed.parent("P1").q
        #expect(q == "appProperties has { key='pvSchema' and value='1' } and trashed=false and 'P1' in parents")
    }

    @Test func escapesAppPropertyLiterals() {
        #expect(DriveQuery.all.appProperty("k'", #"v\"#).q == #"appProperties has { key='k\'' and value='v\\' }"#)
    }

    @Test func fakeServerParsesWhatTheBuilderProduces() {
        let q = DriveQuery.all.appCreated.notTrashed.parent("a'b").name(#"n\m"#).mimeType(DriveMime.folder).q
        #expect(QueryParser.parse(q)?.count == 5)
    }
}

private func api(_ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse) -> (DriveAPI, StubTransport) {
    let transport = StubTransport(handler)
    return (DriveAPI(transport: transport, auth: StaticAuth()), transport)
}

private nonisolated(unsafe) let fileJSON: [String: Any] = ["id": "F1", "name": "n", "mimeType": "image/heic", "parents": ["P"], "trashed": false,
                                       "md5Checksum": "abc", "size": "12", "appProperties": ["pvSchema": "1"]]

@Suite struct DriveAPIRequestTests {
    @Test func generateIdsShape() async throws {
        let (client, transport) = api { _ in .json(200, ["ids": ["a", "b"]]) }
        #expect(try await client.generateIds(count: 2, kind: .shortcuts) == ["a", "b"])
        let r = transport.requests[0]
        #expect(r.method == "GET" && r.url.path == "/drive/v3/files/generateIds")
        #expect(r.query["count"] == "2" && r.query["space"] == "drive" && r.query["type"] == "shortcuts")
        #expect(r.headers["Authorization"] == "Bearer static-token")
    }

    @Test func generateIdsBatchesAt1000() async throws {
        let (client, transport) = api { r in
            let n = Int(r.query["count"]!)!
            return .json(200, ["ids": (0..<n).map { "i\($0)-\(r.query["count"]!)" }])
        }
        #expect(try await client.generateIds(count: 1500, kind: .files).count == 1500)
        #expect(transport.requests.map { $0.query["count"] } == ["1000", "500"])
    }

    @Test func createShape() async throws {
        let (client, transport) = api { _ in .json(200, fileJSON) }
        _ = try await client.create(DriveFileWrite(id: "F1", name: "Day", mimeType: DriveMime.folder, parents: ["P"],
                                                   appProperties: ["pvSchema": "1"], description: "d"))
        let r = transport.requests[0]
        #expect(r.method == "POST" && r.url.path == "/drive/v3/files")
        #expect(r.query["fields"] == "id,name,md5Checksum,trashed,parents,size,appProperties,shortcutDetails,mimeType")
        #expect(r.json["id"] as? String == "F1" && r.json["mimeType"] as? String == DriveMime.folder)
        #expect(r.json["parents"] as? [String] == ["P"] && r.json["description"] as? String == "d")
        #expect(r.json["trashed"] == nil)
        #expect(r.headers["Content-Type"]?.hasPrefix("application/json") == true)
    }

    @Test func getAndUpdateShapes() async throws {
        let (client, transport) = api { _ in .json(200, fileJSON) }
        let file = try await client.get("F/1")
        #expect(file.remoteItem.size == 12 && file.remoteItem.md5 == "abc")
        _ = try await client.update("F1", DriveFileWrite(name: "x", trashed: true), addParents: ["B"], removeParents: ["A"])
        #expect(transport.requests[0].url.absoluteString.contains("/drive/v3/files/F%2F1?"))
        let u = transport.requests[1]
        #expect(u.method == "PATCH" && u.query["addParents"] == "B" && u.query["removeParents"] == "A")
        #expect(u.query["fields"]?.contains("md5Checksum") == true)
        #expect(u.json["trashed"] as? Bool == true && u.json["name"] as? String == "x")
    }

    @Test func listPagesAndEscapesQuery() async throws {
        let (client, transport) = api { r in
            r.query["pageToken"] == nil ? .json(200, ["files": [fileJSON], "nextPageToken": "T2"]) : .json(200, ["files": []])
        }
        let query = DriveQuery.all.appCreated.notTrashed.parent("a'b&c+d")
        let first = try await client.listPage(query, pageToken: nil)
        let second = try await client.listPage(query, pageToken: first.nextPageToken)
        #expect(first.files.count == 1 && second.files.isEmpty)
        let r = transport.requests[0]
        #expect(r.query["q"] == query.q && r.query["q"]!.contains(#"'a\'b&c+d' in parents"#))
        #expect(r.url.absoluteString.contains("%26") && r.url.absoluteString.contains("%2B"))
        #expect(r.query["fields"]?.hasPrefix("nextPageToken,files(") == true)
        #expect(transport.requests[1].query["pageToken"] == "T2")
    }

    @Test func quota() async throws {
        let (client, transport) = api { _ in .json(200, ["storageQuota": ["limit": "1000", "usage": "250"]]) }
        #expect(try await client.quota() == Quota(totalBytes: 1000, usedBytes: 250, availableBytes: 750))
        #expect(transport.requests[0].query["fields"] == "storageQuota")
        let (unlimited, _) = api { _ in .json(200, ["storageQuota": ["usage": "5"]]) }
        #expect(try await unlimited.quota() == Quota(totalBytes: nil, usedBytes: 5, availableBytes: nil))
    }

    @Test func createConflictBecomesAlreadyExists() async throws {
        let (client, _) = api { _ in .json(409, ["error": ["errors": [["reason": "duplicate"]]]]) }
        await #expect(throws: DestinationError.alreadyExists(remoteId: "F1")) { try await client.create(DriveFileWrite(id: "F1")) }
    }

    @Test func errorMapping() async throws {
        let cases: [(Int, String, [String: String], DestinationError)] = [
            (404, "notFound", [:], .notFound),
            (403, "storageQuotaExceeded", [:], .quotaExceeded),
            (403, "userRateLimitExceeded", ["Retry-After": "7"], .rateLimited(retryAfter: 7)),
            (429, "rateLimitExceeded", [:], .rateLimited(retryAfter: nil)),
            (503, "backendError", [:], .server(status: 503)),
        ]
        for (status, reason, headers, expected) in cases {
            let (client, _) = api { _ in StubResponse.json(status, ["error": ["errors": [["reason": reason]]]], headers: headers) }
            await #expect(throws: expected) { try await client.get("x") }
        }
    }

    @Test func networkErrorsMapToOffline() async throws {
        let (client, _) = api { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: DestinationError.offline) { try await client.get("x") }
    }
}
