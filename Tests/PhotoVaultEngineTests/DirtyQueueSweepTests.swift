import Foundation
import PhotoVaultCore
import PhotoVaultStore
import Testing
@testable import PhotoVaultEngine

@Suite struct DirtyQueueSweepTests {
    @Test func aNewSweepRequestRestartsARunningSweep() throws {
        let store = try Store.inMemory()
        try store.write { db in
            try DirtyQueue.requestSweep(db, [.view])
            try DirtyQueue.setSweepCursor(db, .view, "local:m-500")
            #expect(try DirtyQueue.sweepCursor(db, .view) == "local:m-500")
            try DirtyQueue.requestSweep(db, [.view])
            #expect(try DirtyQueue.sweepCursor(db, .view) == "")
        }
    }
}
