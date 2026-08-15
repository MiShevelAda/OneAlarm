import Foundation

enum DeviceID: String, Codable, CaseIterable, Sendable, Identifiable {
    case iphone
    case eightSleep
    case whoop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iphone: return "iPhone"
        case .eightSleep: return "Eight Sleep"
        case .whoop: return "Whoop"
        }
    }

    /// What the offset is for, in one line, shown under the device name.
    var rationale: String {
        switch self {
        case .iphone: return "The loud backstop. Also rings on the Apple Watch."
        case .eightSleep: return "Thermal and vibration ramp needs a run up."
        case .whoop: return "Haptic smart wake window."
        }
    }

    var symbolName: String {
        switch self {
        case .iphone: return "iphone"
        case .eightSleep: return "bed.double.fill"
        case .whoop: return "applewatch"
        }
    }

    /// Whether the leg needs credentials before it can do anything.
    var requiresCredentials: Bool {
        switch self {
        case .iphone: return false
        case .eightSleep, .whoop: return true
        }
    }
}

struct DeviceRule: Codable, Equatable, Sendable, Identifiable {
    var device: DeviceID
    /// Negative is earlier than the master time. Eight Sleep defaults to -10, Whoop to -5.
    var offsetMinutes: Int
    var isEnabled: Bool
    /// When set, this device uses its own days instead of the master's.
    var weekdayOverrideIndices: [Int]?

    var id: String { device.rawValue }

    var weekdayOverride: Set<Locale.Weekday>? {
        get { weekdayOverrideIndices.map(WeekdaySetCoding.decode) }
        set { weekdayOverrideIndices = newValue.map(WeekdaySetCoding.encode) }
    }
}

/// Master wake time plus the per device rules. The single source of truth: edit `masterTime` once
/// and every enabled device recomputes.
struct WakeSchedule: Codable, Equatable, Sendable {
    var masterTime: WallClockTime
    var weekdayIndices: [Int]
    var rules: [DeviceRule]

    var weekdays: Set<Locale.Weekday> {
        get { WeekdaySetCoding.decode(weekdayIndices) }
        set { weekdayIndices = WeekdaySetCoding.encode(newValue) }
    }

    static let `default` = WakeSchedule(
        masterTime: WallClockTime(hour: 7, minute: 0),
        weekdayIndices: WeekdaySetCoding.encode(Locale.Weekday.weekdaysOnly),
        rules: [
            DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true, weekdayOverrideIndices: nil),
            DeviceRule(device: .whoop, offsetMinutes: -5, isEnabled: true, weekdayOverrideIndices: nil),
            DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil),
        ]
    )

    func rule(for device: DeviceID) -> DeviceRule? {
        rules.first { $0.device == device }
    }
}
