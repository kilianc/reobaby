# Changelog

What changed in each ReoBaby release. Every version is on the
[Releases](https://github.com/kilianc/reobaby/releases) page.

## 1.7.0 · 2026-11-09

- **Camera controls.** On cameras that pan, tilt or zoom, such as the E1 Zoom,
  the scope button in the controls strip (or C) lets you aim from the picture:
  click anything to center it, drag a box to frame it, scroll or pinch to zoom.
  Scales along the edges show pan and tilt in degrees and the zoom; drag them,
  click a value, or type an exact one. Arrow keys turn the camera by 1°, or 10°
  with Shift. ReoBaby watches where the camera points and corrects until it's
  within about a degree, where the Reolink app can only start and stop it.
- **Zoom past the lens.** Beyond the camera's optical zoom, ReoBaby crops the
  picture up to 3× more.
- **Saved positions** from the camera, shared with the Reolink app: go to one,
  save the current one, or remove one, from the bookmark button.
- **Soothing sounds.** ReoBaby plays white, pink or brown noise on the nursery
  camera's speaker, to help your baby settle and sleep. A heartbeat, shushing
  and slow waves can go on top, **Warmth** softens the treble, and a sleep timer
  fades it out after 45 minutes, or up to 8 hours. Press S in the player, click
  the moon in its controls, or use the moon's menu; **Settings › Soothing** has
  the rest. The noise is made as it plays, with nothing recorded or downloaded.
  It plays on the camera you're watching, or on your Mac. See
  [Soothing sounds](README.md#soothing-sounds).
- **A level for each layer.** In Settings › Soothing, the heartbeat, the
  shushing and the waves each have a level slider, so you set by ear how loud
  each is against the noise. Each starts at 50%.
- **Preview on your Mac.** The headphones button, in Settings › Soothing and the
  moon's popover, plays the sound as set on your Mac only, so you can choose by
  ear before it plays in the nursery.
- **Nothing changes suddenly.** Playing, stopping, a new colour, a layer, a
  level, the volume, a camera switch and Pause all fade over 10 seconds, and
  quitting fades the sound out first. Stop shows Play again at once, and Play
  during the fade brings the sound back. The sleep timer fades out more slowly,
  over 2 minutes or up to 10. On Reolink's E1 Zoom the sound can still stutter
  for a moment when the camera stalls, every so often.
- **Settings fits smaller screens.** Settings › Soothing has one row per
  setting, and a Settings pane taller than the screen scrolls.
- **The moon's popover matches the player.** It's dark, with the player's
  white controls, slider and moon.
- **Sound notifications expect it.** When soothing sounds start, stop or get
  louder, sound notifications relearn the room's background for a few seconds,
  so the change isn't taken for a cry.

## 1.6.0 · 2026-11-08

- **Settings.** **Settings…** (⌘,), in the ReoBaby menu and the moon's menu,
  has every setting in one window: General, Cameras, Notifications, Sound and
  About. Changes apply right away. It replaces the Cameras window, and the
  moon's Notify on Motion, Notify on Sound, Show in Dock and About ReoBaby.
  Adding a camera or changing one opens a sheet, as Wi-Fi does.
- **Open at login**, in Settings › General.
- **Sound you can tune while you listen.** Settings › Sound has sliders for
  noise reduction, boost and the compressor, and the sound already playing
  changes with them. **Restore Defaults** puts them back.
- **Updates in Settings.** Opening Settings checks for a new version and
  downloads it. Settings › General shows where updates stand, with a badge on
  ReoBaby's icon, lists what's new in the latest version, and links to this
  changelog. **Restart to Update** there installs a downloaded update.
- **Smooth sound, in step with the picture.** Reolink cameras stamp their
  sound with uneven times, up to 60 ms off, and ReoBaby played it as stamped,
  with tiny gaps and overlaps that made it choppy. Sound now plays seamlessly.
  When the picture has to wait out a slow network, the sound catches up during
  quiet moments, a few milliseconds at a time, instead of skipping.
- **A quiet background.** The boost no longer raises what's left of the
  background noise, so the room sounds as quiet as the camera hears it while a
  cry still comes up by 40 dB. Noise reduction also works from the first
  second, instead of letting loud noise through for a few seconds every time
  ReoBaby connects.
- **Natural sound.** Noise reduction is gentler (12 dB) and smoother, so voices
  and cries no longer sound metallic or flanged, and a gentle tone correction
  brings back the warmth it took out. Sound notifications still listen through
  24 dB of noise reduction.

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
