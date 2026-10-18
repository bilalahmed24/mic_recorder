import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Whether the recorder is currently treated as running on Android.
///
/// The value is computed once from the host platform and is safe to read on
/// any platform. It is a mutable variable on purpose: tests overwrite it to
/// emulate a platform without running on it.
bool micIsAndroid = !kIsWeb && Platform.isAndroid;

/// Whether the recorder is currently treated as running on iOS.
///
/// The value is computed once from the host platform and is safe to read on
/// any platform. It is a mutable variable on purpose: tests overwrite it to
/// emulate a platform without running on it.
bool micIsIOS = !kIsWeb && Platform.isIOS;
