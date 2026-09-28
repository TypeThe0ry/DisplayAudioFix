import CoreGraphics

/// Detects whether macOS currently has any external display online.
///
/// CoreAudio can keep a stale DisplayPort UID alive after a monitor is
/// unplugged. The graphics display list is the authoritative connection
/// signal for deciding whether display-audio recovery is even applicable.
enum DisplayPresence {
    static func hasExternalDisplay() -> Bool {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        let result = CGGetOnlineDisplayList(
            UInt32(displayIDs.count),
            &displayIDs,
            &displayCount
        )
        guard result == .success else {
            // If WindowServer cannot answer, do not claim that a display is
            // connected. This prevents a stale monitor UID from being routed
            // while the graphics state is unavailable.
            return false
        }
        return displayIDs.prefix(Int(displayCount)).contains {
            CGDisplayIsBuiltin($0) == 0
        }
    }
}
