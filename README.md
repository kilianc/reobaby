<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

# ReoBaby

A tiny PiP-like window for your Reolink cameras. All local, no cloud. It floats in
a corner of your screen while you work and tells you when something happens.

**[Download for Mac](https://github.com/kilianc/reobaby/releases/latest/download/ReoBaby.zip)**
· [Try it in your browser](https://kilianc.github.io/reobaby/) · [What's new](CHANGELOG.md) · macOS 14 or later, Apple silicon and Intel

![A Mac desktop with a small ReoBaby window showing a baby asleep in a crib, and a "Sound detected" notification](docs/hero.jpg)

## Why I made it

I'm a new dad. I didn't want videos of my son on someone else's servers, and the
baby monitors I tried had grainy video and clumsy apps. So I bought a few Reolink
zoom cameras and kept everything on my home network. ReoBaby replaces the Reolink
app on my Mac, so I can keep an eye on my little dude while I work.

## What it does

- **Picture-in-picture window.** Frameless, any size, optionally pinned above
  every other window. Controls appear on hover: camera, pause, mute, volume,
  soothing sounds, pin.
- **Menu bar.** Hover the moon icon to peek at the camera when the window isn't
  on screen; click the peek to keep it. Closing the window keeps ReoBaby running
  there. Turn off **Show in Dock** in **Settings › General** to keep ReoBaby in
  the menu bar only.
- **Pause.** Press Space, or choose **Pause** from the moon, to disconnect from
  every camera: no picture, no sound, no notifications until you resume. The
  moon shows a pause sign meanwhile, and ReoBaby always starts unpaused.
- **No Camera.** Choose it from the camera list, or press 0, to close the
  player and disconnect from every camera, as Pause does. **Show Player** opens
  it again on the last camera you watched.
- **Camera controls** for pan-tilt-zoom cameras such as the E1 Zoom: click the
  picture to center it there, drag a box to frame it, scroll to zoom, or turn
  by the degree. More in [Camera controls](#camera-controls).
- **Notifications** for motion (including person, vehicle and animal on cameras
  with AI detection) and for sound, each with a snapshot. They come from the
  camera you've chosen, even with the player closed; ReoBaby doesn't connect to
  your other cameras. Sound is measured on your Mac from the camera's audio,
  after noise reduction, even while muted.
- **Soothing sounds** on the nursery camera's speaker: white, pink or brown
  noise, with an optional heartbeat, shushing or waves, and a sleep timer that
  fades out. See [Soothing sounds](#soothing-sounds).
- **Finds your cameras.** **Settings › Cameras** looks for Reolink cameras on
  your network, checks the login and adds them. No IP addresses to look up.
- **Settings** (⌘,) has everything else: open at login, notifications, sound,
  updates and what's new in them. Every change applies right away. It's in the
  ReoBaby menu and the moon's menu.
- **Local only.** ReoBaby connects only to your cameras, and to GitHub to check
  for updates. No account, no cloud, no analytics. Passwords live in the login
  keychain.
- **No dependencies.** RTSP, RTP depacketizing (H.264, H.265, AAC, G.711) and
  hardware decoding are written on top of Network.framework and AVFoundation.

## Install

1. [Download ReoBaby.zip](https://github.com/kilianc/reobaby/releases/latest/download/ReoBaby.zip),
   unzip it and drag **ReoBaby** to your Applications folder.
2. Open it. The first time, macOS refuses because ReoBaby isn't notarized by
   Apple. Click **Done**, open **System Settings › Privacy & Security**, scroll
   down and click **Open Anyway**. If you prefer Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ReoBaby.app
   ```

3. Allow **Local Network** access so ReoBaby can find and reach your cameras,
   and allow notifications if you want alerts.
4. ReoBaby looks for your cameras and offers to add them (next section).

## Add your cameras

Turn on RTSP in each camera's settings first. In the Reolink app it's under the
camera's network settings, often **Advanced › Server Settings**, depending on the
firmware. Camera names and motion alerts also use the camera's HTTP API, so leave
HTTPS or HTTP on as well.

Then choose **Settings…** (⌘,) from the ReoBaby menu or the moon in the menu
bar, and click **Cameras**. It opens there by itself the first time. ReoBaby
looks for Reolink cameras on your network, which takes a second or two, and
lists the ones it finds under **On Your Network**, like Wi-Fi lists networks.
Click **Add…** next to a camera and enter the user and password you set up for
it in the Reolink app. ReoBaby logs in to check them, then saves the password to
your keychain. A camera on another network can be added by typing its address.

Your cameras are listed under **My Cameras**. **Details…** renames a camera,
switches its picture between high and low resolution, changes its login, or
removes it.

ReoBaby keeps the list in `~/.config/reobaby/cameras.json`, which **Open
cameras.json** at the bottom of the pane opens. Changes to the file apply as
soon as you save it.

```json
{
  "cameras": [
    { "url": "rtsp://192.168.1.20:554/Preview_01_main", "user": "admin" },
    { "url": "rtsp://192.168.1.21:554/Preview_01_main", "user": "admin", "name": "Playroom" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `url` | The camera's RTSP address. Use `_sub` instead of `_main` for the low-resolution stream. If the camera answers 404, ReoBaby also tries the `h264Preview_` and `h265Preview_` paths. |
| `user` | The camera login, usually `admin`. |
| `name` | Optional. Without it, ReoBaby shows the name set on the camera. |
| `password` | Optional and stored in plain text. Leave it out: ReoBaby asks the first time a camera rejects the login and keeps the password in your keychain. |

## Updates

ReoBaby checks GitHub for a new version when it starts, every six hours, and
when you open Settings. It downloads the new version in the background, checks
that it's signed by the same developer, and installs it the next time ReoBaby
quits, so it never restarts while you're watching.

**Settings › General** shows where updates stand and what's new in the latest
version. To install a downloaded update right away, click **Restart to Update**
there, or choose it from the ReoBaby menu or the moon in the menu bar. Turn off
**Check for updates automatically** to stop the automatic checks and downloads;
**Check Now** still checks.

A copy built from source without a signing certificate doesn't update itself.

## Notifications

Each camera notifies at most once every 5 minutes, so someone walking into the
room gives you one notification, not twenty. ReoBaby waits 3 seconds after the
first event so the notification can name the most specific thing it saw (a
person rather than motion). **Settings › Notifications** turns motion or sound
alerts off and changes the quiet period.

## Sound

Reolink microphones are quiet, and rooms have steady background noise: a fan, a
white-noise machine, the microphone's own hiss. ReoBaby cleans up camera sound
before you hear it:

1. **Noise reduction** learns the steady background from the last few seconds
   and turns it down by 12 dB, gently enough that voices don't sound metallic.
   Sounds that come and go, like a cry, a cough or a voice, pass through. A
   sound that never changes, like a constant tone, fades into the background
   after a few seconds. A gentle tone correction puts back the warmth noise
   reduction takes out.
2. **Compression** raises quiet sounds by 40 dB and loud ones by less, so a
   whimper is easy to hear and a scream isn't deafening. What's left of the
   background isn't raised, so the room sounds as quiet as the camera hears it.
3. **A limiter** holds the peaks under full scale, so nothing distorts.

Sound notifications listen through stronger noise reduction (24 dB), so a cry
stands out even over a white-noise machine. The volume slider works on top of all this.

**Settings › Sound** has a slider for each step, and changes apply while you
listen. Noise reduction and boost go down to Off; with noise reduction off,
sound notifications listen without it too. The compressor's threshold
(default -50 dBFS) is where compression starts, and its ratio (default 2:1) is
how many dB louder a sound must get to come out 1 dB louder. **Restore
Defaults** puts all four back.

## Camera controls

On a camera that pans, tilts or zooms, the controls strip has a scope button.
Click it, or press C, to aim the camera from the picture:

- **Click** anything to center it. A yellow ring marks the spot and follows it
  to the middle.
- **Drag** a box around something to center it and zoom until it fills the
  picture.
- **Scroll** or **pinch** to zoom. Past the lens's own zoom (about 2× on an E1
  Zoom), ReoBaby crops the picture, up to 3× more.
- **Arrow keys** turn the camera by 1°, or 10° with Shift; + and − zoom; Esc
  stops the camera, then puts the controls away.
- **Scales** along the edges show pan and tilt in degrees and the zoom. Drag
  one to turn or zoom, click a value to go there, or double-click the reading to
  type an exact one. The bar under a scale shows what the picture covers; while
  the camera moves, a white triangle shows where it is.
- **Saved positions** (the bookmark button) are the camera's own, shared with
  the Reolink app: go to one, save where the camera points now, or remove one.

Reolink cameras can only start turning and stop, at about 60° a second, so
ReoBaby watches where the camera points and corrects with short nudges until
it's within about a degree. It steers over ONVIF when the camera has it on (the
default), which answers much faster than the camera's HTTP API.

## Soothing sounds

ReoBaby can play steady noise on the speaker of the camera in the nursery, to
help a baby settle and fall asleep. Press S in the player, click the moon in its
controls, or choose **Soothing Sounds** from the moon's menu.

- **The noise** is made as it plays: no recordings, nothing downloaded. White
  noise is bright, like a fan. Pink is softer, like rain, and brown is deep,
  like surf. **Warmth** takes out treble, toward the low hush a baby hears in
  the womb.
- **Layers** go on top: a heartbeat (70 beats a minute, adjustable), rhythmic
  shushing, and waves that slowly swell and fall. Each has its own level in
  Settings, so you set by ear how loud the heartbeat and the shush are against
  the noise, and how far the waves swell. Every layer starts at 50%, its level
  as designed.
- **Preview** (the headphones button, in Settings and in the moon's popover)
  plays the sound as set on your Mac only, never on a camera, so you can choose
  by ear before it plays in the nursery. It fades in and takes each change in a
  second and a half, and stops when you press it again, press Play, close the
  popover, or after a minute.
- **A timer** stops it after 45 minutes, or 15 minutes to 8 hours, fading out
  over 2 minutes (up to 10 minutes in Settings): by then your baby is most
  likely asleep, so it goes more slowly than any other fade.
- **Nothing changes suddenly.** Playing and stopping fade over 10 seconds. A new
  colour crossfades with the old, layers fade in and out, and volume and layer
  levels ramp, each over 10 seconds; warmth glides. Stop shows Play again at
  once, and Play during the fade brings the sound straight back up. Quitting
  ReoBaby fades the sound out first.
- **It plays on the camera you're watching.** Choose another camera and the
  sound fades out on one and in on the other, unless the timer is already
  fading it out: then it just ends. Pause and No Camera fade it out, and it
  stays off when you resume. **Settings › Soothing › Play on** can play it on
  your Mac instead.

**Settings › Soothing** has all of it, and changes apply to the sound already
playing. Set the volume standing at the crib.

**Why these sounds.** In a small trial, 16 of 20 newborns fell asleep within 5
minutes with white noise, against 5 of 20 without
([Spencer 1990](https://pubmed.ncbi.nlm.nih.gov/2405784/)). No study has
compared pink or brown noise with white for babies, so pick the one you like.
Infant sleep machines can be loud: at full volume, the 14 that one study measured
averaged 79 dBA at 30 cm ([Hugh 2014](https://pubmed.ncbi.nlm.nih.gov/24590753/)).
Its advice is to keep the sound away from the crib, at a low volume, and on a
timer. 50 dBA at the mattress, about a quiet conversation, is the limit it uses.

**How it reaches the speaker.** ReoBaby talks to the camera the way the Reolink
app does, over Reolink's own protocol on port 9000 (it logs in with the camera's
password). The standard ONVIF way, an RTSP backchannel, stutters on Reolink's E1
Zoom. ReoBaby's way is much steadier, but the camera still stalls for a second
or two every so often, and the sound stutters then; sending further ahead
doesn't help, as the camera only holds about a second. ReoBaby sends sound a
second ahead, so a change you make reaches the nursery about a second later.
The camera's microphone hears its speaker, so the noise is part of what
you hear from the nursery, and noise reduction turns most of it down. When the
sound starts, stops or gets louder, sound notifications relearn the room's
background for a few seconds, so the change itself isn't taken for a cry.

## Keyboard

| Key | Action |
| --- | --- |
| Space | Pause or resume |
| M | Mute or unmute |
| ↑ ↓ | Volume |
| T | Float on top |
| C | Camera controls, on cameras that pan, tilt or zoom |
| S | Soothing sounds on or off |
| ← → or Tab, `[` `]` | Previous or next camera |
| 1–9, ⌘1–⌘9 | Jump to a camera |
| 0, ⌘0 | No camera |
| ⌃⌘F | Full screen |
| ⌘, | Settings |

Right-click the video for the same menu. With camera controls on, the arrow
keys, + and − and Esc aim the camera instead (see [Camera controls](#camera-controls)).

## Build from source

You need macOS 14 or later and Xcode or its Command Line Tools (Swift 5.10 or
later). There are no other dependencies.

```bash
git clone https://github.com/kilianc/reobaby.git
cd reobaby
make install
```

`make install` builds `build/ReoBaby.app` and copies it to `~/Applications`.
Other targets:

| Command | What it does |
| --- | --- |
| `make run` | Build and open the app from `build/`. |
| `make release` | Build a universal (Apple silicon and Intel) app and zip it to `build/ReoBaby.zip`. It needs your signing certificate, because ReoBaby only installs updates signed like the copy they replace. |
| `make probe CAM="Nursery"` | Connect to a camera without a window and print codecs, frame rate, errors and its name. `CAM` is a name, a number from the list, or an `rtsp://` URL. |
| `make discover` | List the Reolink cameras on your network, as Settings › Cameras finds them. |
| `make test-server` | Start local test cameras in Docker at `rtsp://tester:testpass@127.0.0.1:8554/` with the paths `nursery`, `h264`, `h265` and `beeps`. |

The Makefile signs with your Apple Development certificate if you have one, so
macOS remembers keychain permissions across rebuilds. Without one it signs
ad hoc, and macOS asks for keychain access again after each build.

To watch live sound levels and detection events for a camera:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --monitor "Nursery" 30
```

To tune the sound processing against a real room, record a camera's sound, then
run the recording through the processing. `--process` prints levels before and
after, lists the sound events it would notify with and without noise reduction,
and writes what you would hear. Settings go after the files, as `-audioBoost 30`,
without changing yours. WAV files are git-ignored, so recordings stay out of the
repo:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --record "Nursery" 60 build/room.wav
```

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --process build/room.wav build/room-processed.wav
```

To drive a pan-tilt camera from Terminal, and to measure how a new model moves
(`PTZGeometry` holds the E1 Zoom's numbers), use `--ptz`. `survey` measures how
far the picture moves per unit of pan and tilt at a zoom; `ends` checks whether
the pictures at the two pan end stops overlap, which means a full turn.
`--api` sends any command of the camera's HTTP API and prints the answer:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --ptz "Nursery" pos
```

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --api "Nursery" GetPtzCurPos '{"PtzCurPos":{"channel":0}}'
```

To hear Soothing Sounds without the app, on a camera's speaker or on this Mac
(`mac`), through one or more steps in turn, each lasting the given seconds. A
step is a volume, or changes joined by `+`: `noise=brown`, `volume=0.6`,
`warmth=0.8`, `shush=on`, `waves=off`, `heart=on`. A layer also takes a level,
which turns it on: `shush=0.7`. Settings go last, as in
`-sootheNoise brown -sootheHeartbeat 1`. On a camera it also logs what the
camera's microphone hears:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --soothe "Nursery" 20 0.3,0.5
```

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --soothe "Nursery" 45 noise=pink,noise=brown,noise=pink+shush=on,shush=off+waves=on
```

Two checks run Soothing Sounds offline and silently, with no camera.
`--soothe-check` renders every change of colour, layer, level, volume and
warmth and fails if one is sudden. `--soothe-app-check` takes about two minutes:
it plays on stand-in camera speakers that only measure what they're sent,
through Stop and Play again, a camera switch, Pause and resume, the timer's end,
and quitting:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --soothe-check
```

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --soothe-app-check
```

`--render soothing <file.png> [dark]` and `--render popover <file.png>` draw
Settings › Soothing and the moon's popover offscreen. Settings go last, as in
`-sootheHeartbeat YES`. The popover is always dark, like the player's controls;
offscreen it has no blur.

`--api-poll` asks for several things at once, with the password ReoBaby saved:
command names to read, or the API's own JSON. With seconds, it asks again once
a second for that long, one line each:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --api-poll "Nursery" GetPerformance,GetEnc
```

`REOBABY_UPDATE_URL` points the updater at another release feed (a JSON file
shaped like GitHub's latest-release answer), to test updates without publishing.

### Pictures without a real camera

`test/demo/nursery-photo.jpg` is an AI-generated photo, so no real footage ends up in the repo.
`tools/demo-frame.swift` stamps it with a camera clock into `test/demo/nursery.png`, which
`make test-server` streams as the `nursery` camera. `REOBABY_CONFIG_DIR` points the app at a
different camera list, and `REOBABY_PIN_CONTROLS=1` keeps the controls visible.
`REOBABY_PTZ_DEMO=1` gives every camera a pretend pan-tilt-zoom motor, and
`REOBABY_CAMERA_CONTROLS=1` opens camera controls at launch:

```bash
mkdir -p /tmp/reobaby-demo
echo '{"cameras":[{"name":"Nursery","url":"rtsp://127.0.0.1:8554/nursery","user":"tester","password":"testpass"}]}' > /tmp/reobaby-demo/cameras.json
open -n --env REOBABY_CONFIG_DIR=/tmp/reobaby-demo --env REOBABY_PIN_CONTROLS=1 build/ReoBaby.app
```

The website in `docs/` is a desktop simulation using the same photo. `make hero` screenshots it
(`docs/index.html#shot`) with headless Chrome into `docs/hero.jpg`. The app icon comes from
`tools/make-icon.swift`.

## License

[MIT](LICENSE). ReoBaby isn't affiliated with Reolink.
