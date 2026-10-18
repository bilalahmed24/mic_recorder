import 'dart:async';

/// A value holder that behaves like a seeded behavior stream.
///
/// New listeners receive the current [value] followed by every value added
/// afterwards, so a consumer attaching late never misses the latest state.
/// The wrapper replaces the `BehaviorSubject` a streams package would
/// provide — with zero dependencies.
///
/// The teardown paths follow two fake-async laws this plugin depends on for
/// deterministic tests:
///
/// * [close] is `void` (fire-and-forget): awaiting the close future of a
///   broadcast controller never completes under a fake event loop.
/// * The per-listener cancel hooks installed by [stream] never surface the
///   underlying subscription's cancel future, for the same reason.
final class SeededStream<T> {
  /// Creates a stream-seeded holder around [seed].
  SeededStream(T seed)
    : _value = seed,
      _events = StreamController<T>.broadcast(sync: true);

  final StreamController<T> _events;

  T _value;

  bool _isClosed = false;

  /// The latest value — the seed until the first [add].
  T get value => _value;

  /// Records [value] as the current value and delivers it to listeners.
  ///
  /// A no-op after [close].
  void add(T value) {
    if (_isClosed) return;

    _value = value;

    _events.add(value);
  }

  /// Delivers the current value to a new listener, then follows updates.
  ///
  /// The seed is delivered asynchronously (next event-loop turn): a value
  /// that arrives in the meantime supersedes it, so a listener never sees a
  /// stale seed ahead of a fresher real event. After [close], late
  /// listeners still receive the last value and then a done event.
  Stream<T> get stream => Stream<T>.multi((controller) {
    var seedPending = true;

    final subscription = _events.stream.listen(
      (event) {
        seedPending = false;

        controller.add(event);
      },
      onError: controller.addError,
      onDone: () {
        controller.close();
      },
    );

    // The seed rides a microtask — but only when no real value arrived
    // first: a synchronous delivery through the events controller
    // clears the pending flag, so the listener never sees a stale seed
    // ahead of a fresher real event.
    scheduleMicrotask(() {
      if (seedPending) controller.add(_value);
    });

    controller.onCancel = () {
      _cancelQuietly(subscription);
    };

    controller.onPause = () {
      subscription.pause();
    };

    controller.onResume = () {
      subscription.resume();
    };
  }, isBroadcast: true);

  /// Closes the stream (fire-and-forget, see the class documentation).
  ///
  /// Safe to call more than once. Adds afterwards are ignored.
  void close() {
    if (_isClosed) return;

    _isClosed = true;

    unawaited(_events.close());
  }
}

/// Forwards events from [source] until [terminator] emits, then stops.
///
/// The returned stream ends (a done event) as soon as the terminator fires
/// or the source completes. Cancelling the subscription cancels both
/// upstream subscriptions — fire-and-forget, so a consumer teardown never
/// depends on a cancel future resolving under a fake event loop.
Stream<T> takeUntil<T>(Stream<T> source, Stream<void> terminator) {
  return Stream<T>.multi((controller) {
    StreamSubscription<T>? sourceSubscription;
    StreamSubscription<void>? terminatorSubscription;

    var terminated = false;

    void stop() {
      if (terminated) return;

      terminated = true;

      _cancelQuietly(sourceSubscription);
      _cancelQuietly(terminatorSubscription);

      controller.close();
    }

    terminatorSubscription = terminator.listen((_) {
      stop();
    });

    sourceSubscription = source.listen(
      (event) {
        if (!terminated) controller.add(event);
      },
      onError: controller.addError,
      onDone: stop,
    );

    controller.onCancel = () {
      _cancelQuietly(sourceSubscription);
      _cancelQuietly(terminatorSubscription);
    };

    controller.onPause = () {
      sourceSubscription?.pause();
      terminatorSubscription?.pause();
    };

    controller.onResume = () {
      sourceSubscription?.resume();
      terminatorSubscription?.resume();
    };
  }, isBroadcast: true);
}

/// Cancels [subscription] without surfacing its cancel future (fake-async
/// law: broadcast cancel futures never resolve under a fake event loop).
void _cancelQuietly(StreamSubscription<dynamic>? subscription) {
  if (subscription == null) return;

  unawaited(subscription.cancel());
}
