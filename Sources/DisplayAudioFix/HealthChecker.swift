import AudioToolbox
import CoreAudio
import Foundation

private final class ProbeContext {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callbackCount = 0

    func bufferCompleted() {
        lock.lock()
        callbackCount += 1
        let shouldSignal = callbackCount == 1
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }
}

private final class ProbeResultBox {
    private let lock = NSLock()
    private var value: HealthStatus?

    func set(_ result: HealthStatus) {
        lock.lock(); value = result; lock.unlock()
    }

    func get() -> HealthStatus? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private let audioQueueOutputCallback: AudioQueueOutputCallback = { userData, _, _ in
    guard let userData else { return }
    Unmanaged<ProbeContext>.fromOpaque(userData).takeUnretainedValue().bufferCompleted()
}

final class HealthChecker {
    private let timelineFailureStatus = OSStatus(bitPattern: 1_937_010_544)

    func test(device: AudioDeviceInfo?, timeout: TimeInterval, audible: Bool) -> HealthStatus {
        // AudioQueueStart itself can block for CoreAudio's 10-second timeline wait.
        // Keep the public probe bounded independently of every CoreAudio call.
        let completion = DispatchSemaphore(value: 0)
        let resultBox = ProbeResultBox()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            resultBox.set(performTest(device: device, timeout: timeout, audible: audible))
            completion.signal()
        }
        guard completion.wait(timeout: .now() + max(timeout, 0.25)) == .success else {
            return .timelineTimeout
        }
        return resultBox.get() ?? .timelineTimeout
    }

    private func performTest(device: AudioDeviceInfo?, timeout: TimeInterval, audible: Bool) -> HealthStatus {
        guard let device else { return .deviceMissing }
        guard device.outputChannels > 0 else { return .deviceMissing }
        if device.isAlive == false { return .deviceNotRunning }

        let sampleRate = device.sampleRate > 0 ? device.sampleRate : 48_000
        let channels = max(1, min(device.outputChannels, 2))
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let context = ProbeContext()
        let retained = Unmanaged.passRetained(context)
        defer { retained.release() }
        var queue: AudioQueueRef?
        var status = AudioQueueNewOutput(
            &format, audioQueueOutputCallback, retained.toOpaque(),
            nil, nil, 0, &queue
        )
        guard status == noErr, let queue else { return classify(status) }
        defer { AudioQueueDispose(queue, true) }

        let uid: CFString = device.uid as CFString
        var uidReference = Unmanaged.passUnretained(uid)
        status = AudioQueueSetProperty(
            queue, kAudioQueueProperty_CurrentDevice,
            &uidReference, UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        )
        guard status == noErr else { return classify(status) }

        let duration = audible ? 0.20 : 0.08
        let frames = max(256, Int(sampleRate * duration))
        let byteCount = UInt32(frames * 4)
        for _ in 0..<2 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queue, byteCount, &buffer)
            guard status == noErr, let buffer else { return classify(status) }
            buffer.pointee.mAudioDataByteSize = byteCount
            if audible {
                fillTone(buffer: buffer, frames: frames, channels: channels, sampleRate: sampleRate)
            } else {
                memset(buffer.pointee.mAudioData, 0, Int(byteCount))
            }
            status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            guard status == noErr else { return classify(status) }
        }

        status = AudioQueueStart(queue, nil)
        guard status == noErr else { return classify(status) }
        let waitResult = context.semaphore.wait(timeout: .now() + timeout)
        AudioQueueStop(queue, true)
        return waitResult == .success ? .healthy : .timelineTimeout
    }

    private func classify(_ status: OSStatus) -> HealthStatus {
        status == timelineFailureStatus ? .timelineTimeout : .startFailed(status)
    }

    private func fillTone(buffer: AudioQueueBufferRef, frames: Int, channels: Int, sampleRate: Double) {
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        let amplitude = Double(Int16.max) * 0.08
        for frame in 0..<frames {
            let value = Int16(sin(2.0 * .pi * 880.0 * Double(frame) / sampleRate) * amplitude)
            for channel in 0..<channels {
                samples[frame * channels + channel] = value
            }
        }
    }
}
