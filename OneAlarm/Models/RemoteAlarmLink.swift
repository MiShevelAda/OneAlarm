import Foundation

/// Which remote alarm belongs to which OneAlarm routine.
///
/// Alex, 2026-08-16: *"OneAlarm is my one single source of truth for alarm setting... only the
/// modifications of temperature, vibration etc should be done in the respective app. So whenever I
/// change something on the routine or one time off, it should be done in the OneAlarm app and
/// should be written into the other apps."*
///
/// That goal is unreachable by day set matching alone, and this type is the reason why.
///
/// Matching by days answers "which alarm is this routine" only while the days agree. The moment he
/// changes a routine from Monday to Friday into Monday to Wednesday, the match evaporates: the
/// alarm that has been serving that routine for weeks stops being recognised, and the app either
/// creates a second one or reports a routine with no home. Either way his bed keeps the old days
/// forever, which is precisely the thing he is asking to stop doing by hand.
///
/// So ownership is **recorded** rather than inferred. Once a routine is linked to an alarm, that
/// alarm is OneAlarm's to author: its time, its days, and its on switch all follow the routine. An
/// alarm that has never been linked is never touched, so his own alarms stay his.
///
/// This is also what makes writing days safe again. Days were banned as a written field on
/// 2026-08-16 because one hand-picked alarm had to serve two routines, so every turn of the week
/// reshaped it, and that is how a real Monday to Friday schedule became every day. The ban was
/// never about days being sacred. It was about writing them to an alarm nobody had established was
/// ours. With a recorded owner there is exactly one routine per alarm and the ambiguity is gone.
///
/// Not a secret, so `UserDefaults` is the right home.
enum RemoteAlarmLink {
    private static func key(_ device: DeviceID) -> String {
        "OneAlarm.alarmLinks.\(device.rawValue)"
    }

    /// `routineID` to the remote alarm's id.
    static func all(for device: DeviceID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(device)) as? [String: String] ?? [:]
    }

    static func alarmID(for routineID: String, on device: DeviceID) -> String? {
        all(for: device)[routineID]
    }

    static func link(routine routineID: String, to alarmID: String, on device: DeviceID) {
        var links = all(for: device)
        // One alarm cannot serve two routines. If this alarm was another routine's, that claim is
        // dropped rather than duplicated, because two owners is how a routine's days get rewritten
        // by a routine that has nothing to do with it.
        for (existing, id) in links where id == alarmID && existing != routineID {
            links.removeValue(forKey: existing)
        }
        links[routineID] = alarmID
        UserDefaults.standard.set(links, forKey: key(device))
    }

    static func unlink(routine routineID: String, on device: DeviceID) {
        var links = all(for: device)
        links.removeValue(forKey: routineID)
        UserDefaults.standard.set(links, forKey: key(device))
    }

    /// Links whose routine no longer exists in OneAlarm.
    ///
    /// These alarms are still on his bed and still ours, so they cannot simply be forgotten: an
    /// abandoned alarm goes on firing on a morning he deleted the routine for. They are switched
    /// off rather than deleted, because OneAlarm has no delete on either service and is not getting
    /// one, and because switching off is a thing he can undo in the Eight Sleep app in one tap.
    static func orphans(for device: DeviceID, livingRoutines: Set<String>) -> [String: String] {
        all(for: device).filter { !livingRoutines.contains($0.key) }
    }

    static func forget(for device: DeviceID) {
        UserDefaults.standard.removeObject(forKey: key(device))
    }
}
