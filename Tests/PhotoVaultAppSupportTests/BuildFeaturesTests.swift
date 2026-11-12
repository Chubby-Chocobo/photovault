import Testing
@testable import PhotoVaultAppSupport

struct BuildFeaturesTests {
    @Test(arguments: ["YES", "yes", "Yes", "1", "true", "TRUE", " YES "])
    func explicitYesIsOn(_ value: String) {
        #expect(BuildFeatures.isOn(value))
    }

    @Test(arguments: ["NO", "no", "0", "false", "", "  ", "$(GOOGLE_DRIVE_BROWSER_IMPORT)", "maybe"])
    func everythingElseIsOff(_ value: String) {
        #expect(!BuildFeatures.isOn(value))
    }

    @Test func boolValuesPassThrough() {
        #expect(BuildFeatures.isOn(true))
        #expect(!BuildFeatures.isOn(false))
    }

    @Test func browserImportNeedsClientIDAndFlag() {
        #expect(BuildFeatures.googleBrowserImportEnabled(clientID: "id", flag: true))
        #expect(!BuildFeatures.googleBrowserImportEnabled(clientID: "id", flag: false))
        #expect(!BuildFeatures.googleBrowserImportEnabled(clientID: "", flag: true))
        #expect(!BuildFeatures.googleBrowserImportEnabled(clientID: "  ", flag: true))
    }

    @Test func missingOrOtherTypesAreOff() {
        #expect(!BuildFeatures.isOn(nil))
        #expect(!BuildFeatures.isOn(1))
        #expect(!BuildFeatures.isOn(["YES"]))
    }
}
