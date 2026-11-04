# Design notes & findings

Companion to the [README](../README.md), which covers setup. This file records how the system
behaves, the hardware constraints discovered while building it, and the decisions that followed.

## The core hardware constraint
**The PRISM+ monitors this was built for only accept DDC/CI on the input they are actively
displaying.** A machine cannot command a monitor that is currently showing the *other* machine:
`GetVCPFeature`/`SetVCPFeature` simply fail on the inactive input.

That rules out the obvious design (one machine drives every monitor). Instead:

- Each machine only switches the monitors it **currently owns** (its active inputs).
  `Set-Preset` skips the rest automatically (`[SKIP] ... no DDC`).
- A hotkey applies the preset **locally** and **forwards** it over TCP (token-checked) to the peer,
  which switches the monitors *it* owns. Together the two halves give the full layout, and neither
  machine ever needs DDC on an inactive input.

Because a hotkey is handled on whichever machine has the keyboard (the CM662 USB switch decides
that), every preset must be applicable from **either** side. That's why the daemon runs on both
machines and the config is shared.

## Identifying monitors
Windows' `dxva2` physical-monitor description is usually just `Generic PnP Monitor`, so it can't
tell two monitors apart. The desktop rectangle from `EnumDisplayMonitors` can, so monitors are
matched by rules on **aspect ratio** or exact **resolution**, evaluated in order (first match
wins). Aspect ratio is preferred because the reported resolution can be DPI-scaled in a
DPI-unaware process, while the ratio stays the same. A display without DDC/CI, such as a
laptop's built-in panel, is labelled `Internal/Other` and never matched.

## Behaviour FAQ
- **After a reboot, do I need to restart anything?** No. The scheduled task starts the daemon at
  **sign-in**, on **unlock** and on **resume from sleep**. It isn't active on the lock screen before
  you sign in: the hotkeys and the wheel need your desktop session. Before sign-in the only thing
  that could run is a SYSTEM service in session 0, and session 0 can't see the physical monitors.
  It's rarely needed anyway: monitors showing the *other* machine can still be pulled over from it.
- **Does it work if one machine is off?** Partially. The machine that's on controls the monitors
  showing it. A monitor showing the **off** machine is stuck, because that machine can't send DDC
  and the other machine is on the monitor's inactive input. It recovers when the machine powers
  back on, through the monitor's own Auto Source, or with the physical input button.
- **Does it work with the software on only one machine?** Not for a full swap: you can push your
  own screens away but never pull a monitor back from the other machine. **Install on both.**

## Flicker
There were two different black-outs, and only one came from this tool:

- **Redundant re-select (fixed):** the input command used to be sent even when the monitor was
  already on that input, which forced an unnecessary HDMI/DP re-handshake. `Set-Preset` now reads
  the current input and **skips it when it already matches** (`[SAME]`), so a monitor that isn't
  changing no longer flashes.
- **Real input change (unavoidable):** switching a monitor between machines drops and
  re-negotiates the video link (DP/HDMI + HDCP), about 1–3 s of black. The physical button does
  the same, and no software can remove it.

Ways to reduce the flash on a real switch:
- Prefer **DisplayPort** over HDMI where possible, because its link training is faster.
- The OSD **Auto Source** setting does **not** speed up a commanded DDC switch, since the exact
  input is named and no scan happens. Leaving Auto Source **on** helps anyway: a monitor whose
  input goes dead (machine off) can recover to the live one by itself.

## Monitor settings
Brightness, contrast, picture mode and the rest follow the same rule as inputs: a machine can only
talk to the monitors it's showing. So a settings action is run locally and forwarded, exactly like
a preset. Relative values (`+10`) are applied by whichever machine owns each monitor.

Safety checks, in `Set-MonitorFeature`:
- **Whitelist.** Only the features in `$script:Features` can be written. Power mode (`0xD6`), factory
  reset (`0x04`), degauss and the like are never sent.
- **Capabilities.** The monitor's MCCS capabilities string is fetched once (it's slow, about 1 s) and
  cached. A feature whose code isn't advertised is skipped, and list values must be advertised ones.
  Without capabilities, a range above 1000 is treated as "unsupported". For example, the X340
  answers volume reads with max 65535 but has no speakers.
- **Clamping and no redundant writes.** Ranges are clamped to the monitor's own max, and a value
  that already matches isn't re-sent. Writes pause 60 ms (250 ms after a mode change), as MCCS asks.

Hardware findings (PRISM+ X340 PRO / F270i PRO, both MStar):
- **X340:** picture mode is standard `0xDC`: `00` Standard, `03` Movie. Its OSD lists Movie, Read
  and Night. `02` selected Read once but not on a later try, and it reads back as `00`. `05` changes
  brightness but the OSD showed Movie. Both are left out. Because readback can't be trusted, picture
  mode is flagged `AlwaysWrite` (never skipped as "already set") and is ignored when deciding whether
  a profile is on.
- **X340 ignores RGB gains over DDC** (`0x16`/`0x18`/`0x1A` accept writes but never change). Its
  Reading look therefore switches to the User1 colour preset, which you warm up once in the OSD,
  and lowers brightness.
- **F270i:** no `0xDC`. Its ten presets are on vendor code **`0xE0`**, in OSD order: 0 STD, 1 RTS, 2 FPS,
  3 MOBA, 4 Movie, 5 Reading, 6 Night, 7 Eye care, 8 MAC, 9 eBook. Config maps it with
  `Codes = @{ PictureMode = 0xE0 }`. It also advertises `0xE1` (0–4), `0xE2` and `0xF0`, which are
  untested and unused.
- Changing picture mode changes brightness on both monitors (each mode remembers its own).

**Reading toggle.** Switching on saves the current values of the profile's features to
`state.local.json` (per machine, git-ignored), then applies the profile. Switching off restores
them in reverse order (gains before colour preset, mode last). The profile counts as "on" if
settings were saved here, or if the monitor visibly matches it, which covers a profile switched on
from the other machine. With nothing saved to restore, the `Normal` profile is applied instead.

## Matching different panels
The same raw number looks different on different panels. Two tools:
- **Looks** store each monitor's own values (mode, colour preset, brightness, contrast, gains,
  volume) under one name, so "matched by eye" can be recalled exactly. A look is saved per monitor,
  and saving keeps the entries of monitors currently on the other machine.
- **Calibration** maps a shared 0–100 level to each monitor's raw value through three points
  matched by eye (piecewise linear). Relative steps, percentages, profiles, looks and status all work
  in levels, so `Set:Brightness=-10` on All dims both by the same visible amount, and level 0 is each
  panel's matched floor. Raw values are clamped to the monitor's max, and the curve is forced to rise
  with the level so it can be inverted.

## Hotkey latency
A settings press costs an enumeration, a couple of DDC reads and a write per monitor (about
0.3–0.5 s). Two things keep this from feeling laggy:
- **Merging.** After handling a press, queued `WM_HOTKEY`s are drained with `PeekMessage`. Repeats
  of the same relative action are summed (up to 3 presses' worth) into one step. Other hotkeys
  keep their order.
- **No trailing sleep.** The MCCS gap is enforced before the *next* write to the same monitor
  (`$script:NextWriteAt`), not after every write.

Relative hotkeys (`+N` / `-N`) are registered without `MOD_NOREPEAT`, so holding them repeats.

## Wheel
A WPF window compiled from C# (`ddc-wheel.ps1`) and shown modally on the daemon's own thread, so
its callbacks can run the PowerShell engine directly. Consequences:
- The daemon's `GetMessage` loop now dispatches non-hotkey messages. Otherwise WPF's hidden windows
  would lose posted messages between uses, and the dispatcher would stall on the next open.
- While the wheel is open, hotkeys arrive in WPF's message loop. Only the wheel's own hotkey (close)
  is acted on.
- Forwarding to the peer runs on a background thread (`PeerSender`), so a peer that's off (1.5 s
  connect timeout) never freezes the wheel or a hotkey. Order is preserved.
- Scroll notches are batched for 220 ms into a single relative change.

## Crash fix: PHYSICAL_MONITOR marshalling
The daemon used to die silently after hours or days with `0xc0000374` (heap corruption) in ntdll.
`PHYSICAL_MONITOR.szPhysicalMonitorDescription` is `WCHAR[128]`, but the struct lacked
`CharSet.Unicode`, so .NET allocated 136 bytes per monitor while dxva2 wrote 264. Every lookup
overran the buffer. Now fixed. Physical-monitor handles are also released after each use
(`Close-Monitors`). Since they used to leak, a single-instance mutex plus the unlock and wake
triggers mean any future crash heals itself the next time you unlock.

## Coordination protocol
One TCP connection per action carrying a single line, `<token>:<action>\n`, where the action is a
preset name or a settings action (`Set:` / `Profile:` / `Toggle:`). The listener:
- accepts only connections from `PeerHost`'s resolved address (`RestrictToPeer`). On a miss it
  re-resolves once, because DNS may not be ready yet at logon;
- gives the client 2 s to send (`ReceiveTimeout`), so a silent connection can't stall the
  single-threaded accept loop;
- rejects lines with the wrong token and logs every outcome.

The daemon won't open the port at all if the token is missing, still the template placeholder,
shorter than 16 characters, or contains `:`. In that case it runs local-only.

This is **authentication by shared secret, not encryption.** The token travels in plaintext, so
run it over Tailscale (WireGuard-encrypted) or a trusted LAN. See *Security model* in the README.

## Maintenance notes
- **Restart the daemon after changing an engine or hotkey.** `ddc-lib.ps1`, `ddc-hotkeys.ps1` and
  the `Hotkeys`/`Network` config are loaded once at startup (presets and input codes are re-read on
  every press). The daemon may run **elevated**, so restart it from an elevated shell, or just sign
  out and back in.
- **Keep files in sync across machines.** Everything except `machine.local.psd1` should be
  identical on both. `machine.local.psd1` is per-machine (a different `PeerHost`).
- **Re-capture after a cable change:** `ddc.ps1 capture PC` / `capture Laptop` prints the current
  codes and flags any that differ from the config.
