import Foundation

/// Parses the strict ISO-8601 form git emits for `%aI`, e.g. `2024-01-15T13:45:30+01:00`.
///
/// `ISO8601DateFormatter` handles this correctly but costs roughly a microsecond per call
/// and is a shared-state object; over a few hundred thousand commits that is measurable
/// and awkward to use off the main thread. This is a direct fixed-format parse.
enum ISO8601 {
    static func parse(_ string: String) -> Date? {
        let b = Array(string.utf8)
        // Shortest valid form: 2024-01-15T13:45:30Z
        guard b.count >= 20 else { return nil }

        func int(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for i in start..<(start + length) {
                guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                value = value * 10 + Int(b[i] - 0x30)
            }
            return value
        }

        guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
              let year = int(0, 4), let month = int(5, 2), let day = int(8, 2),
              let hour = int(11, 2), let minute = int(14, 2), let second = int(17, 2),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var offset = 0
        let sign = b[19]
        if sign == 0x2B || sign == 0x2D {
            guard b.count >= 25, b[22] == 0x3A,
                  let oh = int(20, 2), let om = int(23, 2) else { return nil }
            offset = oh * 3600 + om * 60
            if sign == 0x2D { offset = -offset }
        } else if sign != 0x5A { // 'Z'
            return nil
        }

        let epochDay = daysFromCivil(year: year, month: month, day: day)
        let seconds = epochDay * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                  // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy          // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}
