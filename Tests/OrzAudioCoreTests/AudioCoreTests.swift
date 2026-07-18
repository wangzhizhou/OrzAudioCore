import Testing
@testable import OrzAudioCore

@Test func exposesVersionedABIAndBuiltinFormats() {
    #expect(AudioDecoder.abiVersion == 0x0001_0000)
    let formats = Set(AudioDecoder.supportedFormats.map(\.id))
    #expect(formats.isSuperset(of: ["ym", "mid", "bp"]))
    #expect(!AudioDecoder.buildInfo.isEmpty)
    #expect(!AudioDecoder.cacheFingerprint.isEmpty)
}
