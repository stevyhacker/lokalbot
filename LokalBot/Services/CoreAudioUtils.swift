import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Anything Core Audio knows about a running process that owns audio.
/// Hashable / Equatable on `objectID` only so SwiftUI Pickers keep matching
/// after a refresh that flips `isRunningOutput`.
struct AudioProcess: Identifiable, Equatable, Hashable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let objectID: AudioObjectID
    var isRunningOutput: Bool

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: id)?.icon
    }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.objectID == rhs.objectID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(objectID)
    }
}

enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let code, let label):
            return "Core Audio \(label) failed (\(code))."
        case .noData(let label):
            return "Core Audio \(label) returned no data."
        }
    }
}

/// Thin wrappers over the `AudioObjectGetPropertyData` calls we need so the
/// recorder/detector code reads like Swift instead of a thicket of pointer
/// dances. Modeled on Seminarly's `CoreAudioUtils` (adapted for LokalBot —
/// adds `isDefaultInputRunning` for the mic-in-use signal the detector
/// already depended on, inline).
enum CoreAudioUtils {

    // MARK: - Process objects

    /// Every Core Audio process AudioObjectID currently known to the system.
    static func getProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard err == noErr else { throw CoreAudioError.osStatus(err, "getProcessList size") }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        guard err == noErr else { throw CoreAudioError.osStatus(err, "getProcessList data") }
        return ids
    }

    static func getProcessPID(objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return err == noErr && pid > 0 ? pid : nil
    }

    static func isProcessRunningOutput(objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return err == noErr && isRunning == 1
    }

    /// Core Audio returns the CFString +1 (Create Rule); take it as
    /// `Unmanaged` so ownership is explicit — passing `&CFString` is flagged
    /// unsafe because it forms a raw pointer to an ARC-managed reference.
    static func getProcessBundleID(objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bundleID)
        guard err == noErr, let bundleID else { return nil }
        return bundleID.takeRetainedValue() as String
    }

    /// PID → process AudioObjectID. Returns nil when no Core Audio object is
    /// associated with the PID (the process opened no audio devices).
    static func translatePIDToProcessObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var processObject: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePID = pid
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePID,
            &size, &processObject)
        guard err == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }

    static func listAudioProcesses() throws -> [AudioProcess] {
        let ids = try getProcessList()
        return ids.compactMap { objectID in
            guard let pid = getProcessPID(objectID: objectID) else { return nil }
            let bundleID = getProcessBundleID(objectID: objectID)
            let running = isProcessRunningOutput(objectID: objectID)
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? bundleID ?? "PID \(pid)"
            return AudioProcess(id: pid, name: name, bundleID: bundleID,
                                objectID: objectID, isRunningOutput: running)
        }
    }

    // MARK: - Default input/output devices

    static func getDefaultInputDeviceID() throws -> AudioDeviceID {
        try defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice,
                          label: "getDefaultInputDevice")
    }

    static func getDefaultOutputDeviceID() throws -> AudioDeviceID {
        try defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice,
                          label: "getDefaultOutputDevice")
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector,
                                      label: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr else { throw CoreAudioError.osStatus(err, label) }
        return deviceID
    }

    /// Is *any* process currently using the default input device?
    /// Replaces the inline implementation that used to live in
    /// `MeetingDetector.isMicInUse()`.
    static func isDefaultInputRunning() -> Bool {
        guard let device = try? getDefaultInputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isRunning)
        return err == noErr && isRunning == 1
    }

    /// True iff the current default output device is the laptop's built-in
    /// speaker — useful to surface a "wear headphones to avoid echo" warning.
    static func isOutputBuiltInSpeaker() -> Bool {
        guard let device = try? getDefaultOutputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return err == noErr && transport == kAudioDeviceTransportTypeBuiltIn
    }

    static func getDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard err == noErr else { throw CoreAudioError.osStatus(err, "getDeviceUID") }
        guard let uid else { throw CoreAudioError.noData("getDeviceUID") }
        return uid.takeRetainedValue() as String
    }
}
