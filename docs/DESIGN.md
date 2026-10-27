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
- **After a reboot, do I need to restart anything?** No. Autostart relaunches the daemon at
  **sign-in** on each machine. It isn't active on the lock screen before you sign in.
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

## Coordination protocol
One TCP connection per preset carrying a single line, `<token>:<preset>\n`. The listener:
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
