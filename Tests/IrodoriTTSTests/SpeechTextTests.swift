import XCTest
@testable import IrodoriTTS

final class SpeechTextTests: XCTestCase {
    func testJapaneseTypographyAndMarkdown() {
        XCTAssertEqual(SpeechText.prepare("**様々**な方法で「確認」（テスト）します。"), "様々な方法で確認、テスト、します。")
        XCTAssertEqual(SpeechText.prepare("[公式サイト](https://example.com/a_(b))も見てください。"), "公式サイトも見てください。")
        XCTAssertEqual(SpeechText.prepare("詳細は https://example.com。次の話です。"), "詳細は リンク。次の話です。")
        XCTAssertEqual(SpeechText.prepare("１２３とﾃｽﾄ、色々な人々。"), "１２３とﾃｽﾄ、色々な人々。")
        XCTAssertEqual(SpeechText.prepare("# 説明\n- **最初**です。\n```swift\nprint(1)\n```\n次です。"), "説明 最初です。 次です。")
        XCTAssertEqual(SpeechText.prepare("😊✨"), "")
    }
    func testLongDocumentIsNotSilentlyTruncated() {
        let text = String(repeating: "これは長い文章です。", count: 100)
        XCTAssertEqual(SpeechText.prepare(text), text)
        XCTAssertEqual(SpeechText.sentences(text).count, 100)
    }
    func testBisectionPreservesEveryCharacter() {
        let text = "今日は散歩をして、帰ったら温かいご飯を作ります。"
        XCTAssertEqual(SpeechText.bisect(text)?.joined(), text)
    }
    func testUnsafePathsAreRejected() {
        let root = URL(fileURLWithPath: "/tmp/models")
        for path in ["../voice.wav", "/outside", "x/../../y", "a//b", "https://example.com", "a\\b"] {
            XCTAssertThrowsError(try ModelBundle.safeURL(path, under: root))
        }
        XCTAssertNoThrow(try ModelBundle.safeURL("text_encoder.mlpackage/Manifest.json", under: root))
    }
    func testWAVHeaderAndSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = Data([0, 0, 255, 127, 0, 128])
        try ReferenceAudio.writeWAV(pcm16: pcm, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + pcm.count)
        XCTAssertEqual(data.suffix(pcm.count), pcm)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
    }
}
