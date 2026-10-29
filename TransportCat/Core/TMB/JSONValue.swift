import Foundation

/// Tolerant JSON access helpers shared by all TMB parsers.
enum JSONValue {
    /// Extracts the first integer embedded in a value that may be an Int, a
    /// Double, or a String ("2", "2 min", "Aprox.", "—"). Returns nil when no
    /// number can be extracted.
    static func int(from any: Any?) -> Int? {
        switch any {
        case let number as Int:
            return number
        case let number as Double:
            return Int(number)
        case let string as String:
            return firstInt(in: string)
        default:
            return nil
        }
    }

    static func firstInt(in string: String) -> Int? {
        let digits = string.split(whereSeparator: { !("0"..."9" ~= $0) }).first
        guard let digits, let value = Int(digits) else { return nil }
        return value
    }

    static func string(from any: Any?) -> String? {
        switch any {
        case let string as String:
            return string
        case let number as Int:
            return String(number)
        default:
            return nil
        }
    }

    static func double(from any: Any?) -> Double? {
        switch any {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let string as String:
            return Double(string.replacingOccurrences(of: ",", with: "."))
        default:
            return nil
        }
    }

    static func dateMilliseconds(from any: Any?) -> Date? {
        guard let millis = int(from: any) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
    }

    static func dictionary(from any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(from any: Any?) -> [Any]? {
        any as? [Any]
    }
}
