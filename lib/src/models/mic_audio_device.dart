/// Audio devices as seen by the recorder.
///
/// The vocabulary unifies the Android `AudioDeviceInfo` and the iOS
/// `AVAudioSessionPortDescription` worlds into one set of values the input
/// priority ladder can reason about, plus decoders for both platforms'
/// native encodings.
library;

/// The kind of an audio device.
///
/// Values are shared between Android's `AudioDeviceInfo` types, iOS's
/// audio-session port types and the plugin's own device snapshot model.
enum MicAudioDeviceType {
  /// The device's built-in microphone.
  builtInMic,

  /// The device's built-in speaker.
  builtInSpeaker,

  /// A wired headset (headphones with a microphone).
  wiredHeadset,

  /// Headphones without a (listed) microphone.
  headphones,

  /// A USB audio device (microphone or interface).
  usbAudio,

  /// A Bluetooth HFP/SCO device.
  bluetoothSco,

  /// A Bluetooth LE audio device.
  bluetoothLe,

  /// A Bluetooth A2DP output (no microphone; doubles as a
  /// headset-connected signal).
  bluetoothA2dp,

  /// An analog line input.
  lineAnalog,

  /// A digital line input.
  lineDigital,

  /// A car audio connection.
  carAudio,

  /// Anything else (or an unmappable native code).
  unknown;

  /// Decodes an Android `AudioDeviceInfo.getType()` code.
  ///
  /// Unmapped codes decode to [MicAudioDeviceType.unknown]; [type] is the
  /// raw int exactly as the native layer reported it.
  static MicAudioDeviceType fromAndroidType(int type) {
    switch (type) {
      // TYPE_BUILTIN_SPEAKER
      case 2:
        return MicAudioDeviceType.builtInSpeaker;
      // TYPE_WIRED_HEADSET
      case 3:
        return MicAudioDeviceType.wiredHeadset;
      // TYPE_WIRED_HEADPHONES
      case 4:
        return MicAudioDeviceType.headphones;
      // TYPE_BLUETOOTH_SCO
      case 7:
        return MicAudioDeviceType.bluetoothSco;
      // TYPE_BLUETOOTH_A2DP
      case 8:
        return MicAudioDeviceType.bluetoothA2dp;
      // TYPE_USB_DEVICE
      case 11:
        return MicAudioDeviceType.usbAudio;
      // TYPE_USB_ACCESSORY
      case 12:
        return MicAudioDeviceType.usbAudio;
      // TYPE_BUILTIN_MIC
      case 15:
        return MicAudioDeviceType.builtInMic;
      // TYPE_LINE_ANALOG
      case 19:
        return MicAudioDeviceType.lineAnalog;
      // TYPE_LINE_DIGITAL
      case 20:
        return MicAudioDeviceType.lineDigital;
      // TYPE_USB_HEADSET
      case 22:
        return MicAudioDeviceType.usbAudio;
      // TYPE_BLE_HEADSET
      case 26:
        return MicAudioDeviceType.bluetoothLe;
      default:
        return MicAudioDeviceType.unknown;
    }
  }

  /// Decodes an iOS audio-session port type.
  ///
  /// A `Headphones` output port decodes to [MicAudioDeviceType.wiredHeadset]
  /// when [headphonesInputAvailable] reports that its uid is also a listed
  /// input (a headset's microphone makes it a wired headset) and to
  /// [MicAudioDeviceType.headphones] otherwise.
  static MicAudioDeviceType fromIosPortType(
    String portType, {
    bool headphonesInputAvailable = false,
  }) {
    switch (portType) {
      case 'BuiltInMic':
        return MicAudioDeviceType.builtInMic;
      case 'BuiltInSpeaker':
        return MicAudioDeviceType.builtInSpeaker;
      case 'HeadsetMic':
        return MicAudioDeviceType.wiredHeadset;
      case 'Headphones':
        return headphonesInputAvailable
            ? MicAudioDeviceType.wiredHeadset
            : MicAudioDeviceType.headphones;
      case 'USBAudio':
        return MicAudioDeviceType.usbAudio;
      case 'BluetoothHFP':
        return MicAudioDeviceType.bluetoothSco;
      case 'BluetoothLE':
        return MicAudioDeviceType.bluetoothLe;
      case 'LineIn':
        return MicAudioDeviceType.lineAnalog;
      case 'HDMI':
        return MicAudioDeviceType.lineDigital;
      case 'CarAudio':
        return MicAudioDeviceType.carAudio;
      default:
        return MicAudioDeviceType.unknown;
    }
  }
}

/// An audio device snapshot entry.
///
/// [id] is a stable string identity of the device on its platform (Android's
/// numeric device id stringified, or the iOS port uid); two entries with the
/// same id across two snapshots are the same device.
final class MicAudioDevice {
  /// Creates a device snapshot entry.
  const MicAudioDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isInput,
    required this.isOutput,
  });

  /// Stable platform identity of the device.
  final String id;

  /// Human-readable device name.
  final String name;

  /// The kind of device.
  final MicAudioDeviceType type;

  /// Whether the device can act as an audio input (a microphone).
  final bool isInput;

  /// Whether the device can act as an audio output (a speaker).
  final bool isOutput;

  @override
  bool operator ==(Object other) =>
      other is MicAudioDevice &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.isInput == isInput &&
      other.isOutput == isOutput;

  @override
  int get hashCode => Object.hash(id, name, type, isInput, isOutput);

  @override
  String toString() =>
      'MicAudioDevice(id: $id, name: $name, type: $type, '
      'isInput: $isInput, isOutput: $isOutput)';
}

/// An iOS audio-session input port description.
///
/// Mirrors `AVAudioSessionPortDescription`: [uid] identifies the port,
/// [portType] is the raw port type string (for example `BuiltInMic`,
/// `BluetoothHFP`, `USBAudio`) and [portName] is its human-readable name.
final class MicAudioInput {
  /// Creates a port description.
  const MicAudioInput({
    required this.uid,
    required this.portType,
    required this.portName,
  });

  /// The port's unique identifier.
  final String uid;

  /// The raw port type string.
  final String portType;

  /// The human-readable port name.
  final String portName;

  /// The port type decoded into the shared device vocabulary.
  MicAudioDeviceType get type => MicAudioDeviceType.fromIosPortType(portType);

  @override
  bool operator ==(Object other) =>
      other is MicAudioInput &&
      other.uid == uid &&
      other.portType == portType &&
      other.portName == portName;

  @override
  int get hashCode => Object.hash(uid, portType, portName);

  @override
  String toString() =>
      'MicAudioInput(uid: $uid, portType: $portType, portName: $portName)';
}

/// The current iOS audio-session route.
///
/// An empty route (the default when nothing is reported) means the session
/// has no input selected — the plugin treats that as "the OS decides".
final class MicAudioRoute {
  /// Creates a route snapshot.
  const MicAudioRoute({
    this.inputs = const <MicAudioInput>[],
    this.outputs = const <MicAudioInput>[],
  });

  /// The route's input ports (empty when the route has no input).
  final List<MicAudioInput> inputs;

  /// The route's output ports.
  final List<MicAudioInput> outputs;

  @override
  bool operator ==(Object other) =>
      other is MicAudioRoute &&
      _listEquals(other.inputs, inputs) &&
      _listEquals(other.outputs, outputs);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(inputs), Object.hashAll(outputs));

  @override
  String toString() => 'MicAudioRoute(inputs: $inputs, outputs: $outputs)';
}

bool _listEquals(List<MicAudioInput> a, List<MicAudioInput> b) {
  if (a.length != b.length) return false;

  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }

  return true;
}
