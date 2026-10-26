import AppKit
import CoreAudio
import LocalFlowCore

/// Two read-only questions about the machine: is somebody holding the microphone, and is an
/// application people hold calls in running.
///
/// Neither opens the microphone, and neither needs a permission. `DeviceIsRunningSomewhere` is a
/// property of the device, answerable without touching the stream, which is the whole reason this
/// is the signal and not, say, listening for speech.
enum AudioActivity {
    static func inputIsBusy() -> Bool {
        guard let device = defaultInput() else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func conferencingIsRunning() -> Bool {
        MeetingWatch.isConferencing(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }
}
