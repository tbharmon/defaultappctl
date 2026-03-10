//
//  DefaultAppCtl.swift
//
//  -----------------------------------------------------------------------------
//  PURPOSE
//  -----------------------------------------------------------------------------
//  This tool applies default application handler mappings on macOS 12+ using
//  Apple-supported NSWorkspace APIs:
//
//    • URL scheme defaults (e.g., http, mailto)
//    • UTType / UTI defaults (e.g., com.adobe.pdf)
//
//  The tool is designed for enterprise deployment via a PKG where:
//
//    1) PKG postinstall runs as root (mode=root)
//    2) A follow-up run may be required in the logged-in user GUI context (mode=user)
//
//  IMPORTANT PRACTICAL NOTE (based on observed behavior):
//  -----------------------------------------------------------
//  Default handler state can differ between root and the logged-in user.
//  Testing demonstrated that PDFs could be defaulted to Acrobat for root while
//  remaining Preview for the user. That’s why this CLI supports both modes and
//  why postinstall ultimately had to run the tool in the user GUI context.
//
//  -----------------------------------------------------------------------------
//  BUILD / COMPILER NOTE
//  -----------------------------------------------------------------------------
//  This file uses @main (structured entry point).
//  When compiling with swiftc, pass: -parse-as-library
//
//  Without that flag, swiftc may interpret the file in a “script-like” mode that
//  conflicts with @main and produces:
//    "'main' attribute cannot be used in a module that contains top-level code"
//
//  -----------------------------------------------------------------------------
//  LOGGING + STATE
//  -----------------------------------------------------------------------------
//  • The tool logs progress to a caller-specified log file (append-only).
//  • The tool writes a JSON “state” file containing failures (if any).
//  • On full success, it removes the state file (best-effort), allowing callers
//    to treat presence of state.json as “something failed”.
//
//  -----------------------------------------------------------------------------
//  EXIT CODES (contract for callers)
//  -----------------------------------------------------------------------------
//   0  = success; all requested mappings applied
//  20  = failures occurred in root mode (caller should retry once in user GUI session)
//  21  = failures occurred in user mode (final failures; caller should stop retrying)
//  10  = macOS too old (< 12.0)
//  11  = invalid arguments
//  12  = configuration file could not be loaded/decoded
//
//  -----------------------------------------------------------------------------
//  SECURITY/SAFETY NOTES
//  -----------------------------------------------------------------------------
//  • No network access.
//  • No shelling out.
//  • Uses bundle identifiers (resolved via NSWorkspace) rather than paths.
//  • Best-effort logging: log failure should never stop policy application.
//  • Continues applying remaining mappings even if one fails.
//  • Deterministic order: mappings are sorted so logs are stable across runs.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Configuration model

/// JSON configuration schema.
///
/// Example:
/// {
///   "urls": {
///     "mailto": "com.microsoft.Outlook",
///     "http": "com.google.Chrome"
///   },
///   "types": {
///     "com.adobe.pdf": "com.adobe.Acrobat.Pro"
///   }
/// }
///
/// Notes:
/// - `urls` keys are URL schemes WITHOUT a colon (use "http" not "http:")
/// - `types` keys are UTI strings (UTType identifiers), e.g. "com.adobe.pdf"
/// - Values are application bundle identifiers.
struct Config: Decodable {
  let urls: [String:String]?
  let types: [String:String]?
}

// MARK: - Execution mode

/// Execution mode. This does NOT change logic; it changes exit-code semantics.
///
/// - root:  failures should typically trigger a follow-up attempt in user mode
/// - user:  failures are final (no more retries)
enum Mode: String { case root, user }

// MARK: - Failure telemetry (state file)

/// Indicates which category failed: a scheme or a type.
enum ApplyKind: String, Codable { case url, type }

/// One failure record stored in the state file.
struct FailedItem: Codable {
  let kind: ApplyKind
  let key: String        // scheme name or UTI identifier
  let bundleID: String   // desired handler bundle identifier
  let message: String    // error summary
}

/// State file payload: only failures are recorded.
/// Successes are written to log + stdout.
struct State: Codable {
  var failed: [FailedItem]
}

// MARK: - Logging helpers

/// Print to stderr. Useful for human diagnostics while keeping stdout clean.
func eprint(_ s: String) { fputs(s + "\n", stderr) }

/// Append a timestamped line to the log file.
func logLine(_ logPath: String, _ line: String) {
  let stamp = ISO8601DateFormatter().string(from: Date())
  let msg = "[\(stamp)] \(line)\n"
  guard let data = msg.data(using: .utf8) else { return }

  let url = URL(fileURLWithPath: logPath)

  if FileManager.default.fileExists(atPath: logPath) {
    // Append mode
    if let fh = try? FileHandle(forWritingTo: url) {
      // seekToEnd()/close() are throwing; we intentionally ignore failures.
      try? fh.seekToEnd()
      try? fh.write(contentsOf: data)
      try? fh.close()
    }
  } else {
    // Create atomically on first write
    try? data.write(to: url, options: .atomic)
  }
}

// MARK: - Config + state IO

/// Load and decode the JSON configuration file.
func loadConfig(_ path: String) throws -> Config {
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  return try JSONDecoder().decode(Config.self, from: data)
}

/// Save failures to the state file.
func saveState(_ path: String, _ state: State) {
  if let data = try? JSONEncoder().encode(state) {
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

/// Remove state file. Used when run is fully successful.
func removeState(_ path: String) {
  try? FileManager.default.removeItem(atPath: path)
}

// MARK: - App resolution

/// Resolve a bundle identifier to an installed application URL.
/// Returns nil if the bundle ID is not found/registered.
func appURL(forBundleID bid: String) -> URL? {
  NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
}

// MARK: - Apply operations (macOS 12+)

/// Set default handler for a URL scheme (http, mailto, etc.).
@available(macOS 12.0, *)
func setScheme(_ scheme: String, appURL: URL) async throws {
  try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
}

/// Set default handler for a UTType identifier (com.adobe.pdf, public.vcard, etc.).
@available(macOS 12.0, *)
func setUTI(_ uti: String, appURL: URL) async throws {
  // Convert string to UTType; nil means invalid/unknown identifier on this OS.
  guard let type = UTType(uti) else { throw NSError(domain: "DefaultAppCtl", code: 3) }
  try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
}

// MARK: - CLI usage

func usage() {
  eprint("Usage: defaultappctl --apply --mode root|user --config <path> --state <path> --log <path>")
}

// MARK: - Entry point

@main
struct DefaultAppCtl {
  static func main() async {

    // The NSWorkspace setters we use are available on macOS 12+.
    guard #available(macOS 12.0, *) else {
      eprint("macOS 12+ required for NSWorkspace setDefaultApplication APIs.")
      exit(10)
    }

    // --- Argument parsing ---
    let args = CommandLine.arguments

    /// Returns the value immediately after a named flag, e.g. "--config /path".
    func argValue(_ name: String) -> String? {
      guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
      return args[idx + 1]
    }

    guard args.contains("--apply"),
          let modeStr = argValue("--mode"),
          let mode = Mode(rawValue: modeStr),
          let cfgPath = argValue("--config"),
          let statePath = argValue("--state"),
          let logPath = argValue("--log") else {
      usage(); exit(11)
    }

    logLine(logPath, "START mode=\(modeStr) config=\(cfgPath) state=\(statePath)")

    // --- Load configuration ---
    let cfg: Config
    do {
      cfg = try loadConfig(cfgPath)
    } catch {
      eprint("ERROR: config load failed: \(error)")
      logLine(logPath, "ERROR config load failed: \(error)")
      exit(12)
    }

    // Collect failures while continuing to process everything.
    var state = State(failed: [])

    func recordFail(kind: ApplyKind, key: String, bundleID: String, message: String) {
      state.failed.append(FailedItem(kind: kind, key: key, bundleID: bundleID, message: message))
      logLine(logPath, "FAIL \(kind.rawValue) \(key) -> \(bundleID): \(message)")
    }

    func recordOK(_ line: String) {
      print(line)
      logLine(logPath, line)
    }

    // Deterministic ordering for stable logs and easier troubleshooting.
    let urlItems = (cfg.urls ?? [:]).sorted { $0.key < $1.key }
    let typeItems = (cfg.types ?? [:]).sorted { $0.key < $1.key }

    // Cache app URL resolutions by bundle ID to avoid repeated NSWorkspace lookups.
    var appCache: [String: URL] = [:]
    func resolveApp(_ bid: String) -> URL? {
      if let cached = appCache[bid] { return cached }
      if let url = appURL(forBundleID: bid) {
        appCache[bid] = url
        return url
      }
      return nil
    }

    logLine(logPath, "INFO mappings urls=\(urlItems.count) types=\(typeItems.count)")

    // Apply URL schemes. We prioritize http/https first because browser defaults
    // tend to be the most visible to users and can be coupled by the OS.
    let prioritizedSchemes = ["http", "https"]
    var urlQueue: [(String,String)] = []
    var seen = Set<String>()

    for s in prioritizedSchemes {
      if let bid = cfg.urls?[s] { urlQueue.append((s,bid)); seen.insert(s) }
    }
    for (scheme, bid) in urlItems where !seen.contains(scheme) { urlQueue.append((scheme,bid)) }

    // --- Apply URL scheme mappings ---
    for (scheme, bid) in urlQueue {
      logLine(logPath, "INFO applying url scheme=\(scheme) bundleID=\(bid)")

      guard let app = resolveApp(bid) else {
        recordFail(kind: .url, key: scheme, bundleID: bid, message: "bundle id not found")
        continue
      }

      logLine(logPath, "INFO resolved bundleID=\(bid) appURL=\(app.path)")

      do {
        try await setScheme(scheme, appURL: app)
        recordOK("OK url  \(scheme) -> \(bid)")
      } catch {
        recordFail(kind: .url, key: scheme, bundleID: bid, message: String(describing: error))
      }
    }

    // --- Apply content-type (UTI/UTType) mappings ---
    for (uti, bid) in typeItems {
      logLine(logPath, "INFO applying type uti=\(uti) bundleID=\(bid)")

      guard let app = resolveApp(bid) else {
        recordFail(kind: .type, key: uti, bundleID: bid, message: "bundle id not found")
        continue
      }

      logLine(logPath, "INFO resolved bundleID=\(bid) appURL=\(app.path)")

      do {
        try await setUTI(uti, appURL: app)
        recordOK("OK type \(uti) -> \(bid)")
      } catch {
        recordFail(kind: .type, key: uti, bundleID: bid, message: String(describing: error))
      }
    }

    // --- Finalize state + exit code semantics ---
    if state.failed.isEmpty {
      // Remove any stale state file so callers can treat existence as “had failures”.
      removeState(statePath)
      logLine(logPath, "DONE success")
      exit(0)
    }

    // Persist failures for troubleshooting / automation decisions.
    saveState(statePath, state)
    logLine(logPath, "DONE failures=\(state.failed.count)")

    // root failures should trigger a retry in user mode; user failures are final.
    if mode == .root { exit(20) }
    exit(21)
  }
}      logLine(logPath, "DONE success")
      exit(0)
    }

    saveState(statePath, state)
    logLine(logPath, "DONE failures=\(state.failed.count)")

    if mode == .root { exit(20) }
    exit(21)
  }
}
