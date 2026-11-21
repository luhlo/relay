// Existing Flutter PWAs still check this URL. Install the complete Relay shell
// through the same atomic cache path before replacing their previous worker.
importScripts('./relay-sw.js');
