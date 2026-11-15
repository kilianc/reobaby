import Foundation
import ReoBabyKit

// `reobaby`: ReoBabyKit from the command line. Each command is a `Probe` function; this file only
// reads the arguments. Settings named after them (`-audioBoost 30`) apply to this run only.

let usage = """
reobaby: your Reolink cameras from the command line. Local only, no cloud.

Usage: reobaby <command> [arguments]

Cameras
  list                                     The cameras in cameras.json, numbered
  discover                                 Reolink cameras on the local network
  api <camera> <Command> [json] [action]   One command of the camera's HTTP API
  api-poll <camera> <commands> [seconds]   Several at once; with seconds, once a second
  ptz <camera> [command]                   Pan, tilt and zoom; `reobaby ptz <camera> help`

Picture and sound (macOS; on Linux, probe counts packets without decoding)
  probe <camera> [seconds]                 Connect and report codecs, frame rate and errors
  monitor <camera> [seconds]               Sound levels and detection events, live
  record <camera> <seconds> <out.wav>      A camera's sound, as it arrives
  process <in.wav> [out.wav]               A recording through ReoBaby's sound processing

Soothing sounds
  soothe <camera | mac> <seconds> [steps]  Steps played in turn, each for the seconds given
  soothe-check                             Every change glides: offline and silent
  soothe-app-check                         The app's paths on stand-in speakers: about 2 minutes

<camera> is a name, a number from `reobaby list`, or an rtsp:// URL.
Cameras come from ~/.config/reobaby/cameras.json, or REOBABY_CONFIG_DIR.
Settings go last, as `-audioBoost 30`, and don't change yours.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
// `--probe` and the other flags the app's binary used to take still work.
let command = arguments.isEmpty ? "" : String(arguments.removeFirst().trimmingPrefix(while: { $0 == "-" }))
func argument(_ i: Int) -> String? { i < arguments.count ? arguments[i] : nil }
/// An argument that isn't a setting (`-audioBoost`), which goes after them.
func plain(_ i: Int) -> String? { argument(i).flatMap { $0.hasPrefix("-") ? nil : $0 } }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

switch command {
case "", "help", "h":
    print(usage)
    exit(command.isEmpty ? 2 : 0)

case "version", "v":
    print("reobaby \(ReoBaby.version)")

case "list":
    exit(Probe.list())

case "discover":
    exit(Probe.discover())

case "api":
    guard let target = plain(0), let cmd = plain(1) else { fail("reobaby api <camera> <Command> [json param] [action]") }
    exit(Probe.api(target: target, cmd: cmd, param: plain(2) ?? "{\"channel\":0}", action: plain(3).flatMap { Int($0) } ?? 0))

case "api-poll":
    guard let target = plain(0), let commands = plain(1) else { fail("reobaby api-poll <camera> <commands> [seconds]") }
    exit(Probe.apiPoll(target: target, commands: commands, seconds: plain(2).flatMap { Double($0) } ?? 0))

case "ptz":
    guard let target = plain(0) else { fail("reobaby ptz <camera> [pos | goto | pulses | zoom | limit | survey | ends]") }
    exit(Probe.ptz(target: target, arguments: Array(arguments.dropFirst())))

#if canImport(CoreMedia)
case "probe":
    exit(Probe.run(target: plain(0) ?? "", seconds: plain(1).flatMap { Double($0) } ?? 8))

case "monitor":
    exit(Probe.monitor(target: plain(0) ?? "", seconds: plain(1).flatMap { Double($0) } ?? 20))

case "record":
    guard let target = plain(0), let seconds = plain(1).flatMap({ Double($0) }), let path = plain(2) else {
        fail("reobaby record <camera> <seconds> <out.wav>")
    }
    exit(Probe.record(target: target, seconds: seconds, to: path))

case "process":
    guard let input = plain(0) else { fail("reobaby process <in.wav> [out.wav]") }
    exit(Probe.process(input, to: plain(1)))
#else
case "probe":
    // No decoder here: what arrives, track by track.
    exit(Probe.stream(target: plain(0) ?? "", seconds: plain(1).flatMap { Double($0) } ?? 8))

case "monitor", "record", "process":
    fail("reobaby \(command) decodes the camera's sound, which needs macOS for now.")
#endif

case "soothe":
    guard let target = plain(0) else { fail("reobaby soothe <camera | mac> <seconds per step> [step,step,…]") }
    exit(Probe.soothe(target: target, stepSeconds: plain(1).flatMap { Double($0) } ?? 30,
                      steps: plain(2)?.split(separator: ",").map(String.init) ?? []))

case "soothe-check":
    exit(Probe.sootheCheck())

case "soothe-app-check":
#if canImport(Combine)
    exit(MainActor.assumeIsolated { Probe.sootheAppCheck() })
#else
    fail("reobaby soothe-app-check runs the Mac app's paths, so it needs macOS.")
#endif

default:
    fail("reobaby: no command “\(command)”. `reobaby help` lists them.")
}
