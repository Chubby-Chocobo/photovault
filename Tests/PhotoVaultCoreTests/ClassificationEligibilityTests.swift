import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct ClassificationTests {
    let settings = GlobalSettings()

    func classify(_ media: MediaType = .image, _ subtypes: MediaSubtypes = [], raw: Bool = false, albums: [String] = [],
                  header: CaptureMetadata? = nil) -> ClassificationResult {
        CategoryClassifier.classify(mediaType: media, subtypes: subtypes, hasRaw: raw, albumTitles: albums,
                                    settings: settings, headerMetadata: header)
    }

    @Test func screenshotsWinOverChatAlbums() {
        let r = classify(.image, .photoScreenshot, albums: ["Zalo"])
        #expect(r.category == .screenshot && !r.provisional)
        #expect(classify(.video, .videoScreenRecording).category == .screenshot)
    }

    @Test func chatAlbumNeedsExactMatch() {
        #expect(classify(albums: ["  zalo "]).category == .saved)
        #expect(classify(albums: ["Zalo backup"], header: CaptureMetadata(make: "Apple")).category == .camera)
    }

    @Test func rule3OnlyForPhotosWithoutRaw() {
        #expect(classify(header: .empty).category == .saved)
        #expect(classify(header: CaptureMetadata(model: "iPhone 16")).category == .camera)
        #expect(classify(.video, header: .empty).category == .camera, "drone videos never go to Saved")
        #expect(classify(raw: true).category == .camera)
        let pending = classify()
        #expect(pending.category == .camera && pending.provisional && pending.reason == .pendingHeaderRead)
    }

    @Test func rule3CanBeDisabled() {
        var s = GlobalSettings()
        s.photosWithoutCameraExifAreSaved = false
        let r = CategoryClassifier.classify(mediaType: .image, subtypes: [], hasRaw: false, albumTitles: [], settings: s, headerMetadata: nil)
        #expect(r.category == .camera && !r.provisional)
    }
}

@Suite struct EligibilityTests {
    let tz = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    let baseline = Date(timeIntervalSince1970: 1_800_000_000)

    func asset(inserted: Date? = nil, created: Date, category: AssetCategory = .camera, hidden: Bool = false) -> AssetRecord {
        AssetRecord(assetKey: .local(UUID().uuidString), localId: "x", creationDate: created, mediaType: .image,
                    category: category, isHidden: hidden, insertedAt: inserted, firstSeenAt: baseline, lastSeenAt: baseline)
    }

    func destination(_ scope: ScopeMode, baseline: Date? = nil, categories: Set<AssetCategory> = Set(AssetCategory.allCases)) -> DestinationRecord {
        var rules = DestinationRules()
        rules.categories = categories
        return DestinationRecord(id: .googleDrive, displayName: "Drive", statusSince: self.baseline, scope: scope,
                                 baselineAt: baseline ?? self.baseline, rules: rules, createdAt: self.baseline)
    }

    @Test func newOnlySkipsOldPhotosAndTakesNewOnes() {
        let old = asset(created: baseline.addingTimeInterval(-86_400 * 100))
        let new = asset(inserted: baseline.addingTimeInterval(10), created: baseline.addingTimeInterval(10))
        let importedOld = asset(inserted: baseline.addingTimeInterval(20), created: baseline.addingTimeInterval(-86_400 * 3000))
        let d = destination(.newOnly)
        #expect(!Eligibility.inScope(old, d, archiveTimeZone: tz))
        #expect(Eligibility.inScope(new, d, archiveTimeZone: tz))
        #expect(Eligibility.inScope(importedOld, d, archiveTimeZone: tz), "T5: old photo imported after the baseline is uploaded")
    }

    @Test func sinceUsesArchiveDayOrWindow() {
        let since = ArchiveDay(date: baseline.addingTimeInterval(-86_400 * 30), timeZone: tz)
        let d = destination(.since(since))
        #expect(Eligibility.inScope(asset(created: baseline.addingTimeInterval(-86_400 * 10)), d, archiveTimeZone: tz))
        #expect(!Eligibility.inScope(asset(created: baseline.addingTimeInterval(-86_400 * 40)), d, archiveTimeZone: tz))
        #expect(Eligibility.inScope(asset(inserted: baseline.addingTimeInterval(5), created: baseline.addingTimeInterval(-86_400 * 400)), d, archiveTimeZone: tz))
    }

    @Test func destinationAddedLaterWithNewOnlyGetsOnlyLaterAssets() {
        let nasBaseline = baseline.addingTimeInterval(86_400)
        let nas = destination(.newOnly, baseline: nasBaseline)
        let beforeNas = asset(inserted: baseline.addingTimeInterval(100), created: baseline.addingTimeInterval(100))
        let afterNas = asset(inserted: nasBaseline.addingTimeInterval(100), created: nasBaseline.addingTimeInterval(100))
        #expect(!Eligibility.inScope(beforeNas, nas, archiveTimeZone: tz), "T27c")
        #expect(Eligibility.inScope(afterNas, nas, archiveTimeZone: tz))
    }

    @Test func deletedHiddenAndRulesExclude() {
        var deleted = asset(created: baseline)
        deleted.deletedAt = baseline
        let settings = GlobalSettings()
        #expect(!Eligibility.isEligible(deleted, destination(.full), settings: settings, archiveTimeZone: tz))
        #expect(!Eligibility.isEligible(asset(created: baseline, hidden: true), destination(.full), settings: settings, archiveTimeZone: tz))
        #expect(!Eligibility.isEligible(asset(created: baseline, category: .screenshot), destination(.full, categories: [.camera, .saved]), settings: settings, archiveTimeZone: tz))
        var provisional = asset(created: baseline)
        provisional.categoryProvisional = true
        #expect(!Eligibility.isEligible(provisional, destination(.full), settings: settings, archiveTimeZone: tz))
        #expect(Eligibility.needsClassification(provisional, destinations: [destination(.full, categories: [.saved])], settings: settings, archiveTimeZone: tz))
        #expect(!Eligibility.needsClassification(provisional, destinations: [destination(.full, categories: [.screenshot])], settings: settings, archiveTimeZone: tz))
    }

    @Test func burstFramesFollowSetting() {
        var frame = asset(created: baseline)
        frame.burstIdentifier = "b"
        frame.burstIsPick = false
        var s = GlobalSettings()
        #expect(Eligibility.passesGlobalAssetSettings(frame, s))
        s.includeAllBurstFrames = false
        #expect(!Eligibility.passesGlobalAssetSettings(frame, s))
    }
}

@Suite struct ResourcePlannerTests {
    let heic = ResourceDescriptor(type: .photo, uti: "public.heic", originalFilename: "IMG_1.HEIC", isRaw: false)
    let live = ResourceDescriptor(type: .pairedVideo, uti: "com.apple.quicktime-movie", originalFilename: "IMG_1.MOV", isRaw: false)
    let edited = ResourceDescriptor(type: .fullSizePhoto, uti: "public.heic", originalFilename: "FullSizeRender.heic", isRaw: false)
    let adj = ResourceDescriptor(type: .adjustmentData, uti: "com.apple.photos.adjustment", originalFilename: "Adjustments.plist", isRaw: false)
    let jpg = ResourceDescriptor(type: .photo, uti: "public.jpeg", originalFilename: "DSC1.JPG", isRaw: false)
    let arw = ResourceDescriptor(type: .alternatePhoto, uti: "com.sony.arw-raw-image", originalFilename: "DSC1.ARW", isRaw: true)

    @Test func defaultPlanSkipsAdjustmentData() {
        let planned = ResourcePlanner.plannedTypes(for: [heic, live, edited, adj], mediaType: .image, settings: GlobalSettings(), rules: .everything)
        #expect(planned == [.photo, .fullSizePhoto, .pairedVideo])
    }

    @Test func rawPairPrimaryAndRules() {
        #expect(ResourcePlanner.primary(of: [jpg, arw])?.type == .alternatePhoto)
        var noRaw = DestinationRules()
        noRaw.includeRaw = false
        let planned = ResourcePlanner.plannedTypes(for: [jpg, arw], mediaType: .image, settings: GlobalSettings(), rules: noRaw)
        #expect(planned == [.photo])
        #expect(ResourcePlanner.viewTarget(of: [jpg, arw], planned: planned) == .photo, "T27b: Drive without RAW targets the JPEG")
    }

    @Test func globalCeilingAndsWithRules() {
        var s = GlobalSettings()
        s.includeEdited = false
        #expect(ResourcePlanner.plannedTypes(for: [heic, edited], mediaType: .image, settings: s, rules: .everything) == [.photo])
        var originalsOnly = DestinationRules()
        originalsOnly.includeEdited = false
        originalsOnly.sidecarXmp = false
        #expect(ResourcePlanner.plannedSidecars(settings: GlobalSettings(), rules: originalsOnly, hasPlannedResources: true) == [.sidecarJson])
        #expect(ResourcePlanner.plannedSidecars(settings: GlobalSettings(), rules: .everything, hasPlannedResources: false).isEmpty)
    }
}
