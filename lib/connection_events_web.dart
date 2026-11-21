import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Stream<void> connectionRestoredEvents() {
  late StreamController<void> events;
  final callback = ((web.Event event) => events.add(null)).toJS;
  events = StreamController<void>.broadcast(
    onListen: () => web.window.addEventListener('online', callback),
    onCancel: () => web.window.removeEventListener('online', callback),
  );
  return events.stream;
}
