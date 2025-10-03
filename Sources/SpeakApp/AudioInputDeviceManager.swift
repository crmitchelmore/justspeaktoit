import AVFoundation
import CoreAudio
import os.log

@MainActor
final class AudioInputDeviceManager: ObservableObject {
  struct Device: Identifiable, Equatable {
    let id: String
    let deviceID: AudioDeviceID
    let name: String
    let manufacturer: String
    let channelCount: UInt32
    let nominalSampleRate: Double
    let isDefault: Bool

    var displayName: String {
      if manufacturer.isEmpty { return name }
      if name.localizedCaseInsensitiveContains(manufacturer) {
        return name
      }
      return "\(name) (\(manufacturer))"
    }

    var detailDescription: String {
      let channelsDescription = channelCount == 1 ? "1 channel" : "\(channelCount) channels"
      let formattedRate = String(format: "%.0f Hz", nominalSampleRate)
      return "\(channelsDescription) • \(formattedRate)"
    }
  }

  struct SessionContext {
    fileprivate let previousDeviceID: AudioDeviceID?
    fileprivate let didChangeDevice: Bool
  }

  static let systemDefaultToken = "__system_default_input__"

  @Published private(set) var devices: [Device] = []
  @Published private(set) var selectedDeviceUID: String?
  @Published private(set) var activeDeviceUID: String?

  private let appSettings: AppSettings
  private let logger = Logger(subsystem: "com.github.speakapp", category: "AudioInput")
  private var devicesListener: AudioObjectPropertyListenerBlock?
  private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

  init(appSettings: AppSettings) {
    self.appSettings = appSettings
    selectedDeviceUID = appSettings.preferredAudioInputUID
    refreshDevices()
    startObservingHardwareChanges()
  }

  deinit {
    let devicesListener = self.devicesListener
    let defaultDeviceListener = self.defaultDeviceListener
    self.devicesListener = nil
    self.defaultDeviceListener = nil

    Task { @MainActor in
      if let devicesListener {
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDevices,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          DispatchQueue.main,
          devicesListener
        )
      }

      if let defaultDeviceListener {
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDefaultInputDevice,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          DispatchQueue.main,
          defaultDeviceListener
        )
      }
    }
  }

  var currentSelectionDisplayName: String {
    if let uid = selectedDeviceUID, let device = device(for: uid) {
      return device.displayName
    }
    return systemDefaultDisplayName
  }

  var systemDefaultDisplayName: String {
    guard let active = activeDeviceUID, let device = device(for: active) else {
      return "System Default"
    }
    return device.displayName
  }

  var currentSelectionDetails: String? {
    if let uid = selectedDeviceUID, let device = device(for: uid) {
      return device.detailDescription
    }
    if let active = activeDeviceUID, let device = device(for: active) {
      return device.detailDescription
    }
    return nil
  }

  func refresh() {
    refreshDevices()
  }

  func selectDevice(uid: String?) {
    let normalizedUID = uid?.isEmpty == false ? uid : nil
    guard normalizedUID != selectedDeviceUID else { return }
    selectedDeviceUID = normalizedUID
    appSettings.preferredAudioInputUID = normalizedUID
  }

  func selectSystemDefault() {
    selectDevice(uid: nil)
  }

  func beginUsingPreferredInput() async -> SessionContext {
    let preferredUID = selectedDeviceUID ?? appSettings.preferredAudioInputUID
    guard
      let uid = preferredUID,
      let targetDeviceID = deviceID(forUID: uid),
      let currentDefaultID = currentDefaultInputDeviceID(),
      targetDeviceID != currentDefaultID
    else {
      return SessionContext(previousDeviceID: nil, didChangeDevice: false)
    }

    if setDefaultInputDevice(to: targetDeviceID) {
      refreshDevices()
      logger.debug("Activated preferred input device with UID \(uid, privacy: .public)")
      return SessionContext(previousDeviceID: currentDefaultID, didChangeDevice: true)
    }

    logger.error("Failed to activate preferred input \(uid, privacy: .public); continuing with system default")
    return SessionContext(previousDeviceID: nil, didChangeDevice: false)
  }

  func endUsingPreferredInput(session: SessionContext) async {
    guard session.didChangeDevice, let previous = session.previousDeviceID else {
      return
    }

    if setDefaultInputDevice(to: previous) {
      refreshDevices()
      logger.debug("Restored previous input device after session")
    } else {
      logger.error("Failed to restore previous input device after session")
    }
  }

  private func device(for uid: String) -> Device? {
    devices.first { $0.id == uid }
  }

  private func refreshDevices() {
    let defaultID = currentDefaultInputDeviceID()
    var results: [Device] = []

    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &dataSize
    ) == noErr else {
      logger.error("Unable to query audio device list size")
      return
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &dataSize,
      &deviceIDs
    ) == noErr else {
      logger.error("Unable to fetch audio device IDs")
      return
    }

    for identifier in deviceIDs {
      let channelCount = inputChannelCount(for: identifier)
      guard channelCount > 0 else { continue }
      guard let uid = stringProperty(
        selector: kAudioDevicePropertyDeviceUID,
        deviceID: identifier
      ) else { continue }

      let name = stringProperty(selector: kAudioObjectPropertyName, deviceID: identifier) ?? "Unknown"
      let manufacturer = stringProperty(
        selector: kAudioObjectPropertyManufacturer,
        deviceID: identifier
      ) ?? ""
      let sampleRate = doubleProperty(
        selector: kAudioDevicePropertyNominalSampleRate,
        deviceID: identifier
      ) ?? 44_100

      let device = Device(
        id: uid,
        deviceID: identifier,
        name: name,
        manufacturer: manufacturer,
        channelCount: channelCount,
        nominalSampleRate: sampleRate,
        isDefault: identifier == defaultID
      )
      results.append(device)
    }

    results.sort { lhs, rhs in
      if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    devices = results
    activeDeviceUID = results.first(where: { $0.isDefault })?.id

    if let selection = selectedDeviceUID, !results.contains(where: { $0.id == selection }) {
      selectedDeviceUID = nil
      appSettings.preferredAudioInputUID = nil
    }
  }

  private func startObservingHardwareChanges() {
    let queue = DispatchQueue.main

    var devicesAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    devicesListener = { [weak self] _, _ in
      self?.refreshDevices()
    }

    if let devicesListener {
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &devicesAddress,
        queue,
        devicesListener
      )
    }

    var defaultAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    defaultDeviceListener = { [weak self] _, _ in
      self?.refreshDevices()
    }

    if let defaultDeviceListener {
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &defaultAddress,
        queue,
        defaultDeviceListener
      )
    }
  }

  private func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else {
      return 0
    }

    let rawPointer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else {
      return 0
    }

    let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    var channels: UInt32 = 0
    for buffer in buffers {
      channels += buffer.mNumberChannels
    }
    return channels
  }

  private func currentDefaultInputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID()
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    ) == noErr else {
      return nil
    }

    return deviceID
  }

  private func setDefaultInputDevice(to deviceID: AudioDeviceID) -> Bool {
    if let current = currentDefaultInputDeviceID(), current == deviceID {
      return true
    }

    var mutableDeviceID = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &mutableDeviceID
    )

    if status != noErr {
      logger.error("AudioObjectSetPropertyData returned \(status)")
      return false
    }
    return true
  }

  private func deviceID(forUID uid: String) -> AudioDeviceID? {
    var uidChars = Array(uid.utf8CString)
    var deviceID = AudioDeviceID()
    let status = uidChars.withUnsafeMutableBufferPointer { buffer -> OSStatus in
      guard let baseAddress = buffer.baseAddress else { return kAudioHardwareBadDeviceError }
      return withUnsafeMutablePointer(to: &deviceID) { devicePointer in
        var translation = AudioValueTranslation(
          mInputData: UnsafeMutableRawPointer(baseAddress),
          mInputDataSize: UInt32(buffer.count),
          mOutputData: UnsafeMutableRawPointer(devicePointer),
          mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          &translationSize,
          &translation
        )
      }
    }

    guard status == noErr else { return nil }
    return deviceID
  }

  private func stringProperty(
    selector: AudioObjectPropertySelector,
    deviceID: AudioDeviceID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var cfString: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &cfString) { pointer -> OSStatus in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return cfString as String
  }

  private func doubleProperty(
    selector: AudioObjectPropertySelector,
    deviceID: AudioDeviceID
  ) -> Double? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var value = Double(0)
    var size = UInt32(MemoryLayout<Double>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
  }
}
