import Foundation

/// Transport mode of one entry of the schedule pack. The raw values are the
/// ones the pack writes, so decoding is a plain `ScheduleMode(rawValue:)`.
enum ScheduleMode: String {
    case metro
    case bus
    case funicular
}

/// One route variant of a direction: the stops it serves and the time offsets
/// of its timetable.
///
/// `arrivals` and `departures` are seconds from the arrival at the first stop,
/// which is always 0, so a run's absolute times are `originArrival + offset`.
struct SchedulePattern: Hashable {
    /// Stop codes, in travel order.
    let stops: [Int]
    /// Seconds from the first stop's arrival to the arrival at each stop.
    let arrivals: [Int]
    /// Seconds from the first stop's arrival to the departure from each stop.
    let departures: [Int]
}

/// One direction of a line: its headsign, the de-duplicated patterns it runs
/// and, per day type, the sorted list of `(startSec, patternIndex)` departures.
struct ScheduleDirection {
    /// GTFS `direction_id` (0 or 1), not the iBus `id_sentit` (1 or 2).
    let id: Int
    let headsign: String
    let patterns: [SchedulePattern]
    /// One list per day type index of the pack, each sorted by `start`.
    let dayTypes: [[(start: Int, pattern: Int)]]
}

/// One scheduled trip of one direction, anchored to an absolute instant.
struct ScheduledRun {
    let directionID: Int
    let headsign: String
    /// Departure from the first stop of the pattern, as an absolute instant:
    /// the service day's midnight in the pack's time zone plus `startSec`.
    let start: Date
    /// `startSec` as delivered by the pack: seconds from the service day's
    /// midnight. Kept because the theoretical fleet names a run with it.
    let startSec: Int
    let pattern: SchedulePattern

    /// Arrival at the last stop of the pattern: the run is over after this.
    var end: Date {
        guard let last = pattern.arrivals.last else { return start }
        return originArrival.addingTimeInterval(Double(last))
    }

    /// Absolute arrival at `stopCode`, or nil when the pattern skips it.
    func arrival(at stopCode: Int) -> Date? {
        guard let index = pattern.stops.firstIndex(of: stopCode),
              pattern.arrivals.indices.contains(index) else { return nil }
        return originArrival.addingTimeInterval(Double(pattern.arrivals[index]))
    }

    /// Absolute arrival at the first stop; the pattern offsets are relative to
    /// it, and `start` is the departure from it.
    var originArrival: Date {
        start.addingTimeInterval(-Double(pattern.departures.first ?? 0))
    }
}

/// One line of the schedule pack, with its timetable resolved to absolute
/// instants.
///
/// The date → day type table and the time zone stay here because a run is only
/// absolute once both are known: `runs(on:)` turns the service day of an
/// instant into the day type index the pack stores.
///
/// Per `(direction, service day)` the resolved runs and the per-stop arrival
/// lists are cached behind a lock, so a screen redrawing at 10 Hz pays the
/// resolution once. `ScheduleLine` is a value whose only mutable state is that
/// cache, which is why it is safe to share across threads.
struct ScheduleLine: @unchecked Sendable {
    let mode: ScheduleMode
    let code: Int
    let name: String
    let directions: [ScheduleDirection]
    /// `"yyyyMMdd"` of every date the pack has service for, mapped to its day
    /// type index. Dates without service are absent, which means no runs.
    let dates: [String: Int]
    /// Time zone the pack's service days and `startSec` are expressed in.
    let timeZone: TimeZone

    private let index = ScheduleIndex()

    /// Runs of the service day of `day`, plus the previous service day's runs
    /// that are still after midnight of it, so a trip that starts at 00:20 of
    /// the next calendar day is still found when asking about the next day.
    ///
    /// Sorted by `start`. `directionID` nil returns every direction.
    func runs(on day: Date, directionID: Int? = nil) -> [ScheduledRun] {
        index.day(self, serviceDay: serviceDayKey(for: day), directionID: directionID).runs
    }

    /// Absolute arrival instants at `stopCode` of one direction, ascending.
    func arrivals(at stopCode: Int, directionID: Int, on day: Date) -> [Date] {
        index.day(self, serviceDay: serviceDayKey(for: day), directionID: directionID).arrivals(at: stopCode)
    }

    /// Scheduled direction matching an iBus-style headsign, case and diacritic
    /// insensitive. `stopCodes` narrows the fallback to the only direction
    /// whose patterns serve them, which is what identifies the direction when
    /// the headsign strings differ (`"Gornal"` vs `"Gornal / Besòs"`).
    func direction(headsign: String, stopCodes: Set<Int>) -> ScheduleDirection? {
        let wanted = Self.fold(headsign)
        if !wanted.isEmpty,
           let exact = directions.first(where: { Self.fold($0.headsign) == wanted }) {
            return exact
        }
        let candidates = directions.filter { direction in
            direction.patterns.contains { pattern in
                pattern.stops.contains(where: stopCodes.contains)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// `"yyyyMMdd"` of the service day `instant` falls in, in the pack's zone.
    func serviceDayKey(for instant: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        return Self.key(components)
    }

    /// Midnight that starts the service day of `instant`, as an absolute Date.
    func serviceMidnight(for instant: Date) -> Date {
        calendar.startOfDay(for: instant)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func key(_ components: DateComponents) -> String {
        String(
            format: "%04d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Folds a name for comparison: lowercase, no diacritics, no surrounding
    /// blanks.
    private static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Decoding

    /// Decodes one `<mode>-<code>.json` file of the pack.
    static func decode(_ data: Data, timeZone: TimeZone) throws -> ScheduleLine {
        let file = try JSONDecoder().decode(LineFile.self, from: data)
        guard let mode = ScheduleMode(rawValue: file.mode) else {
            throw SchedulePackError.unknownMode(file.mode)
        }
        let directions = file.directions.map { direction in
            ScheduleDirection(
                id: direction.id,
                headsign: direction.headsign,
                patterns: direction.patterns.map {
                    SchedulePattern(stops: $0.stops, arrivals: $0.arr, departures: $0.dep)
                },
                dayTypes: direction.dayTypes.map { entries in
                    entries.compactMap { pair in
                        guard pair.count >= 2 else { return nil }
                        return (start: pair[0], pattern: pair[1])
                    }
                }
            )
        }
        return ScheduleLine(
            mode: mode,
            code: file.code,
            name: file.name,
            directions: directions,
            dates: file.dates,
            timeZone: timeZone
        )
    }
}

/// Errors of the schedule pack. Only thrown while decoding; the app treats
/// every one of them as "no schedule" and degrades silently.
enum SchedulePackError: Error {
    case unknownTimeZone(String)
    case unknownMode(String)
    case unsupportedVersion(Int)
}

// MARK: - Resolved days

/// Resolved runs of one `(direction, service day)` pair plus its lazily built
/// per-stop arrival lists. The lock is the only mutable state of the whole
/// schedule layer.
private final class ResolvedDay: @unchecked Sendable {
    let runs: [ScheduledRun]

    private let lock = NSLock()
    private var arrivalsByStop: [Int: [Date]] = [:]

    init(runs: [ScheduledRun]) {
        self.runs = runs
    }

    /// Arrivals at `stopCode` of every run of the day, ascending. Built once
    /// per stop: a stop is asked for on every UI redraw, the scan is not.
    func arrivals(at stopCode: Int) -> [Date] {
        lock.lock()
        if let cached = arrivalsByStop[stopCode] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var result: [Date] = []
        for run in runs {
            if let arrival = run.arrival(at: stopCode) {
                result.append(arrival)
            }
        }
        result.sort()

        lock.lock()
        arrivalsByStop[stopCode] = result
        lock.unlock()
        return result
    }
}

/// Cache of `ResolvedDay` per `(direction, service day)`, shared by every copy
/// of one `ScheduleLine`.
private final class ScheduleIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var days: [String: ResolvedDay] = [:]

    func day(_ line: ScheduleLine, serviceDay: String, directionID: Int?) -> ResolvedDay {
        let key = "\(serviceDay)-\(directionID.map(String.init) ?? "all")"
        lock.lock()
        if let cached = days[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = ResolvedDay(runs: resolve(line, serviceDay: serviceDay, directionID: directionID))
        lock.lock()
        days[key] = resolved
        lock.unlock()
        return resolved
    }

    private func resolve(_ line: ScheduleLine, serviceDay: String, directionID: Int?) -> [ScheduledRun] {
        guard let midnight = Self.midnight(of: serviceDay, in: line.timeZone),
              let previousDay = Self.previousKey(of: serviceDay, in: line.timeZone) else {
            return []
        }
        var runs: [ScheduledRun] = []
        for direction in line.directions where directionID == nil || direction.id == directionID {
            runs.append(contentsOf: Self.runs(of: direction, dayType: line.dates[serviceDay], midnight: midnight))
            // A trip that left after midnight on the previous service day is
            // still running when this one starts.
            if let previousType = line.dates[previousDay],
               let previousMidnight = Self.midnight(of: previousDay, in: line.timeZone) {
                runs.append(contentsOf: Self.runs(of: direction, dayType: previousType, midnight: previousMidnight).filter {
                    $0.end > midnight
                })
            }
        }
        return runs.sorted { $0.start < $1.start }
    }

    private static func runs(of direction: ScheduleDirection, dayType: Int?, midnight: Date) -> [ScheduledRun] {
        guard let dayType, direction.dayTypes.indices.contains(dayType) else { return [] }
        return direction.dayTypes[dayType].compactMap { entry in
            guard direction.patterns.indices.contains(entry.pattern) else { return nil }
            return ScheduledRun(
                directionID: direction.id,
                headsign: direction.headsign,
                start: midnight.addingTimeInterval(Double(entry.start)),
                startSec: entry.start,
                pattern: direction.patterns[entry.pattern]
            )
        }
    }

    /// Midnight of a `"yyyyMMdd"` key, in the pack's zone.
    private static func midnight(of key: String, in timeZone: TimeZone) -> Date? {
        guard key.count == 8,
              let year = Int(key.prefix(4)),
              let month = Int(key.dropFirst(4).prefix(2)),
              let day = Int(key.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func previousKey(of key: String, in timeZone: TimeZone) -> String? {
        guard let midnight = midnight(of: key, in: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let previous = calendar.date(byAdding: .day, value: -1, to: midnight) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: previous)
        return String(
            format: "%04d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

// MARK: - Pack

/// The schedule pack: the tiny `index.json` plus one file per line, decoded on
/// first request and kept.
///
/// This type only decodes. Where the bytes come from is the caller's business
/// (`ScheduleStore` downloads and caches them; the tests hand them in), so the
/// app can publish a timetable without bundling it.
///
/// Loading a line decodes a few hundred kilobytes of JSON, so callers ask for
/// it off the main thread (the screens do it once, in their topology load) and
/// the pack hands back the same value afterwards. Everything mutable here is
/// the cache, guarded by its lock, so the pack is safe to share across
/// threads; there is no other concurrency machinery on purpose.
final class SchedulePack: @unchecked Sendable {
    /// Format version this code understands. A pack of any other version is
    /// refused instead of half understood.
    static let supportedVersion = 1

    /// `"yyyyMMdd"` of the first and last service date the pack covers, as
    /// delivered by `index.json`.
    let feedStart: String
    let feedEnd: String
    /// GTFS `feed_version` of the pack, when the builder wrote one. It changes
    /// whenever TMB publishes a new feed, which is what makes a cached line
    /// file stale.
    let feedVersion: String?
    /// ISO8601 instant the pack was built. Together with `feedVersion` it
    /// identifies the pack: a cache holding the same identity needs no rewrite.
    let generatedAt: String?
    /// Time zone every service day and `startSec` of the pack is expressed in.
    let timeZone: TimeZone

    private struct Entry {
        let mode: ScheduleMode
        let code: Int
        let file: String
    }

    private let entries: [Entry]
    private let loadFile: (String) -> Data?
    private let lock = NSLock()
    private var loaded: [String: ScheduleLine] = [:]

    /// - Parameters:
    ///   - index: contents of `index.json`.
    ///   - loadFile: called with a file name of the index (`"metro-94.json"`),
    ///     returns its bytes or nil when it is missing.
    init(index: Data, loadFile: @escaping (String) -> Data?) throws {
        let decoded = try JSONDecoder().decode(IndexFile.self, from: index)
        guard let zone = TimeZone(identifier: decoded.timezone) else {
            throw SchedulePackError.unknownTimeZone(decoded.timezone)
        }
        guard (decoded.v ?? Self.supportedVersion) == Self.supportedVersion else {
            throw SchedulePackError.unsupportedVersion(decoded.v ?? 0)
        }
        self.timeZone = zone
        self.feedStart = decoded.feedStart ?? ""
        self.feedEnd = decoded.feedEnd ?? ""
        self.feedVersion = decoded.feedVersion
        self.generatedAt = decoded.generatedAt
        self.loadFile = loadFile
        self.entries = decoded.lines.compactMap { line in
            guard let mode = ScheduleMode(rawValue: line.mode) else { return nil }
            return Entry(mode: mode, code: line.code, file: line.file)
        }
    }

    /// File of the pack that holds a line, without decoding it: this is what
    /// lets a caller download exactly the line it needs instead of the whole
    /// pack. Nil when the pack has no such line.
    func fileName(mode: ScheduleMode, code: Int) -> String? {
        entries.first { $0.mode == mode && $0.code == code }?.file
    }

    /// The line of the pack, decoded on first request. Nil when the pack has no
    /// such line or its file cannot be decoded.
    func line(mode: ScheduleMode, code: Int) -> ScheduleLine? {
        guard let entry = entries.first(where: { $0.mode == mode && $0.code == code }) else { return nil }
        lock.lock()
        if let cached = loaded[entry.file] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let data = loadFile(entry.file),
              let line = try? ScheduleLine.decode(data, timeZone: timeZone) else { return nil }

        lock.lock()
        loaded[entry.file] = line
        lock.unlock()
        return line
    }
}

// MARK: - Decoding shapes

/// `index.json`. Unknown keys are ignored by `Codable`, which is what keeps an
/// older app running against a newer pack.
private struct IndexFile: Decodable {
    let v: Int?
    let timezone: String
    let generatedAt: String?
    let feedStart: String?
    let feedEnd: String?
    let feedVersion: String?
    let lines: [Line]

    struct Line: Decodable {
        let mode: String
        let code: Int
        let file: String
    }
}

/// `<mode>-<code>.json`, the per-line file of the pack.
private struct LineFile: Decodable {
    let mode: String
    let code: Int
    let name: String
    let dates: [String: Int]
    let directions: [Direction]

    struct Direction: Decodable {
        let id: Int
        let headsign: String
        let patterns: [Pattern]
        /// `[[startSec, patternIndex], ...]` per day type.
        let dayTypes: [[[Int]]]
    }

    struct Pattern: Decodable {
        let stops: [Int]
        let arr: [Int]
        let dep: [Int]
    }
}
