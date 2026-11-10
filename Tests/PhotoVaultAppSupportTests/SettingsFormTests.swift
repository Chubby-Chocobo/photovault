import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct SettingsFormTests {
    @Test func defaultsAreValid() {
        #expect(SettingsValidator.validate(GlobalSettings()).isEmpty)
    }

    @Test func gigabyteViewsConvertToBytes() {
        var settings = GlobalSettings()
        #expect(settings.backfillGBPerHour == 20)
        #expect(settings.lowWatermarkGB == 15)
        #expect(settings.criticalWatermarkGB == 5)
        #expect(settings.stagingSoftLimitGB == 4)
        settings.lowWatermarkGB = 30
        settings.backfillGBPerHour = 8
        #expect(settings.lowWatermarkBytes == 30 * GlobalSettings.GiB)
        #expect(settings.backfillBytesPerHour == 8 * GlobalSettings.GiB)
        settings.stagingSoftLimitGB = -3
        #expect(settings.stagingSoftLimitBytes == 0)
    }

    @Test func criticalMustStayBelowLow() {
        var settings = GlobalSettings()
        settings.criticalWatermarkGB = 15
        #expect(SettingsValidator.validate(settings) == [.criticalNotBelowLow])
        settings.criticalWatermarkGB = 20
        #expect(SettingsValidator.validate(settings) == [.criticalNotBelowLow])
        settings.criticalWatermarkGB = 14
        #expect(SettingsValidator.validate(settings).isEmpty)
    }

    @Test func rangesAreEnforced() {
        var settings = GlobalSettings()
        settings.backfillGBPerHour = 0
        settings.stagingSoftLimitGB = 0
        settings.integrityCheckIntervalDays = 0
        settings.homeCountryCode = "VNM"
        #expect(Set(SettingsValidator.validate(settings)) == [
            .rateNotPositive, .stagingNotPositive, .integrityIntervalOutOfRange, .invalidHomeCountry,
        ])
        settings = GlobalSettings()
        settings.integrityCheckIntervalDays = 365
        #expect(SettingsValidator.validate(settings).isEmpty)
    }

    @Test func everyIssueHasAMessage() {
        let all: [SettingsIssue] = [
            .criticalNotBelowLow, .rateNotPositive, .stagingNotPositive,
            .integrityIntervalOutOfRange, .invalidHomeCountry,
        ]
        #expect(all.allSatisfy { !$0.message.isEmpty })
    }

    @Test func operatingKnobsDoNotTriggerRecompute() {
        let base = GlobalSettings()
        var changed = base
        changed.lowWatermarkGB = 40
        changed.backfillGBPerHour = 5
        changed.pauseOnExpensiveNetwork = false
        changed.allUploadsOnlyOnACPower = true
        changed.backfillOnlyOnACPower = false
        changed.launchAtLogin = false
        changed.integrityCheckIntervalDays = 30
        changed.stagingSoftLimitGB = 8
        changed.criticalWatermarkGB = 2
        #expect(!SettingsValidator.needsEngineRecompute(from: base, to: changed))
    }

    @Test func contentAndOrganizationChangesTriggerRecompute() {
        let base = GlobalSettings()
        let edits: [(inout GlobalSettings) -> Void] = [
            { $0.includeVideos = false }, { $0.includeEdited = false }, { $0.includeAllBurstFrames = false },
            { $0.includeHidden = true }, { $0.chatAppAlbumNames.append("Kakao") },
            { $0.photosWithoutCameraExifAreSaved = false }, { $0.placeNamesEnabled = false },
            { $0.homeCountryCode = "JP" }, { $0.sidecarJsonEnabled = false }, { $0.sidecarXmpEnabled = false },
            { $0.viewByDeviceEnabled = false }, { $0.viewByPlaceEnabled = false }, { $0.viewFavoritesEnabled = false }, { $0.viewByLensEnabled = true },
        ]
        for edit in edits {
            var changed = base
            edit(&changed)
            #expect(SettingsValidator.needsEngineRecompute(from: base, to: changed))
        }
    }

    @Test func albumNamesAreUniqueIgnoringCase() {
        var albums = ["WhatsApp", "Zalo"]
        #expect(SettingsValidator.addingAlbum(" Kakao ", to: &albums))
        #expect(!SettingsValidator.addingAlbum("zalo", to: &albums))
        #expect(!SettingsValidator.addingAlbum("   ", to: &albums))
        #expect(albums == ["WhatsApp", "Zalo", "Kakao"])
    }
}

struct DestinationRulesEditorTests {
    @Test func globalCeilingLocksRows() {
        var settings = GlobalSettings()
        #expect(RuleKey.allCases.allSatisfy { !RuleEditor.ceilingBlocks($0, settings: settings) })
        settings.includeVideos = false
        settings.includeEdited = false
        settings.sidecarJsonEnabled = false
        settings.sidecarXmpEnabled = false
        let blocked = RuleKey.allCases.filter { RuleEditor.ceilingBlocks($0, settings: settings) }
        #expect(Set(blocked) == [.video, .edited, .sidecarJson, .sidecarXmp])
        let rules = DestinationRules.everything
        #expect(!RuleEditor.isEffective(.video, rules: rules, settings: settings))
        #expect(RuleEditor.isEffective(.photo, rules: rules, settings: settings))
    }

    @Test func rowAccessorsRoundTrip() {
        var rules = DestinationRules.everything
        for key in RuleKey.allCases {
            #expect(rules.isOn(key))
            rules.set(key, false)
            #expect(!rules.isOn(key))
            rules.set(key, true)
            #expect(rules.isOn(key))
        }
        rules.set(.screenshot, false)
        #expect(rules.categories == [.camera, .saved])
    }

    @Test func skipLargeFilesInGigabytes() {
        var rules = DestinationRules.everything
        #expect(rules.skipLargerThanGB == nil)
        rules.skipLargerThanGB = 4
        #expect(rules.skipLargerThanBytes == 4 * GlobalSettings.GiB)
        rules.skipLargerThanGB = 0
        #expect(rules.skipLargerThanGB == 1)
        rules.skipLargerThanGB = nil
        #expect(rules.skipLargerThanBytes == nil)
    }

    @Test func summaryListsEffectiveRows() {
        var rules = DestinationRules.everything
        rules.set(.screenshot, false)
        var settings = GlobalSettings()
        settings.includeEdited = false
        rules.skipLargerThanGB = 4
        let text = RuleEditor.effectiveSummary(rules: rules, settings: settings)
        #expect(text == "Camera + Lưu từ app · Ảnh (gồm video Live Photo) + Video + RAW · Bản gốc · JSON + XMP · bỏ qua > 4 GB")
    }

    @Test func emptyGroupShowsDash() {
        var rules = DestinationRules.everything
        rules.categories = []
        #expect(RuleEditor.effectiveSummary(rules: rules, settings: GlobalSettings()).hasPrefix("— · "))
    }

    @Test func changePreviewDescribesEachEdit() {
        let settings = GlobalSettings()
        var new = DestinationRules.everything
        new.set(.video, false)
        new.set(.raw, false)
        new.skipLargerThanGB = 2
        let lines = RuleEditor.changeLines(
            old: .everything, new: new, oldScope: .full, newScope: .newOnly, settings: settings, counts: [.video: 4110])
        #expect(lines == [
            "Tắt Video → huỷ job còn chờ của ~4.110 asset",
            "Tắt RAW → huỷ job còn chờ",
            "Bỏ qua file > 2 GB → huỷ job còn chờ của file lớn hơn",
            "Đổi phạm vi → mở rộng thì xếp hàng thêm, thu hẹp chỉ huỷ phần chưa upload",
        ])
        #expect(RuleEditor.changeLines(old: new, new: .everything, oldScope: .full, newScope: .full, settings: settings, counts: [.video: 3]) == [
            "Bật Video → xếp hàng thêm ~3 asset", "Bật RAW → xếp hàng thêm", "Không bỏ qua file lớn → xếp hàng lại file đã bỏ qua",
        ])
    }

    @Test func rowsLockedByTheCeilingAreNotListedAsChanges() {
        var settings = GlobalSettings()
        settings.includeVideos = false
        var new = DestinationRules.everything
        new.set(.video, false)
        #expect(RuleEditor.changeLines(old: .everything, new: new, oldScope: .full, newScope: .full, settings: settings).isEmpty)
    }
}

@Suite struct SettingsSavableTests {
    @Test func aValidToggleIsSavedWhileAnotherFieldIsInvalid() {
        let persisted = GlobalSettings()
        var edited = persisted
        edited.integrityCheckIntervalDays = 0
        edited.sidecarJsonEnabled = false
        let saved = SettingsValidator.savable(edited, persisted: persisted)
        #expect(saved.sidecarJsonEnabled == false)
        #expect(saved.integrityCheckIntervalDays == persisted.integrityCheckIntervalDays)
        #expect(SettingsValidator.validate(saved).isEmpty)
    }

    @Test func bothWatermarksStayTogetherWhenTheirOrderIsWrong() {
        let persisted = GlobalSettings()
        var edited = persisted
        edited.lowWatermarkGB = 1
        edited.criticalWatermarkGB = 5
        edited.homeCountryCode = "X"
        edited.placeNamesEnabled = false
        let saved = SettingsValidator.savable(edited, persisted: persisted)
        #expect(saved.lowWatermarkBytes == persisted.lowWatermarkBytes && saved.criticalWatermarkBytes == persisted.criticalWatermarkBytes)
        #expect(saved.homeCountryCode == persisted.homeCountryCode)
        #expect(saved.placeNamesEnabled == false)
    }

    @Test func aValidEditIsSavedAsIs() {
        var edited = GlobalSettings()
        edited.includeVideos = false
        #expect(SettingsValidator.savable(edited, persisted: GlobalSettings()) == edited)
    }
}
