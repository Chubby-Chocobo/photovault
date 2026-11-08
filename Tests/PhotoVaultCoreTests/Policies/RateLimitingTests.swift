import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct RateLimitingTests {
    let t0 = PolicyFixtures.t0

    func consume(_ bucket: inout TokenBucket, _ bytes: Int64, _ lane: TokenBucket.Lane = .upload, at date: Date) -> Bool {
        bucket.tryConsume(bytes: bytes, lane: lane, at: date)
    }

    @Test func backoffCeilingDoublesAndCapsAtThirtyMinutes() {
        let backoff = Backoff()
        #expect(backoff.ceiling(forAttempt: 0) == 1)
        #expect(backoff.ceiling(forAttempt: 1) == 2)
        #expect(backoff.ceiling(forAttempt: 5) == 32)
        #expect(backoff.ceiling(forAttempt: 11) == 1800)
        #expect(backoff.ceiling(forAttempt: 500) == 1800)
        #expect(backoff.ceiling(forAttempt: -3) == 1)
    }

    @Test func backoffJitterStaysWithinBoundsAndVaries() {
        let backoff = Backoff()
        var generator = PolicyFixtures.SeededGenerator(state: 42)
        var seen = Set<Double>()
        for attempt in 0..<40 {
            let delay = backoff.delay(forAttempt: attempt, using: &generator)
            #expect(delay >= 0 && delay <= backoff.ceiling(forAttempt: attempt))
            seen.insert(delay)
        }
        #expect(seen.count > 30)
        var first = PolicyFixtures.SeededGenerator(state: 7)
        var second = PolicyFixtures.SeededGenerator(state: 7)
        #expect(backoff.delay(forAttempt: 3, using: &first) == backoff.delay(forAttempt: 3, using: &second))
    }

    @Test func bucketRefillsOverTimeUpToCapacity() {
        var bucket = TokenBucket(capacity: 3600, refillPerHour: 3600)
        #expect(consume(&bucket, 3600, .upload, at: t0))
        #expect(!consume(&bucket, 1, .upload, at: t0))
        #expect(consume(&bucket, 100, .upload, at: t0.addingTimeInterval(100)))
        #expect(!consume(&bucket, 1, .upload, at: t0.addingTimeInterval(100)))
        #expect(bucket.available(at: t0.addingTimeInterval(100 + 100_000)) == 3600)
    }

    @Test func timeUntilAvailableMatchesRefillRate() {
        var bucket = TokenBucket(capacity: 3600, refillPerHour: 3600)
        _ = bucket.tryConsume(bytes: 3600, at: t0)
        #expect(bucket.timeUntilAvailable(bytes: 600, at: t0) == 600)
        #expect(bucket.timeUntilAvailable(bytes: 600, at: t0.addingTimeInterval(600)) == 0)
        let stalled = TokenBucket(capacity: 10, refillPerHour: 0)
        var drained = stalled
        _ = drained.tryConsume(bytes: 10, at: t0)
        #expect(drained.timeUntilAvailable(bytes: 1, at: t0) == nil)
    }

    @Test func failedConsumeLeavesBucketUntouched() {
        var bucket = TokenBucket(capacity: 100, refillPerHour: 0)
        #expect(!consume(&bucket, 101 * 2, .metadata, at: t0))
        #expect(bucket.available(at: t0) == 100)
    }

    @Test func uploadsBeatMetadataWhenBucketIsLow() {
        var bucket = TokenBucket(capacity: 1000, refillPerHour: 3600, metadataReserveFraction: 0.5)
        #expect(consume(&bucket, 500, .metadata, at: t0))
        #expect(!consume(&bucket, 1, .metadata, at: t0))
        #expect(consume(&bucket, 500, .upload, at: t0))
        #expect(bucket.timeUntilAvailable(bytes: 100, lane: .metadata, at: t0) == 600)
        #expect(bucket.timeUntilAvailable(bytes: 100, lane: .upload, at: t0) == 100)
        #expect(bucket.timeUntilAvailable(bytes: 600, lane: .metadata, at: t0) == nil)
    }

    @Test func oversizedUploadNeedsFullBucketThenGoesIntoDebt() {
        var bucket = TokenBucket(capacity: 100, refillPerHour: 3600)
        #expect(consume(&bucket, 10, .upload, at: t0))
        #expect(!consume(&bucket, 250, .upload, at: t0))
        #expect(consume(&bucket, 250, .upload, at: t0.addingTimeInterval(10)))
        #expect(bucket.available(at: t0.addingTimeInterval(10)) < 0)
    }

    @Test func rollingCapWindowEdges() {
        var cap = RollingByteCap(limit: 100, window: 86_400)
        cap.record(bytes: 60, at: t0)
        cap.record(bytes: 40, at: t0.addingTimeInterval(3600))
        #expect(cap.usage(at: t0.addingTimeInterval(3600)) == 100)
        #expect(!cap.allows(bytes: 1, at: t0.addingTimeInterval(3600)))
        #expect(cap.usage(at: t0.addingTimeInterval(86_399)) == 100)
        #expect(cap.usage(at: t0.addingTimeInterval(86_400)) == 40)
        #expect(cap.allows(bytes: 60, at: t0.addingTimeInterval(86_400)))
        #expect(cap.usage(at: t0.addingTimeInterval(3600 + 86_400)) == 0)
    }

    @Test func rollingCapNextAvailableAndDefaults() {
        var cap = RollingByteCap(limit: 100, window: 100)
        cap.record(bytes: 70, at: t0)
        cap.record(bytes: 30, at: t0.addingTimeInterval(50))
        #expect(cap.nextAvailable(bytes: 10, at: t0.addingTimeInterval(60)) == t0.addingTimeInterval(100))
        #expect(cap.nextAvailable(bytes: 80, at: t0.addingTimeInterval(60)) == t0.addingTimeInterval(150))
        #expect(cap.nextAvailable(bytes: 101, at: t0) == nil)
        #expect(RollingByteCap().limit == 700_000_000_000)
        #expect(RollingByteCap().window == 86_400)
    }
}
