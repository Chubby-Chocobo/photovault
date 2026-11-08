import Testing
@testable import PhotoVaultAppSupport

@Test func appSupportModuleNameIsStable() {
    #expect(PhotoVaultAppSupportModule.name == "PhotoVaultAppSupport")
}
