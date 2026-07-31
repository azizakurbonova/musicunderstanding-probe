import AVFoundation
import CoreMedia
import Foundation
import MusicUnderstanding

// MARK: - Formatting helpers

func fmt(_ t: CMTime) -> String {
    guard t.isNumeric else { return "  --:--  " }
    let s = t.seconds
    let m = Int(s) / 60
    let rest = s - Double(m * 60)
    return String(format: "%d:%06.3f", m, rest)
}

func fmt(_ v: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", v)
}

func fmt(_ v: Float, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", v)
}

// MARK: - Result of one analysed track

public struct TrackReport: Sendable {
    public var slug: String
    public var durationSeconds: Double
    public var sessionInitSeconds: Double
    public var analyzeSeconds: Double
    public var sectionCount: Int
    public var segmentCount: Int
    public var phraseCount: Int
    public var beatCount: Int
    public var bpm: Float?
    public var text: String
    public var json: Data?
}

// MARK: - The probe

public enum Probe {

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    public static var allTypes: Set<AnalysisType> {
        [.structure, .rhythm, .pace, .loudness, .instrumentActivity, .key]
    }

    /// Runs a full analysis and renders a human-readable merged timeline.
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    public static func analyze(url: URL, slug: String) async throws -> TrackReport {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let duration = try await asset.load(.duration)

        let clock = ContinuousClock()
        let tA = clock.now
        let session = try await MusicUnderstandingSession(asset: asset)
        let tB = clock.now
        let result = try await session.analyze(for: allTypes)
        let tC = clock.now

        let initSecs = Double((tB - tA).components.seconds)
            + Double((tB - tA).components.attoseconds) / 1e18
        let analyzeSecs = Double((tC - tB).components.seconds)
            + Double((tC - tB).components.attoseconds) / 1e18

        let text = render(
            slug: slug,
            duration: duration,
            initSecs: initSecs,
            analyzeSecs: analyzeSecs,
            result: result
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try? encoder.encode(result)

        return TrackReport(
            slug: slug,
            durationSeconds: duration.seconds,
            sessionInitSeconds: initSecs,
            analyzeSeconds: analyzeSecs,
            sectionCount: result.structure?.sections.count ?? -1,
            segmentCount: result.structure?.segments.count ?? -1,
            phraseCount: result.structure?.phrases.count ?? -1,
            beatCount: result.rhythm?.beats.count ?? -1,
            bpm: result.rhythm?.beatsPerMinute,
            text: text,
            json: json
        )
    }

    // MARK: - Cross-signal helpers

    /// Mean of timed values whose time falls in [from, to).
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    static func mean(
        _ values: [MusicUnderstandingSession.TimedValue<Float>],
        from: Double,
        to: Double
    ) -> Float? {
        let hits = values.filter { $0.time.isNumeric && $0.time.seconds >= from && $0.time.seconds < to }
        guard !hits.isEmpty else { return nil }
        return hits.reduce(Float(0)) { $0 + $1.value } / Float(hits.count)
    }

    /// Value of the ranged series covering `t`.
    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    static func value(
        _ ranges: [MusicUnderstandingSession.RangedValue<Double>],
        at t: Double
    ) -> Double? {
        ranges.first {
            $0.range.start.isNumeric && $0.range.duration.isNumeric
                && t >= $0.range.start.seconds
                && t < $0.range.start.seconds + $0.range.duration.seconds
        }?.value
    }

    static func instrumentName(_ i: InstrumentActivityResult.Instrument) -> String {
        switch i {
        case .vocal: return "vocal"
        case .drum: return "drum"
        case .bass: return "bass"
        case .other: return "other"
        default: return i.rawValue
        }
    }

    // MARK: - Rendering

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    static func render(
        slug: String,
        duration: CMTime,
        initSecs: Double,
        analyzeSecs: Double,
        result: MusicUnderstandingSession.SessionResult
    ) -> String {
        var out = ""
        func line(_ s: String = "") { out += s + "\n" }

        line("================================================================")
        line("TRACK: \(slug)")
        line("================================================================")
        line("duration            : \(fmt(duration))  (\(fmt(duration.seconds))s)")
        line("session init        : \(fmt(initSecs, 3))s")
        line("analyze(for:) all 6 : \(fmt(analyzeSecs, 3))s")
        if duration.seconds > 0 {
            line("realtime factor     : \(fmt(duration.seconds / max(analyzeSecs, 0.0001), 1))x faster than playback")
        }
        line()

        // ---- which result buckets came back at all
        line("--- RESULT PRESENCE ---")
        line("structure          : \(result.structure == nil ? "nil" : "present")")
        line("rhythm             : \(result.rhythm == nil ? "nil" : "present")")
        line("pace               : \(result.pace == nil ? "nil" : "present")")
        line("loudness           : \(result.loudness == nil ? "nil" : "present")")
        line("instrumentActivity : \(result.instrumentActivity == nil ? "nil" : "present")")
        line("key                : \(result.key == nil ? "nil" : "present")")
        line()

        // ---- rhythm
        if let r = result.rhythm {
            line("--- RHYTHM ---")
            line("beatsPerMinute : \(r.beatsPerMinute.map { fmt($0, 2) } ?? "nil")")
            line("beats          : \(r.beats.count)")
            line("bars           : \(r.bars.count)")
            if r.beats.count > 1 {
                let secs = r.beats.compactMap { $0.isNumeric ? $0.seconds : nil }
                let deltas = zip(secs.dropFirst(), secs).map(-)
                let mean = deltas.reduce(0, +) / Double(max(deltas.count, 1))
                let variance = deltas.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(deltas.count, 1))
                line("beat interval  : mean \(fmt(mean, 4))s  sd \(fmt(sqrt(variance), 4))s  -> implied \(fmt(60.0 / max(mean, 0.0001), 2)) BPM")
            }
            line("first 8 beats  : \(r.beats.prefix(8).map { fmt($0) }.joined(separator: "  "))")
            line("first 6 bars   : \(r.bars.prefix(6).map { fmt($0) }.joined(separator: "  "))")
            line()
        }

        // ---- key
        if let k = result.key {
            line("--- KEY ---")
            for kr in k.ranges.prefix(12) {
                line("  \(fmt(kr.range.start)) -> \(fmt(kr.range.end))   \(kr.value.tonic.rawValue) \(kr.value.mode.rawValue)")
            }
            if k.ranges.count > 12 { line("  ... \(k.ranges.count - 12) more key ranges") }
            line()
        }

        // ---- loudness
        if let l = result.loudness {
            line("--- LOUDNESS (LUFS) ---")
            line("integrated : \(fmt(l.integrated.value)) @ \(fmt(l.integrated.time))")
            line("peak       : \(fmt(l.peak.value)) @ \(fmt(l.peak.time))")
            line("momentary  : \(l.momentary.count) samples")
            line("shortTerm  : \(l.shortTerm.count) samples")
            line()
            line("shortTerm contour, sampled every 5s:")
            var t = 0.0
            var contour = ""
            while t < duration.seconds {
                if let v = mean(l.shortTerm, from: t, to: t + 5) {
                    // -60..0 LUFS mapped to a 40-wide bar
                    let norm = max(0.0, min(1.0, (Double(v) + 60.0) / 60.0))
                    let bars = Int(norm * 40)
                    contour += String(format: "  %6.1fs %7.2f |%@\n", t, v, String(repeating: "#", count: bars))
                }
                t += 5
            }
            line(contour)
        }

        // ---- pace
        if let p = result.pace {
            line("--- PACE ---")
            line("ranges: \(p.ranges.count)")
            for pr in p.ranges.prefix(24) {
                line("  \(fmt(pr.range.start)) -> \(fmt(pr.range.end))   pace \(fmt(pr.value, 3))")
            }
            if p.ranges.count > 24 { line("  ... \(p.ranges.count - 24) more pace ranges") }
            line()
        }

        // ---- instrument activity
        if let ia = result.instrumentActivity {
            line("--- INSTRUMENT ACTIVITY ---")
            for (inst, ranges) in ia.ranges.sorted(by: { instrumentName($0.key) < instrumentName($1.key) }) {
                line("  \(instrumentName(inst)) active ranges: \(ranges.count)")
                for rr in ranges.prefix(16) {
                    line("      \(fmt(rr.start)) -> \(fmt(rr.end))")
                }
                if ranges.count > 16 { line("      ... \(ranges.count - 16) more") }
            }
            for (inst, act) in ia.activity.sorted(by: { instrumentName($0.key) < instrumentName($1.key) }) {
                line("  \(instrumentName(inst)) activity samples: \(act.count)")
            }
            line()
        }

        // ---- structure: THE headline question
        line("--- STRUCTURE (the labelled-vs-unlabelled question) ---")
        if let s = result.structure {
            line("StructureResult fields are `sections`, `segments`, `phrases`, each [CMTimeRange].")
            line("There is NO label / role / type / confidence property on the API surface.")
            line("sections: \(s.sections.count)   segments: \(s.segments.count)   phrases: \(s.phrases.count)")
            line()

            line("SECTIONS with cross-signal evidence at each boundary:")
            line("  #   start        end          len      dLUFS(6s pre->post)   pace pre->post    instrument entries at boundary")
            for (i, sec) in s.sections.enumerated() {
                let start = sec.start.seconds
                let end = sec.end.seconds
                let len = end - start

                var dL = "      --"
                if let l = result.loudness,
                   let pre = mean(l.shortTerm, from: start - 6, to: start),
                   let post = mean(l.shortTerm, from: start, to: start + 6) {
                    dL = String(format: "%+8.2f dB", post - pre)
                }

                var dP = "     --"
                if let p = result.pace {
                    let pre = value(p.ranges, at: start - 1)
                    let post = value(p.ranges, at: start + 1)
                    if let a = pre, let b = post {
                        dP = String(format: "%6.2f->%6.2f", a, b)
                    }
                }

                var entries: [String] = []
                if let ia = result.instrumentActivity {
                    for (inst, ranges) in ia.ranges {
                        for rr in ranges where abs(rr.start.seconds - start) <= 2.0 {
                            entries.append("+\(instrumentName(inst))")
                        }
                        for rr in ranges where abs(rr.end.seconds - start) <= 2.0 {
                            entries.append("-\(instrumentName(inst))")
                        }
                    }
                }

                line(String(
                    format: "  %-3d %-12@ %-12@ %6.1fs  %@   %@   %@",
                    i,
                    fmt(sec.start) as NSString,
                    fmt(sec.end) as NSString,
                    len,
                    dL as NSString,
                    dP as NSString,
                    entries.isEmpty ? "-" : entries.joined(separator: " ") as NSString
                ))
            }
            line()

            line("SEGMENTS (first 40):")
            for (i, sg) in s.segments.prefix(40).enumerated() {
                line("  \(String(format: "%-3d", i)) \(fmt(sg.start)) -> \(fmt(sg.end))   \(fmt(sg.duration.seconds, 1))s")
            }
            if s.segments.count > 40 { line("  ... \(s.segments.count - 40) more segments") }
            line()

            line("PHRASES (first 40):")
            for (i, ph) in s.phrases.prefix(40).enumerated() {
                line("  \(String(format: "%-3d", i)) \(fmt(ph.start)) -> \(fmt(ph.end))   \(fmt(ph.duration.seconds, 1))s")
            }
            if s.phrases.count > 40 { line("  ... \(s.phrases.count - 40) more phrases") }
            line()

            // Boundary alignment with the beat grid: are sections snapped to bars?
            if let r = result.rhythm, !r.bars.isEmpty {
                let barSecs = r.bars.compactMap { $0.isNumeric ? $0.seconds : nil }
                var aligned = 0
                var offs: [Double] = []
                for sec in s.sections {
                    let t = sec.start.seconds
                    if let nearest = barSecs.min(by: { abs($0 - t) < abs($1 - t) }) {
                        let off = abs(nearest - t)
                        offs.append(off)
                        if off <= 0.12 { aligned += 1 }
                    }
                }
                let meanOff = offs.isEmpty ? 0 : offs.reduce(0, +) / Double(offs.count)
                line("section starts snapped to a bar line (<=120ms): \(aligned)/\(s.sections.count), mean offset \(fmt(meanOff, 3))s")
                line()
            }
        } else {
            line("structure == nil")
            line()
        }

        return out
    }
}
