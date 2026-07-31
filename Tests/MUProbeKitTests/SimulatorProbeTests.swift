import AVFoundation
import CoreMedia
import Foundation
import XCTest

@testable import MUProbeKit

import MusicUnderstanding

final class SimulatorProbeTests: XCTestCase {

    /// Q1 — does the framework run at all inside the simulator?
    /// Deliberately depends on nothing external: synthesises its own audio.
    func testFrameworkRunsHere() async throws {
        print("=== ENVIRONMENT ===")
        #if targetEnvironment(simulator)
        print("targetEnvironment: SIMULATOR")
        #else
        print("targetEnvironment: DEVICE-OR-HOST")
        #endif
        print("ProcessInfo.os: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let url = try Self.synthesiseClickTrack(seconds: 25, bpm: 120)
        print("synthesised: \(url.path)")

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await session.analyze(for: [.rhythm, .loudness, .structure, .pace])

        print("=== SYNTHETIC RESULT ===")
        print("rhythm present    : \(result.rhythm != nil)")
        print("beats             : \(result.rhythm?.beats.count ?? -1)")
        print("bars              : \(result.rhythm?.bars.count ?? -1)")
        print("bpm               : \(String(describing: result.rhythm?.beatsPerMinute))")
        print("loudness present  : \(result.loudness != nil)")
        print("integrated LUFS   : \(String(describing: result.loudness?.integrated.value))")
        print("shortTerm samples : \(result.loudness?.shortTerm.count ?? -1)")
        print("structure present : \(result.structure != nil)")
        print("sections          : \(result.structure?.sections.count ?? -1)")
        print("segments          : \(result.structure?.segments.count ?? -1)")
        print("phrases           : \(result.structure?.phrases.count ?? -1)")
        print("pace ranges       : \(result.pace?.ranges.count ?? -1)")

        // "Non-trivial result" bar: real loudness measurement over real samples.
        let loudness = try XCTUnwrap(result.loudness, "loudness came back nil in this environment")
        XCTAssertFalse(loudness.shortTerm.isEmpty, "no short-term loudness samples")
        XCTAssertTrue(loudness.integrated.value.isFinite, "integrated LUFS not finite")
        XCTAssertTrue(loudness.integrated.value < 0, "integrated LUFS should be negative for this signal")

        // Rhythm on a 120 BPM click should land close to 120.
        if let bpm = result.rhythm?.beatsPerMinute {
            print("detected BPM \(bpm) against a synthesised 120")
        }
    }

    /// Q2 + Q3 — real Creative Commons tracks, if CI dropped them into the bundle.
    func testRealTracks() async throws {
        let tracks = Self.bundledAudio()
        guard !tracks.isEmpty else {
            print("=== NO BUNDLED AUDIO — skipping real-track pass ===")
            throw XCTSkip("no audio in bundle")
        }
        print("=== \(tracks.count) BUNDLED TRACKS ===")

        var rows: [String] = []
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mu-sim-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("sim report dir: \(outDir.path)")

        for url in tracks {
            let slug = url.deletingPathExtension().lastPathComponent
            print("\n>>> SIM ANALYSING \(slug)")
            do {
                let report = try await Probe.analyze(url: url, slug: slug)
                print("<<<<<<<<<< BEGIN TIMELINE \(slug) >>>>>>>>>>")
                print(report.text)
                print("<<<<<<<<<< END TIMELINE \(slug) >>>>>>>>>>")

                try? report.text.data(using: .utf8)?
                    .write(to: outDir.appendingPathComponent("\(slug).sim.timeline.txt"))

                let att = XCTAttachment(string: report.text)
                att.name = "\(slug).sim.timeline.txt"
                att.lifetime = .keepAlways
                add(att)

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
                print("!!! SIM FAILED \(slug): \(error)")
                rows.append("| \(slug) | FAILED: \(error) | | | | | | | | |")
            }
        }

        var table = "\n=== TIMING TABLE (iOS Simulator) ===\n"
        table += "| track | dur s | init s | analyze s | realtime | sections | segments | phrases | beats | bpm |\n"
        table += "|---|---|---|---|---|---|---|---|---|---|\n"
        table += rows.joined(separator: "\n") + "\n"
        print(table)
        let att = XCTAttachment(string: table)
        att.name = "timing-simulator.md"
        att.lifetime = .keepAlways
        add(att)
    }

    // MARK: - helpers

    static func bundledAudio() -> [URL] {
        let exts = ["mp3", "m4a", "wav", "flac", "aac", "aif", "aiff"]
        var found: [URL] = []
        let b = Bundle.module
        for e in exts {
            found += b.urls(forResourcesWithExtension: e, subdirectory: nil) ?? []
            found += b.urls(forResourcesWithExtension: e, subdirectory: "Audio") ?? []
        }
        // de-dup, stable order
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    /// A 120 BPM amplitude-modulated tone written to a WAV — enough signal for
    /// loudness and rhythm without shipping any audio in the repository.
    static func synthesiseClickTrack(seconds: Double, bpm: Double) throws -> URL {
        let sampleRate = 44100.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let beatPeriod = 60.0 / bpm
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let phaseInBeat = t.truncatingRemainder(dividingBy: beatPeriod) / beatPeriod
            // percussive envelope on every beat
            let env = exp(-phaseInBeat * 14.0)
            // alternate a low "kick" and a higher "snare" every other beat
            let beatIndex = Int(t / beatPeriod)
            let carrier = (beatIndex % 2 == 0) ? 90.0 : 320.0
            // plus a sustained pad so it is not pure silence between hits
            let pad = 0.06 * sin(2 * .pi * 220.0 * t)
            ptr[i] = Float(0.7 * env * sin(2 * .pi * carrier * t) + pad)
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mu-click-\(Int(bpm))-\(Int(seconds)).wav")
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return url
    }
}
