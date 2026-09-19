import Foundation
import IOKit
import IOKit.pwr_mgt

// IOMessage.h defines these through a C macro that Swift cannot import.
private let messageCanSystemSleep: UInt32 = 0xe000_0270
private let messageSystemWillSleep: UInt32 = 0xe000_0280
private let messageSystemHasPoweredOn: UInt32 = 0xe000_0300

private let powerCallback: IOServiceInterestCallback = { refCon, _, messageType, messageArgument in
    guard let refCon else { return }
    let monitor = Unmanaged<PowerMonitor>.fromOpaque(refCon).takeUnretainedValue()
    monitor.handle(messageType: messageType, argument: messageArgument)
}

final class PowerMonitor {
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private let onWake: () -> Void

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
    }

    func start() {
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(opaque, &notificationPort, powerCallback, &notifier)
        guard rootPort != 0, let notificationPort else {
            AppLogger.shared.log("warning: unable to register for sleep/wake notifications")
            return
        }
        let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case messageSystemWillSleep, messageCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case messageSystemHasPoweredOn:
            AppLogger.shared.log("system wake detected")
            onWake()
        default:
            break
        }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        if rootPort != 0 { IOServiceClose(rootPort) }
    }
}
