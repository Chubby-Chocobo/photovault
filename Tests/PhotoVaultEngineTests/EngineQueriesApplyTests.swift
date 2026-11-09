import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import Testing
@testable import PhotoVaultEngine

@Suite struct EngineQueriesApplyTests {
    private let key = AssetKey.local("1")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(states: [JobState]) throws -> Store {
        let store = try Store.inMemory()
        try store.write { db in
            for (index, state) in states.enumerated() {
                let destination = index == 0 ? DestinationID.googleDrive : DestinationID.local()
                try db.execute(sql: """
                    INSERT INTO upload_job (destination_id, asset_key, res_type, kind, origin, state, updated_at)
                    VALUES (?, ?, ?, 'original', 'incremental', ?, ?)
                    """, arguments: [destination.rawValue, key.rawValue, ResourceType.photo.rawValue, state.rawValue, now])
            }
        }
        return store
    }

    @Test func invalidTransitionsAreSkipped() async throws {
        let store = try store(states: [.pending, .done])
        try await store.write { [key, now] db in
            try EngineQueries.apply(db, .cancel, key: key, type: .photo, states: [.pending, .done], now: now)
        }
        let states = try await store.read { db in try JobRepository.fetchAll(db, assetKey: AssetKey.local("1")).map(\.state) }
        #expect(Set(states) == [.cancelled, .done])
    }

    @Test func databaseErrorsReachTheCaller() async throws {
        let store = try store(states: [.pending])
        try await store.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse BEFORE UPDATE ON upload_job BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        await #expect(throws: DatabaseError.self) {
            try await store.write { [key, now] db in
                try EngineQueries.apply(db, .cancel, key: key, type: .photo, states: [.pending], now: now)
            }
        }
    }
}
