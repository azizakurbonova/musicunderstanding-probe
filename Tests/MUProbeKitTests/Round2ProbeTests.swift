import AVFoundation
import CoreMedia
import Foundation
import XCTest

@testable import MUProbeKit

import MusicUnderstanding

/// ROUND 2 — raw SessionResult evidence on real CC audio.
///
/// Produces, per bundled track:
///   1. the full Codable JSON dump of the real SessionResult (pretty, sorted)
///   2. a non-finite Double/Float verdict on the real payload (JSON .throw,
///      binary plist, and a sentinel scan that counts occurrences)
///   3. codec numbers on the real payload: JSON vs binary plist size, and
///      decode p95 (nearest-rank, 20 samples) per track and as a batch
///   4. a phrase/section/segment census with bar-quantisation and a
///      uniform-grid suspicion metric
/// Plus a per-analysis-type wall-time proxy on two tracks, because the API
/// exposes no per-stage timing (analyze(for:) is monolithic — verified against
/// the round-1 swiftinterface dump).
final class Round2ProbeTests: XCTestCase {

    static let sampleCount = 20  // decode samples per codec, matching the shipped stand-in methodology

    struct TrackMetrics: Codable {
        var slug: String
        var durationSeconds: Double
        var sessionInitSeconds: Double
        var analyzeAllSixSeconds: Double
        var realtimeFactor: Double

        // presence
        var structurePresent: Bool
        var rhythmPresent: Bool
        var pacePresent: Bool
        var loudnessPresent: Bool
        var instrumentActivityPresent: Bool
        var keyPresent: Bool

        // non-finite verdicts
        var jsonThrowEncodeSucceeded: Bool
        var jsonThrowEncodeError: String?
        var plistEncodeSucceeded: Bool
        var plistEncodeError: String?
        var nonFiniteSentinelCount: Int

        // codec on the REAL payload
        var jsonCompactBytes: Int?
        var plistBinaryBytes: Int?
        var jsonDecodeP95Ms: Double?
        var plistDecodeP95Ms: Double?
        var jsonDecodeMeanMs: Double?
        var plistDecodeMeanMs: Double?

        // structure census
        var sectionCount: Int
        var segmentCount: Int
        var phraseCount: Int
        var beatCount: Int
        var barCount: Int
        var bpm: Float?
        var sectionLenSeconds: [Double]
        var sectionLenBars: [Double]
        var phraseLenSecondsMin: Double?
        var phraseLenSecondsMedian: Double?
        var phraseLenSecondsMax: Double?
        var segmentLenSecondsMedian: Double?
        var modalBarLength: Int?
        var modalBarLengthShare: Double?
        var maxDeviationFromIntegerBars: Double?
    }

    struct StageProxy: Codable {
        var slug: String
        var perTypeSeconds: [String: Double]
        var perTypeSum: Double
        var allSixSeconds: Double
    }

    struct Round2Output: Codable {
        var sampleCount: Int
        var tracks: [TrackMetrics]
        var batchDecode: [String: Double]
        var stageProxies: [StageProxy]
    }

    func testRound2() async throws {
        let tracks = SimulatorProbeTests.bundledAudio()
        guard !tracks.isEmpty else { throw XCTSkip("no audio in bundle") }
        print("=== ROUND 2: \(tracks.count) BUNDLED TRACKS ===")

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mu-round2-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("round2 report dir: \(outDir.path)")

        let clock = ContinuousClock()
        var metrics: [TrackMetrics] = []
        var realPayloads: [(slug: String, json: Data, plist: Data?)] = []

        for url in tracks {
            let slug = url.deletingPathExtension().lastPathComponent
            print("\n>>> R2 ANALYSING \(slug)")

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration = try await asset.load(.duration)

            let tA = clock.now
            let session = try await MusicUnderstandingSession(asset: asset)
            let tB = clock.now
            let result: MusicUnderstandingSession.SessionResult
            do {
                result = try await session.analyze(for: Probe.allTypes)
            } catch {
                print("!!! R2 ANALYZE FAILED \(slug): \(error)")
                continue
            }
            let tC = clock.now
            let initS = seconds(tB - tA)
            let anaS = seconds(tC - tB)
            print("    init \(f3(initS))s  analyze \(f3(anaS))s  (\(f1(duration.seconds / max(anaS, 0.0001)))x realtime)")

            // ---- 1. full raw JSON dump (pretty, sorted — the ground-truth artifact)
            let pretty = JSONEncoder()
            pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
            pretty.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "__MU_POSINF__", negativeInfinity: "__MU_NEGINF__", nan: "__MU_NAN__")
            let prettyData = try pretty.encode(result)
            try prettyData.write(to: outDir.appendingPathComponent("\(slug).sessionresult.json"))
            print("    raw dump: \(prettyData.count) bytes (pretty)")

            // ---- 2. non-finite verdicts on the real payload
            var jsonThrowOK = true, jsonThrowErr: String? = nil
            var jsonCompact: Data? = nil
            do {
                let e = JSONEncoder()
                e.nonConformingFloatEncodingStrategy = .throw  // the strict strategy a persisting consumer would use
                jsonCompact = try e.encode(result)
            } catch {
                jsonThrowOK = false; jsonThrowErr = String(describing: error)
            }
            var plistOK = true, plistErr: String? = nil
            var plistData: Data? = nil
            do {
                let pe = PropertyListEncoder()
                pe.outputFormat = .binary
                plistData = try pe.encode(result)
            } catch {
                plistOK = false; plistErr = String(describing: error)
            }
            let sentinelText = String(data: prettyData, encoding: .utf8) ?? ""
            let sentinelCount = ["__MU_POSINF__", "__MU_NEGINF__", "__MU_NAN__"]
                .map { sentinelText.components(separatedBy: $0).count - 1 }.reduce(0, +)
            print("    non-finite: json.throw=\(jsonThrowOK ? "OK" : "THREW") plist=\(plistOK ? "OK" : "THREW") sentinels=\(sentinelCount)")

            // ---- 3. codec decode p95 on the real payload (per track)
            var jsonP95: Double? = nil, jsonMean: Double? = nil
            var plistP95: Double? = nil, plistMean: Double? = nil
            if let jd = jsonCompact {
                let times = measureDecodesMs(count: Self.sampleCount) {
                    _ = try JSONDecoder().decode(MusicUnderstandingSession.SessionResult.self, from: jd)
                }
                jsonP95 = nearestRankP95(times); jsonMean = times.reduce(0, +) / Double(times.count)
            }
            if let pd = plistData {
                let times = measureDecodesMs(count: Self.sampleCount) {
                    _ = try PropertyListDecoder().decode(MusicUnderstandingSession.SessionResult.self, from: pd)
                }
                plistP95 = nearestRankP95(times); plistMean = times.reduce(0, +) / Double(times.count)
            }
            if let jd = jsonCompact { realPayloads.append((slug, jd, plistData)) }

            // ---- 4. structure census
            let s = result.structure
            let secLens: [Double] = (s?.sections ?? []).map { $0.duration.seconds }
            var secBars: [Double] = []
            var modalLen: Int? = nil, modalShare: Double? = nil, maxDev: Double? = nil
            if let bpm = result.rhythm?.beatsPerMinute, bpm > 0 {
                let barSec = 4.0 * 60.0 / Double(bpm)
                secBars = secLens.map { $0 / barSec }
                let rounded = secBars.map { Int(($0).rounded()) }
                if !rounded.isEmpty {
                    let freq = Dictionary(grouping: rounded, by: { $0 }).mapValues(\.count)
                    if let (len, n) = freq.max(by: { $0.value < $1.value }) {
                        modalLen = len
                        modalShare = Double(n) / Double(rounded.count)
                    }
                    maxDev = secBars.map { abs($0 - $0.rounded()) }.max()
                }
            }
            let phLens = (s?.phrases ?? []).map { $0.duration.seconds }.sorted()
            let sgLens = (s?.segments ?? []).map { $0.duration.seconds }.sorted()

            metrics.append(TrackMetrics(
                slug: slug,
                durationSeconds: duration.seconds,
                sessionInitSeconds: initS,
                analyzeAllSixSeconds: anaS,
                realtimeFactor: duration.seconds / max(anaS, 0.0001),
                structurePresent: result.structure != nil,
                rhythmPresent: result.rhythm != nil,
                pacePresent: result.pace != nil,
                loudnessPresent: result.loudness != nil,
                instrumentActivityPresent: result.instrumentActivity != nil,
                keyPresent: result.key != nil,
                jsonThrowEncodeSucceeded: jsonThrowOK,
                jsonThrowEncodeError: jsonThrowErr,
                plistEncodeSucceeded: plistOK,
                plistEncodeError: plistErr,
                nonFiniteSentinelCount: sentinelCount,
                jsonCompactBytes: jsonCompact?.count,
                plistBinaryBytes: plistData?.count,
                jsonDecodeP95Ms: jsonP95,
                plistDecodeP95Ms: plistP95,
                jsonDecodeMeanMs: jsonMean,
                plistDecodeMeanMs: plistMean,
                sectionCount: s?.sections.count ?? -1,
                segmentCount: s?.segments.count ?? -1,
                phraseCount: s?.phrases.count ?? -1,
                beatCount: result.rhythm?.beats.count ?? -1,
                barCount: result.rhythm?.bars.count ?? -1,
                bpm: result.rhythm?.beatsPerMinute,
                sectionLenSeconds: secLens.map { round($0 * 1000) / 1000 },
                sectionLenBars: secBars.map { round($0 * 1000) / 1000 },
                phraseLenSecondsMin: phLens.first,
                phraseLenSecondsMedian: median(phLens),
                phraseLenSecondsMax: phLens.last,
                segmentLenSecondsMedian: median(sgLens),
                modalBarLength: modalLen,
                modalBarLengthShare: modalShare,
                maxDeviationFromIntegerBars: maxDev
            ))
        }

        // ---- batch decode measurement, replicating the shipped stand-in methodology
        // (decode the whole corpus sequentially = one sample; 20 samples; nearest-rank p95)
        var batch: [String: Double] = [:]
        if !realPayloads.isEmpty {
            let jsonBatch = measureDecodesMs(count: Self.sampleCount) {
                for p in realPayloads {
                    _ = try JSONDecoder().decode(MusicUnderstandingSession.SessionResult.self, from: p.json)
                }
            }
            batch["jsonBatchP95Ms"] = nearestRankP95(jsonBatch)
            batch["jsonBatchMeanMs"] = jsonBatch.reduce(0, +) / Double(jsonBatch.count)
            let plists = realPayloads.compactMap(\.plist)
            if plists.count == realPayloads.count {
                let plistBatch = measureDecodesMs(count: Self.sampleCount) {
                    for d in plists {
                        _ = try PropertyListDecoder().decode(MusicUnderstandingSession.SessionResult.self, from: d)
                    }
                }
                batch["plistBatchP95Ms"] = nearestRankP95(plistBatch)
                batch["plistBatchMeanMs"] = plistBatch.reduce(0, +) / Double(plistBatch.count)
            }
            batch["trackCount"] = Double(realPayloads.count)
        }

        // ---- per-type stage proxy on two tracks (API exposes no per-stage timing)
        var proxies: [StageProxy] = []
        let proxySlugs = ["edm-build-drop-a", "rock-verse-chorus"]
        for url in tracks {
            let slug = url.deletingPathExtension().lastPathComponent
            guard proxySlugs.contains(slug) else { continue }
            print("\n>>> R2 PER-TYPE PROXY \(slug)")
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var perType: [String: Double] = [:]
            for t in Probe.allTypes {
                do {
                    let s = try await MusicUnderstandingSession(asset: asset)
                    let t0 = clock.now
                    _ = try await s.analyze(for: [t])
                    perType[t.rawValue] = seconds(clock.now - t0)
                } catch {
                    print("    per-type \(t.rawValue) FAILED: \(error)")
                }
            }
            let allSix = metrics.first(where: { $0.slug == slug })?.analyzeAllSixSeconds ?? -1
            proxies.append(StageProxy(
                slug: slug, perTypeSeconds: perType,
                perTypeSum: perType.values.reduce(0, +), allSixSeconds: allSix))
            for (k, v) in perType.sorted(by: { $0.key < $1.key }) {
                print("    \(k): \(f3(v))s")
            }
        }

        // ---- write metrics + summary
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outData = try enc.encode(Round2Output(
            sampleCount: Self.sampleCount, tracks: metrics, batchDecode: batch, stageProxies: proxies))
        try outData.write(to: outDir.appendingPathComponent("round2-metrics.json"))

        let summary = renderSummary(metrics: metrics, batch: batch, proxies: proxies)
        try summary.data(using: .utf8)?.write(to: outDir.appendingPathComponent("round2-summary.md"))
        print("\n<<<<<<<<<< BEGIN ROUND2 SUMMARY >>>>>>>>>>")
        print(summary)
        print("<<<<<<<<<< END ROUND2 SUMMARY >>>>>>>>>>")

        let att = XCTAttachment(data: outData)
        att.name = "round2-metrics.json"
        att.lifetime = .keepAlways
        add(att)
        let att2 = XCTAttachment(string: summary)
        att2.name = "round2-summary.md"
        att2.lifetime = .keepAlways
        add(att2)

        XCTAssertFalse(metrics.isEmpty, "no track produced a SessionResult")
    }

    // MARK: - helpers

    func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func measureDecodesMs(count: Int, _ body: () throws -> Void) -> [Double] {
        let clock = ContinuousClock()
        var out: [Double] = []
        for _ in 0..<count {
            let t0 = clock.now
            do { try body() } catch { return [] }
            out.append(seconds(clock.now - t0) * 1000)
        }
        return out
    }

    /// Nearest-rank p95 — the shipped stand-in measurement's estimator.
    func nearestRankP95(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(rank - 1, sorted.count - 1))]
    }

    func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let m = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2
    }

    func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    func renderSummary(metrics: [TrackMetrics], batch: [String: Double], proxies: [StageProxy]) -> String {
        var o = "# Round 2 summary (iOS Simulator on CI — proxy numbers, not device numbers)\n\n"
        o += "## Timing + census\n\n"
        o += "| track | dur s | init s | analyze s | realtime | sections | segments | phrases | beats | bpm |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for m in metrics {
            o += "| \(m.slug) | \(f1(m.durationSeconds)) | \(f3(m.sessionInitSeconds)) | \(f3(m.analyzeAllSixSeconds)) | \(f1(m.realtimeFactor))x | \(m.sectionCount) | \(m.segmentCount) | \(m.phraseCount) | \(m.beatCount) | \(m.bpm.map { String(format: "%.1f", $0) } ?? "nil") |\n"
        }
        o += "\n## Non-finite Doubles in real payloads\n\n"
        o += "| track | JSON .throw encode | binary plist encode | sentinel count |\n|---|---|---|---|\n"
        for m in metrics {
            o += "| \(m.slug) | \(m.jsonThrowEncodeSucceeded ? "OK" : "THREW: \(m.jsonThrowEncodeError ?? "?")") | \(m.plistEncodeSucceeded ? "OK" : "THREW: \(m.plistEncodeError ?? "?")") | \(m.nonFiniteSentinelCount) |\n"
        }
        o += "\n## Codec on REAL payloads (\(Self.sampleCount) samples, nearest-rank p95)\n\n"
        o += "| track | json bytes | plist bytes | plist/json | json p95 ms | plist p95 ms |\n|---|---|---|---|---|---|\n"
        for m in metrics {
            let ratio = (m.jsonCompactBytes != nil && m.plistBinaryBytes != nil)
                ? String(format: "%.2f", Double(m.plistBinaryBytes!) / Double(m.jsonCompactBytes!)) : "-"
            o += "| \(m.slug) | \(m.jsonCompactBytes.map(String.init) ?? "-") | \(m.plistBinaryBytes.map(String.init) ?? "-") | \(ratio) | \(m.jsonDecodeP95Ms.map { f3($0) } ?? "-") | \(m.plistDecodeP95Ms.map { f3($0) } ?? "-") |\n"
        }
        o += "\nBatch (whole corpus decoded sequentially per sample): "
        o += batch.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\(f3($0.value))" }.joined(separator: "  ")
        o += "\n\n## Section lengths in bars (uniform-grid suspicion)\n\n"
        for m in metrics {
            o += "- **\(m.slug)** (bpm \(m.bpm.map { String(format: "%.1f", $0) } ?? "nil")): "
            o += m.sectionLenBars.map { String(format: "%.2f", $0) }.joined(separator: " ")
            if let modal = m.modalBarLength, let share = m.modalBarLengthShare {
                o += "  → modal \(modal) bars, share \(String(format: "%.2f", share))"
            }
            if let dev = m.maxDeviationFromIntegerBars {
                o += ", max dev from integer bars \(String(format: "%.3f", dev))"
            }
            o += "\n"
        }
        o += "\n## Phrase census\n\n"
        o += "| track | phrases | min s | median s | max s | segment median s |\n|---|---|---|---|---|---|\n"
        for m in metrics {
            o += "| \(m.slug) | \(m.phraseCount) | \(m.phraseLenSecondsMin.map { f1($0) } ?? "-") | \(m.phraseLenSecondsMedian.map { f1($0) } ?? "-") | \(m.phraseLenSecondsMax.map { f1($0) } ?? "-") | \(m.segmentLenSecondsMedian.map { f1($0) } ?? "-") |\n"
        }
        o += "\n## Per-type wall-time proxy (NO per-stage API exists; fresh session per type)\n\n"
        for p in proxies {
            o += "- **\(p.slug)**: "
            o += p.perTypeSeconds.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\(f3($0.value))s" }.joined(separator: "  ")
            o += "  | sum \(f3(p.perTypeSum))s vs all-six-at-once \(f3(p.allSixSeconds))s\n"
        }
        return o
    }
}
