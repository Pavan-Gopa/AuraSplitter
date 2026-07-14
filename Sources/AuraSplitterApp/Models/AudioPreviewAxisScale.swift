import Foundation

struct AudioPreviewAxisTick: Equatable {
    let db: Double
    let label: String
    let isMajor: Bool

    var amplitudeFraction: Double {
        pow(10, db / 20)
    }
}

enum AudioPreviewAxisScale {
    static let majorDecibels: [Double] = [0, -1, -2, -3, -4, -5, -6, -8, -10, -12, -20, -24]
    static let minorDecibels: [Double] = [-0.5, -1.5, -2.5, -3.5, -4.5, -5.5, -7, -9, -11, -14, -16, -18, -22]

    static let decibelTicks: [AudioPreviewAxisTick] = {
        let major = majorDecibels.map { db in
            AudioPreviewAxisTick(db: db, label: formattedLabel(for: db), isMajor: true)
        }
        let minor = minorDecibels.map { db in
            AudioPreviewAxisTick(db: db, label: "", isMajor: false)
        }
        return (major + minor).sorted { lhs, rhs in
            if lhs.db == rhs.db {
                return lhs.isMajor && !rhs.isMajor
            }
            return lhs.db > rhs.db
        }
    }()

    private static func formattedLabel(for db: Double) -> String {
        let rounded = Int(db.rounded())
        return "\(rounded)"
    }
}
