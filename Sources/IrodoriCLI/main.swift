import Foundation
import CryptoKit
import IrodoriTTS

private struct BenchmarkCase: Decodable { let name: String; let text: String }
private final class CollectedPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes) }
    func equals(_ bytes: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return data == bytes }
}

@main struct CLI {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }; return args[i + 1]
        }
        if args.isEmpty || args.contains("--help") {
            print("""
            irodori synthesize --models DIR --text TEXT --output FILE.wav [--reference FILE.wav] [--caption TEXT] [--repeat N] [--report FILE.json] [--raw]
            irodori benchmark --models DIR --cases FILE.json --output-directory DIR --report FILE.json [--reference FILE.wav] [--repeat N]
            irodori verify --models DIR
            irodori download --manifest HTTPS_URL_PINNED_TO_COMMIT --destination DIR
            Diagnostic native flags: --irodori-fixed-seed --irodori-seed 11 --irodori-diagnostics
            --raw bypasses document formatting/splitting for exact engine comparisons. Benchmark always uses raw text.
            """)
            return
        }
        if args[0] == "download", let url = value("--manifest").flatMap(URL.init(string:)), let path = value("--destination") {
            try await ModelDownloader().download(manifestURL: url, to: URL(fileURLWithPath: path)) {
                done, total, name in print("[\(done)/\(total)] \(name)")
            }; return
        }
        guard let model = value("--models") else { throw IrodoriError.invalid("--models DIR is required") }
        let modelURL = URL(fileURLWithPath: model)
        if args[0] == "verify" { try ModelBundle.validate(at: modelURL, verifyHashes: true); print("All model files verified"); return }
        let benchmark = args[0] == "benchmark"
        let cases: [BenchmarkCase]
        if benchmark, let file = value("--cases"), value("--report") != nil, value("--output-directory") != nil {
            cases = try JSONDecoder().decode([BenchmarkCase].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            guard !cases.isEmpty, cases.count <= 100 else { throw IrodoriError.invalid("Use 1–100 benchmark cases") }
        } else if args[0] == "synthesize", let text = value("--text"), value("--output") != nil {
            cases = [BenchmarkCase(name: "synthesis", text: text)]
        } else { throw IrodoriError.invalid("Use --help for usage") }
        let repeats = Int(value("--repeat") ?? "1") ?? 0
        guard (1...100).contains(repeats) else { throw IrodoriError.invalid("--repeat must be between 1 and 100") }
        if let directory = value("--output-directory"), benchmark {
            let url = URL(fileURLWithPath: directory)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw IrodoriError.invalid("Benchmark output directory already exists") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let engine = IrodoriEngine()
        let loadMs = try await engine.prepare(modelDirectory: modelURL)
        let registration = try await engine.registerReference(value("--reference").map { URL(fileURLWithPath: $0) })
        var runs: [[String: Any]] = []
        for pass in 0..<repeats {
            for (index, item) in cases.enumerated() {
                let collected = CollectedPCM()
                let result = try await engine.synthesize(item.text, caption: value("--caption") ?? "", rawText: benchmark || args.contains("--raw")) { collected.append($0.pcm16) }
                let matches = collected.equals(result.pcm16)
                guard matches else { throw IrodoriError.invalid("Stream differs from completed PCM") }
                if benchmark {
                    let url = URL(fileURLWithPath: value("--output-directory")!).appendingPathComponent("pass-\(pass)-case-\(index).wav")
                    try result.writeWAV(to: url)
                } else if pass == repeats - 1 { try result.writeWAV(to: URL(fileURLWithPath: value("--output")!)) }
                runs.append(["name": item.name, "pass": pass, "text": result.preparedText, "synthesisMs": result.synthesisMilliseconds,
                    "firstPcmMs": result.firstPCMMilliseconds, "audioSeconds": result.audioSeconds, "rtf": result.rtf,
                    "pcmSha256": SHA256.hash(data: result.pcm16).map { String(format: "%02x", $0) }.joined(),
                    "streamMatchesCompletedPcm": matches, "metrics": result.metrics, "diagnostics": result.diagnostics])
                print(String(format: "pass=%d %@ audio=%.2fs synth=%.1fms firstPCM=%.1fms RTF=%.4f", pass, item.name,
                     result.audioSeconds, result.synthesisMilliseconds, result.firstPCMMilliseconds, result.rtf))
            }
        }
        if let report = value("--report") {
            let data = try JSONSerialization.data(withJSONObject: ["modelLoadMs": loadMs,
                "referenceMs": registration.milliseconds, "referenceCacheHit": registration.cacheHit,
                "timingScope": "TTS only; first PCM callback, not physical speaker onset; model/reference preparation excluded from RTF",
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "runs": runs], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: report), options: .atomic)
        }
        await engine.release()
    }
}
