<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

# ReoBaby

A tiny Mac window for your Reolink baby cameras. It floats in a corner of your
screen while you work, tells you when something happens, and keeps everything on
your home network.

**[Download for Mac](https://github.com/kilianc/reobaby/releases/latest/download/ReoBaby.zip)**
· [Try it in your browser](https://kilianc.github.io/reobaby/) · macOS 14 or later, Apple silicon and Intel

![A Mac desktop with a small ReoBaby window showing a baby asleep in a crib, and a "Sound detected" notification](docs/hero.jpg)

## Why I made it

I'm a new dad. I didn't want videos of my son on someone else's servers, and the
baby monitors I tried had grainy video and clumsy apps. So I bought a few Reolink
zoom cameras and kept everything on my home network. ReoBaby replaces the Reolink
app on my Mac, so I can keep an eye on my little dude while I work.

## What it does

- **Picture-in-picture window.** Frameless, any size, optionally pinned above
  every other window. Controls appear on hover: camera, mute, volume, pin.
- **Menu bar.** Hover the moon icon to peek at the camera when the window isn't
  on screen; click the peek to keep it. Closing the window keeps ReoBaby running
  there.
- **Notifications** for motion (including person, vehicle and animal on cameras
  with AI detection) and for sound, each with a snapshot. Sound is measured on
  your Mac from each camera's audio, even while muted.
- **Local only.** ReoBaby connects only to the cameras you list. No account, no
  cloud, no analytics. Passwords live in the login keychain.
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

3. Allow **Local Network** access so ReoBaby can reach your cameras, and allow
   notifications if you want alerts.
4. Add your cameras (next section).

## Add your cameras

Turn on RTSP in each camera's settings first. In the Reolink app it's under the
camera's network settings, often **Advanced › Server Settings**, depending on the
firmware. Camera names and motion alerts also use the camera's HTTP API, so leave
HTTPS or HTTP on as well.

Then click the moon in the menu bar and choose **Edit Cameras…** (⌘,). This opens
`~/.config/reobaby/cameras.json`; changes apply as soon as you save.

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

## Notifications

Each camera notifies at most once every 5 minutes, so someone walking into the
room gives you one notification, not twenty. ReoBaby waits 3 seconds after the
first event so the notification can name the most specific thing it saw (a
person rather than motion). Turn motion or sound alerts off from the menu bar.
To change the quiet period, in seconds:

```bash
defaults write com.kilianciuffolo.cam notifyCooldown -float 600
```

## Keyboard

| Key | Action |
| --- | --- |
| M | Mute or unmute |
| ↑ ↓ | Volume |
| T | Float on top |
| ← → or Tab, `[` `]` | Previous or next camera |
| 1–9, ⌘1–⌘9 | Jump to a camera |
| ⌃⌘F | Full screen |

Right-click the video for the same menu.

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
| `make release` | Build a universal (Apple silicon and Intel) app and zip it to `build/ReoBaby.zip`. |
| `make probe CAM="Nursery"` | Connect to a camera without a window and print codecs, frame rate, errors and its name. `CAM` is a name, a number from the list, or an `rtsp://` URL. |
| `make test-server` | Start local test cameras in Docker at `rtsp://tester:testpass@127.0.0.1:8554/` with the paths `nursery`, `h264`, `h265` and `beeps`. |

The Makefile signs with your Apple Development certificate if you have one, so
macOS remembers keychain permissions across rebuilds. Without one it signs
ad hoc, and macOS asks for keychain access again after each build.

To watch live sound levels and detection events for a camera:

```bash
build/ReoBaby.app/Contents/MacOS/ReoBaby --monitor "Nursery" 30
```

### Pictures without a real camera

Every picture of a baby here is AI-generated, not filmed. `test/demo/nursery-photo.jpg` is the
photo; `tools/demo-frame.swift` stamps it with a camera clock into `test/demo/nursery.png`, which
`make test-server` streams as the `nursery` camera. `tools/hero-shot.swift` puts a capture of the
app's window on a drawn desktop. `REOBABY_CONFIG_DIR` points the app at a different camera list,
and `REOBABY_PIN_CONTROLS=1` keeps the controls visible:

```bash
mkdir -p /tmp/reobaby-demo
echo '{"cameras":[{"name":"Nursery","url":"rtsp://127.0.0.1:8554/nursery","user":"tester","password":"testpass"}]}' > /tmp/reobaby-demo/cameras.json
open -n --env REOBABY_CONFIG_DIR=/tmp/reobaby-demo --env REOBABY_PIN_CONTROLS=1 build/ReoBaby.app
```

The website in `docs/` is a desktop simulation using the same photo. The app icon comes from
`tools/make-icon.swift`.

## License

[MIT](LICENSE). ReoBaby isn't affiliated with Reolink.
