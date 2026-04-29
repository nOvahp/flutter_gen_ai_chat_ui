// ─────────────────────────────────────────────────────────────
// AppConfig — change these to match your setup
// ─────────────────────────────────────────────────────────────
class AppConfig {
  AppConfig._();

  // ── Backend URL ───────────────────────────────────────────
  //
  // During development on a real device, use your computer's
  // local IP address (not localhost):
  //   Android emulator : http://10.0.2.2:3000
  //   iOS simulator    : http://localhost:3000
  //   Real device      : http://YOUR_COMPUTER_IP:3000
  //                      (find it with `ipconfig` or `ifconfig`)
  //
  static const String baseUrl = 'http://localhost:3000';
  //                                    ↑
  //                          Change this for real device

  // Auth token — our simple backend has no auth, set to null
  static const String? authToken = null;

  // ── Chat UI ───────────────────────────────────────────────
  static const int streamingWordDelayMs = 30;
  static const bool streamingWordByWord = true;
}
