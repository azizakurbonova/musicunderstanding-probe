import Foundation
import MUProbeKit

// usage: mu-probe <outputDir> <slug=path> [<slug=path> ...]

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: mu-probe <outputDir> <slug=path> ...\n".data(using: .utf8)!)
    exit(2)
}

let outDir = URL(fileURLWithPath: args[0], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var rows: [String] = []
var failures = 0

for spec in args.dropFirst() {
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
        print("skipping malformed spec: \(spec)")
        continue
    }
    let slug = parts[0]
    let url = URL(fileURLWithPath: parts[1])

    print("\n>>> analysing \(slug) — \(url.lastPathComponent)")
    do {
        let report = try await Probe.analyze(url: url, slug: slug)
        print(report.text)

        try? report.text.data(using: .utf8)?
            .write(to: outDir.appendingPathComponent("\(slug).timeline.txt"))
        try? report.json?
            .write(to: outDir.appendingPathComponent("\(slug).result.json"))

        rows.append(String(
            format: "| %@ | %.1f | %.3f | %.3f | %.1fx | %d | %d | %d | %d | %@ |",
            slug,
            report.durationSeconds,
            report.sessionInitSeconds,
            report.analyzeSeconds,
            report.durationSeconds / max(report.analyzeSeconds, 0.0001),
            report.sectionCount,
            report.segmentCount,
            report.phraseCount,
            report.beatCount,
            report.bpm.map { String(format: "%.1f", $0) } ?? "nil"
        ))
    } catch {
        failures += 1
        print("!!! FAILED \(slug): \(error)")
        rows.append("| \(slug) | FAILED: \(error) | | | | | | | | |")
    }
}

var table = "\n\n=== TIMING TABLE (macOS host) ===\n"
table += "| track | dur s | init s | analyze s | realtime | sections | segments | phrases | beats | bpm |\n"
table += "|---|---|---|---|---|---|---|---|---|---|\n"
table += rows.joined(separator: "\n") + "\n"
print(table)
try? table.data(using: .utf8)?.write(to: outDir.appendingPathComponent("timing-host.md"))

if failures > 0 { exit(1) }
