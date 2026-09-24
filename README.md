# DisplayAudioFix

`DisplayAudioFix` is a native, dependency-free macOS command-line utility and LaunchDaemon for recovering DisplayPort/HDMI audio when the device remains enumerated but CoreAudio can no longer start playback, or when a hot-reconnected endpoint temporarily disappears from CoreAudio altogether.

It was built for macOS 27.0 (26A428) and the preferred `LS24A600U` output. It discovers devices by name and re-reads their UID after a CoreAudio restart; no monitor UUID is hardcoded.

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

There is a second reconnect failure mode: the display link and EDID remain present, but the CoreAudio endpoint is absent or a full HAL device walk blocks on another stale endpoint. The repair now remembers the last good device UID, asks CoreAudio for that UID directly, and treats a missing endpoint as a recovery trigger instead of waiting forever for another log event. UID lookup, device enumeration, default-output writes, and sample-rate writes are all bounded and single-flight, so a wedged CoreAudio call cannot stop the watcher or create an unbounded pile of worker threads.

## Recovery Method

DisplayAudioFix performs the following staged recovery:

1. Pause the BetterDisplay user-session process before querying CoreAudio, so a stale `AudioQueue` does not keep the old DisplayPort I/O context wedged.
2. Record the preferred endpoint UID if it can be enumerated. The UID is persisted in the state file and is queried directly after reconnect; a temporary enumeration timeout does not abort recovery.
3. Select the built-in MacBook output when available, but continue if CoreAudio is too wedged to switch yet.
4. Restart only `coreaudiod` with `launchctl kickstart -kp`.
5. Poll for the DisplayPort endpoint to be enumerated again, then restore it as both default output and system output.
6. Toggle its nominal rate and restore the original rate to rebuild its I/O context.
7. Run a bounded silent `AudioQueue` playback probe on the monitor itself.
8. Relaunch BetterDisplay only after its old process has exited, keep the built-in output selected if the probe fails, and retry after the cooldown. A shared advisory lock prevents the system daemon, a user agent, and a manual `repair` command from resetting CoreAudio concurrently.

BetterDisplay is paused only during an actual recovery and relaunched through
the existing logged-in user's LaunchServices session. If either the monitor or
the built-in output is temporarily absent from CoreAudio's device list, the
recovery still resets `coreaudiod` instead of stopping at the failed query.

The watcher also monitors relevant unified-log events, coalesces duplicate lines from one failure burst, checks the preferred device every 30 seconds, and checks after sleep/wake. If CoreAudio reports no preferred device, the watcher enters the staged reset immediately; it does not wait for a future error line. There is no window-wide maximum-attempt block in the current implementation.

## What it does

- Enumerates CoreAudio output devices, including transport, UID, sample rate, role, liveness/running state, and channel count. When the full HAL list is blocked, it uses the persisted endpoint UID without probing unrelated device properties.
- Watches the unified log for timeline, `1937010544`, `StartIOThread`, and `Device ... is not running` failures.
- Runs a bounded, inaudible AudioQueue playback probe on the selected hardware.
- Switches to built-in speakers, restarts `coreaudiod`, waits for device discovery, restores the preferred display output, then verifies playback.
- Enforces a 30-second minimum cooldown while continuing automatic recovery until a real playback probe succeeds; the cooldown is not an attempt limit.
- Renegotiates the preferred display's nominal sample rate during recovery to rebuild a wedged DisplayPort I/O context on macOS 27.0.
- Quiesces and relaunches BetterDisplay around recovery when its process is present, waiting up to five seconds for its old AudioQueue client to exit before CoreAudio is reset.
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

`test` sends silence. To verify routing with a quiet 880 Hz tone:

```sh
.build/release/displayaudiofix test --audible
```

## Install

From a fresh clone, deploy with:

```sh
git clone https://github.com/TypeThe0ry/DisplayAudioFix.git
cd DisplayAudioFix
./install.sh
```

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
  "preferredDeviceName" : "LS24A600U",
  "recoveryWindowSeconds" : 300
}
```

```sh
sudo launchctl kickstart -k system/com.displayaudiofix.daemon
```

For a one-off source-tree test, `DISPLAYAUDIOFIX_PREFERRED_DEVICE` overrides the configured name. `DISPLAYAUDIOFIX_CONFIG` can point at another JSON file.

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

`set-rate` is a diagnostic/recovery command for the configured preferred device. It changes the CoreAudio nominal sample-rate property; it does not change display resolution or refresh rate.

`restore` first runs the real silent playback probe and only then selects the preferred display output as both default and system output. It is useful after a reconnect when the endpoint is healthy again but macOS is still left on the built-in speakers; it does not require administrator privileges.

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

If `status` reports the built-in speakers, that is a protective fallback, not a successful repair. Success requires `LS24A600U` as the current default and `HEALTHY` from the active probe.

## Safety And Scope

DisplayAudioFix uses documented CoreAudio, AudioToolbox, Foundation, and `launchctl` interfaces. It does not modify SIP or Apple system files, install kernel extensions, use private audio frameworks, delete audio preference databases, kill unrelated applications, disable other monitors, or modify display resolution/refresh rate. During a needed recovery it temporarily terminates and relaunches BetterDisplay so its stale audio client releases the old display endpoint.

Other applications can also own the same DisplayPort audio UID. In particular, remote-desktop or video-capture applications may reopen an old audio context immediately after a repair. DisplayAudioFix records those failures and never kills unrelated applications automatically; if the log names a non-BetterDisplay client, close or pause that client while testing the reconnect. A repair is considered successful only when the monitor is the current default and the active AudioQueue probe reports `HEALTHY`.

No license file is currently included. Add the license that matches how you intend to distribute this project before publishing it for reuse.
