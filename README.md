# DisplayAudioFix

`DisplayAudioFix` is a native, dependency-free macOS command-line utility and LaunchDaemon for recovering DisplayPort/HDMI audio when the device remains enumerated but CoreAudio can no longer start playback, or when a hot-reconnected endpoint temporarily disappears from CoreAudio altogether.

It was first built around the `LS24A600U` failure on macOS 27.0 (26A428), but the recovery target is not limited to that monitor. In automatic mode it follows the current physical output, including another DisplayPort/HDMI monitor, USB/Thunderbolt audio device, Bluetooth speaker, or built-in speaker. The configured `LS24A600U` name is retained as the first-choice external fallback for existing installations.

### Important: the LS24A600U has no built-in speakers

Samsung's specifications for the S60UA/`LS24A600U` list **Speaker: No** and
**Headphone: Yes**. The DisplayPort endpoint is therefore a digital audio
stream delivered to the monitor's headphone jack (or to another downstream
audio sink); it cannot make the monitor itself produce sound. After a
reconnect, connect powered speakers or headphones to that jack and check the
monitor's OSD input/volume/mute state. macOS reports no scalar volume or mute
property for this DisplayPort endpoint, so the normal macOS volume slider may
show `missing value` even while the stream is healthy. See Samsung's official
[S60UA specifications](https://www.samsung.com/ie/monitors/high-resolution/s60ua-24-24-inch-ips-uhd-4k-ls24a600ucuxxu/).

## Problem And Root Cause

On the affected macOS 27.0 system, `LS24A600U` remained visible in `system_profiler` and CoreAudio with two output channels, `Alive: yes`, and a 48 kHz DisplayPort format. Enumeration therefore looked normal, but a real `AudioQueue` playback probe failed with `TIMELINE_TIMEOUT` / `AudioQueueStart failed ('stop')`.

The matching `coreaudiod` messages were:

```text
Device <UID> is not running
could not establish a timeline after waiting 10000000 microseconds
stopping with error 1937010544
StartIOThread: the IO thread failed to start, Error: 1937010544
```

The observed cause is a macOS/CoreAudio DisplayPort I/O-context failure: the endpoint is enumerated, but its legacy I/O context cannot establish a running timeline. This is not the same as a missing device, and selecting the device in Sound settings does not prove that playback works.

In testing, changing the endpoint's documented nominal sample-rate property from 48 kHz to 44.1 kHz and back to 48 kHz forced CoreAudio to renegotiate the wedged I/O context. The next real silent playback probe returned `HEALTHY`. This is an empirical workaround for this macOS 27.0 failure mode; it does not change display refresh rate.

There is a second reconnect failure mode: the display link and EDID remain present, but the CoreAudio endpoint is absent or a full HAL device walk blocks on another stale endpoint. The repair remembers the last good device UID, but never treats UID translation alone as proof that the device is still connected: the endpoint's real CoreAudio properties must be readable before it can be selected. A disconnected monitor therefore falls back to the currently enumerable built-in or other physical output instead of sending audio to a stale DisplayPort UID. UID lookup, device enumeration, default-output writes, and sample-rate writes are all bounded and have a small cap on timed-out replacement workers, so a wedged CoreAudio call cannot stop the watcher or create an unbounded pile of worker threads.

## Recovery Method

DisplayAudioFix performs the following staged recovery:

1. If the active target is a display, pause the BetterDisplay user-session process before querying CoreAudio, so a stale `AudioQueue` does not keep the old DisplayPort I/O context wedged.
2. Resolve the active physical output. A user-selected external output wins; otherwise the persisted UID/name or configured `preferredDeviceName` is used. If that endpoint disappeared, another physical output is selected before falling back to a built-in speaker. The active UID/name is persisted so a monitor or speaker switch does not send audio back to the wrong endpoint.
3. Select the built-in MacBook output when available, but continue if CoreAudio is too wedged to switch yet.
4. Restart only `coreaudiod` with `launchctl kickstart -kp`.
5. Poll for the active physical endpoint to be enumerated again, then restore it as both default output and system output.
6. Toggle its nominal rate and restore the original rate to rebuild its I/O context.
7. Run a bounded silent `AudioQueue` playback probe on the active output.
8. Relaunch BetterDisplay only after its old process has exited. When the
   recovery probe succeeds, read the monitor's DDC mute/volume state through
   BetterDisplay, write the same unmuted/volume values back to wake the
   active monitor's headphone jack, and reassert that display as the default
   after the app has recreated its audio client. A reconnect-stale monitor mute
   is cleared; the current volume level is preserved. USB, Bluetooth, built-in,
   and other non-display outputs use CoreAudio recovery without display-specific
   DDC commands. If the probe fails, the built-in output remains selected
   and the watcher retries after the cooldown. A shared advisory lock prevents
   the system daemon, a user agent, and a manual `repair` command from resetting
   CoreAudio concurrently.

BetterDisplay is paused only during an actual recovery and relaunched through
the existing logged-in user's LaunchServices session. If either the monitor or
the built-in output is temporarily absent from CoreAudio's device list, the
recovery still resets `coreaudiod` instead of stopping at the failed query.

The watcher also monitors relevant unified-log events, coalesces duplicate lines from one failure burst, checks the active physical output at the configured interval (with a 30-second minimum), and checks after sleep/wake. If CoreAudio reports no active endpoint, the watcher enters the staged reset immediately; it does not wait for a future error line. Failed recoveries use an adaptive delay (up to five minutes) before the next reset, so an unplugged monitor or a wedged third-party driver cannot cause a coreaudiod restart/CPU storm. Recovery never gives up; a healthy physical output clears the delay immediately.

## What it does

- Enumerates CoreAudio output devices, including transport, UID, sample rate, role, liveness/running state, and channel count. When the full HAL list is blocked, a persisted endpoint UID is accepted only after the endpoint's real properties can be read; a stale disconnected monitor is never manufactured as a live DisplayPort device.
- Follows a deliberate switch among physical outputs instead of treating `LS24A600U` as a hard-coded monitor. Virtual meeting/capture devices are not selected automatically.
- Watches the unified log for timeline, `1937010544`, `StartIOThread`, and `Device ... is not running` failures.
- Runs a bounded, inaudible AudioQueue playback probe on the selected hardware.
- Switches to a temporary built-in fallback, restarts `coreaudiod`, waits for device discovery, restores the active physical output, then verifies playback.
- Enforces a minimum cooldown plus adaptive backoff while continuing automatic recovery until a real playback probe succeeds; the delay is not an attempt limit.
- Renegotiates the active physical output's nominal sample rate during recovery when the device exposes that property; this rebuilds a wedged DisplayPort/HDMI I/O context without changing display refresh rate.
- Quiesces and relaunches BetterDisplay around recovery when its process is present. It waits up to five seconds for a graceful exit and escalates to `SIGKILL` only for that already-identified, non-root BetterDisplay process if it is wedged, so the stale AudioQueue cannot survive into the next reconnect.
- After a successful display recovery, clears a reconnect-stale monitor-side DDC
  mute bit, re-writes the current volume level, and reasserts that display as
  the default after BetterDisplay relaunches.
- Leaves built-in speakers selected when repair does not restore healthy playback.
- Rotates `/var/log/displayaudiofix.log` to one `.1` backup at 2 MiB.

It does **not** modify SIP, install kernel extensions, edit Apple system files, delete audio preferences, kill unrelated applications, change display settings, or use private frameworks. During a needed recovery only, it sends `TERM` to BetterDisplay and relaunches it after the audio recovery attempt.

## Build and inspect

```sh
swift build -c release
.build/release/displayaudiofix devices
.build/release/displayaudiofix status
.build/release/displayaudiofix test
```

`test` sends silence. To perform a manual listening test with a 0.8-second
880 Hz tone:

```sh
.build/release/displayaudiofix test --audible
```

`HEALTHY` means CoreAudio started the queue and completed an output buffer. It
proves the digital transport, not the presence of a built-in monitor speaker
or the volume/mute state of an external sink.

## Install

From a fresh clone, deploy with:

```sh
git clone https://github.com/TypeThe0ry/DisplayAudioFix.git
cd DisplayAudioFix
./install.sh
```

For a Finder-based one-click deployment, double-click `install.command` in the
cloned folder. It opens Terminal, builds the release binary, and asks for the
same macOS administrator authorization as `install.sh`.

`install.sh` is committed as executable, builds the release binary, asks for
administrator authorization, installs the system LaunchDaemon, and starts it.
No separate `chmod`, manual file copy, or background terminal is needed. Run
the command in Terminal and let it finish; do not suspend it with Ctrl-Z. When
Terminal asks for your macOS login password, typing is intentionally invisible;
type it and press Return.

The installer uses `sudo` when required and installs:

- `/usr/local/bin/displayaudiofix`
- `/Library/LaunchDaemons/com.displayaudiofix.daemon.plist`
- `/Library/Application Support/DisplayAudioFix/config.json`
- `/var/db/displayaudiofix/state.json` (created after first recovery)
- `/var/log/displayaudiofix.log`

Verify:

```sh
displayaudiofix status
sudo launchctl print system/com.displayaudiofix.daemon
displayaudiofix logs --follow
```

The full LaunchDaemon can restart the system `coreaudiod` service and is the recommended installation. If administrator authorization is unavailable, run `install-user.sh`; the user LaunchAgent can probe, select, monitor, and retry, but cannot restart system `coreaudiod`.

Run only one watcher. Do not leave an older `/usr/local/bin/displayaudiofix` LaunchDaemon and a separate user agent managing the same output at the same time; competing recovery loops can re-trigger the DisplayPort failure. The current watcher takes a shared watcher lock at `/tmp/com.displayaudiofix.watch.lock`, and every staged repair takes `/tmp/com.displayaudiofix.recovery.lock`; a full `install.sh` removes the matching user agent before starting the system daemon.

## Configuration

Edit `/Library/Application Support/DisplayAudioFix/config.json`, then restart the daemon:

```json
{
  "healthCheckIntervalSeconds" : 30,
  "healthCheckTimeoutSeconds" : 3,
  "continuousRecovery" : true,
  "minimumRecoveryCooldownSeconds" : 30,
  "postWakeDelaySeconds" : 8,
  "followActiveOutput" : true,
  "preferredDeviceName" : "LS24A600U",
  "recoveryWindowSeconds" : 300
}
```

```sh
sudo launchctl kickstart -k system/com.displayaudiofix.daemon
```

With `followActiveOutput: true`, the watcher follows the current physical
output when you switch monitors or speakers. Set it to `false` to pin recovery
to `preferredDeviceName`. For a one-off source-tree test,
`DISPLAYAUDIOFIX_PREFERRED_DEVICE` overrides the configured name.
`DISPLAYAUDIOFIX_CONFIG` can point at another JSON file.

## Commands

```text
displayaudiofix status
displayaudiofix devices
displayaudiofix test [--audible]
displayaudiofix restore
displayaudiofix set-rate <hz>
displayaudiofix repair
displayaudiofix watch
displayaudiofix logs [--follow]
displayaudiofix install
displayaudiofix uninstall
```

`repair`, `install`, and `uninstall` prompt through `sudo` when not already root. A manual repair bypasses automatic rate limiting, but still performs one staged recovery and one delayed post-recovery probe retry. Automatic recovery has no window-wide attempt cap; the cooldown only prevents concurrent/tight-loop restarts.

`set-rate` is a diagnostic/recovery command for the active/configured output. It changes the CoreAudio nominal sample-rate property; it does not change display resolution or refresh rate.

`restore` first runs the real silent playback probe and only then selects the active physical output as both default and system output. It is useful after a reconnect when the endpoint is healthy again but macOS is still left on the wrong output; it does not require administrator privileges.

## Uninstall

```sh
./uninstall.sh
```

Uninstall removes the daemon, installed executable, and transient state. Configuration and logs remain in place so the operation is reversible and its history remains inspectable. Remove those retained files manually only if desired.

## Health results

- `HEALTHY`: AudioQueue started and completed a buffer before the timeout.
- `START_FAILED`: queue creation, device selection, buffer setup, or start returned another `OSStatus`.
- `TIMELINE_TIMEOUT`: CoreAudio returned `'stop'`/`1937010544`, or no buffer completed before the deadline.
- `DEVICE_MISSING`: no usable output device was found.
- `DEVICE_NOT_RUNNING`: CoreAudio reports that the device is not alive.

The `Running` field from `devices` is informational. A healthy idle output can legitimately report `no`; the active playback probe is the authoritative check.

## Troubleshooting

```sh
displayaudiofix logs --follow
system_profiler SPAudioDataType
displayaudiofix devices
displayaudiofix test
log show --last 10m --style compact --predicate 'process == "coreaudiod"'
```

If `status` reports the built-in speakers while an external output is connected, inspect `displayaudiofix devices` and the current macOS Sound output selection. In automatic mode, the selected physical output—not a hard-coded `LS24A600U`—must be the current default and return `HEALTHY` from the active probe.

## Safety And Scope

DisplayAudioFix uses documented CoreAudio, AudioToolbox, Foundation, and `launchctl` interfaces. It does not modify SIP or Apple system files, install kernel extensions, use private audio frameworks, delete audio preference databases, kill unrelated applications, disable other monitors, or modify display resolution/refresh rate. During a needed recovery it temporarily terminates and relaunches BetterDisplay so its stale audio client releases the old display endpoint; if that identified BetterDisplay process ignores `TERM`, the recovery escalates only that process to `SIGKILL`.

Other applications can also own the same DisplayPort audio UID. In particular, remote-desktop or video-capture applications may reopen an old audio context immediately after a repair. DisplayAudioFix records those failures and never kills unrelated applications automatically; if the log names a non-BetterDisplay client, close or pause that client while testing the reconnect. A repair is considered successful only when the monitor is the current default and the active AudioQueue probe reports `HEALTHY`.

No license file is currently included. Add the license that matches how you intend to distribute this project before publishing it for reuse.
