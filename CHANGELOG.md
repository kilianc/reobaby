# Changelog

What changed in each ReoBaby release. Every version is on the
[Releases](https://github.com/kilianc/reobaby/releases) page.

## Unreleased

- **Smooth sound.** Reolink cameras stamp their sound with uneven times, up to
  60 ms off, and ReoBaby played it as stamped, with tiny gaps and overlaps that
  made it choppy. Sound now plays seamlessly.
- **A quiet background.** The boost no longer raises what's left of the
  background noise, so the room sounds as quiet as the camera hears it while a
  cry still comes up by 40 dB. Noise reduction also works from the first
  second, instead of letting loud noise through for a few seconds every time
  ReoBaby connects.

## 1.5.0 · 2026-11-08

- **Clearer, louder sound.** Noise reduction turns steady background noise (a
  fan, a white-noise machine, microphone hiss) down by 24 dB, and a compressor
  raises quiet sounds by 40 dB and loud ones by less. A whimper is now easy to
  hear and a cry still doesn't distort. `noiseReduction` and `audioBoost`
  change them; see [Sound](README.md#sound).
- **Sound notifications hear through background noise.** Sound is measured
  after noise reduction, so a cry over a white-noise machine is noticed.
- **Only the chosen camera is connected.** ReoBaby used to stay connected to
  every camera for notifications. Now notifications come from the camera you've
  chosen, and ReoBaby doesn't connect to the others. **No Camera** disconnects
  from every camera, as Pause does, and the moon shows the pause sign.

## 1.4.1 · 2026-11-07

- **About ReoBaby** is in the moon's menu too, so it's there without a Dock
  icon. The panel now says what ReoBaby is, with links to GitHub and this
  changelog, and its license.

## 1.4.0 · 2026-11-07

- **Louder camera sound.** Reolink microphones are quiet, so ReoBaby now plays
  camera sound 24 dB louder, through a limiter so a sudden cry doesn't distort.
  `defaults write com.kilianciuffolo.cam audioBoost -float <dB>` changes the
  boost; 0 turns it off.
- **No Camera closes the player.** **Show Player**, or choosing a camera, opens
  it again on the last camera you watched.
- **Show in Dock** is also in the ReoBaby menu.
- The player says "Waiting for keychain access…" only when macOS stops to ask
  for it, not at every launch.

## 1.3.0 · 2026-11-07

- **Pause.** Space, the pause button in the player, or **Pause** from the moon
  disconnects from every camera: no picture, no sound, no notifications until
  you resume. The moon shows a pause sign meanwhile, and ReoBaby always starts
  unpaused.
- **No Camera.** The last choice in every camera list (or 0) empties the player
  while motion and sound notifications keep working.
- **Show in Dock.** Turn it off in the moon's menu to keep ReoBaby in the menu
  bar only.

## 1.2.0 · 2026-11-07

- **Automatic updates.** ReoBaby checks GitHub for a new version at launch and
  every six hours, downloads it in the background, checks that it's signed by
  the same developer, and installs it the next time ReoBaby quits.
- **Restart to Update** installs a downloaded update right away. **Check for
  Updates…** checks now.

## 1.1.0 · 2026-11-07

- **Cameras window** (⌘,). ReoBaby finds the Reolink cameras on your network
  and lists them, like Wi-Fi lists networks. **Add** checks the login and keeps
  the password in your keychain.
- **Edit** renames a camera, switches its picture between high and low
  resolution, changes its login, or removes it.
- **Open cameras.json** at the bottom of the window opens the file for hand
  edits.

## 1.0.0 · 2026-11-07

The first release: a floating picture-in-picture window for Reolink cameras, a
moon in the menu bar that peeks at the camera, and notifications for motion and
sound. Cameras were added by editing cameras.json.
