@{
    # SHARED config: copy to config.psd1 and keep it IDENTICAL on both machines.
    # config.psd1 is git-ignored because it holds your Network.Token.

    # Monitors: an ordered list. Each physical monitor gets the Name of the FIRST rule whose Match
    # criteria all pass. Criteria (all optional): MinAspect, MaxAspect, Width, Height.
    # Aspect ratio is the most robust (resolution can be reported DPI-scaled); `ddc.ps1 list` shows
    # what your monitors report. An empty Match matches anything - keep it last as the fallback.
    #
    # Every other key is a "side" (a machine) -> that machine's DDC input code (VCP 0x60) on this
    # monitor. Find them with `ddc.ps1 capture PC` / `ddc.ps1 capture Laptop`, run while the
    # monitors are showing that machine.
    Monitors = @(
        @{ Name = 'X340 PRO';  Match = @{ MinAspect = 2.0 }; PC = 0x08; Laptop = 0x05 }   # 34" 21:9 ultrawide
        @{ Name = 'F270i PRO'; Match = @{};                  PC = 0x0F; Laptop = 0x11 }   # 27" 16:9 (fallback)
    )

    # Named presets: monitor Name -> which side it should show.
    Presets = @{
        'A'         = @{ 'X340 PRO' = 'Laptop'; 'F270i PRO' = 'PC' }       # side-by-side
        'B'         = @{ 'X340 PRO' = 'PC';     'F270i PRO' = 'Laptop' }   # swapped
        'AllPC'     = @{ 'X340 PRO' = 'PC';     'F270i PRO' = 'PC' }       # classic KVM -> PC
        'AllLaptop' = @{ 'X340 PRO' = 'Laptop'; 'F270i PRO' = 'Laptop' }   # classic KVM -> Laptop
    }

    # Global hotkeys (daemon). Modifiers: Ctrl, Alt, Shift, Win. Keys: A-Z, 0-9, F1-F24.
    Hotkeys = @(
        @{ Keys = 'Ctrl+Alt+1'; Preset = 'A' }
        @{ Keys = 'Ctrl+Alt+2'; Preset = 'B' }
        @{ Keys = 'Ctrl+Alt+P'; Preset = 'AllPC' }
        @{ Keys = 'Ctrl+Alt+L'; Preset = 'AllLaptop' }
    )

    # Coordination between the two daemons. Port + Token must match on both machines.
    # The daemon refuses to open the port (runs local-only) until Token is changed to a
    # random string of 16+ characters (no ':'). Generate one with:
    #   $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)
    Network = @{
        Port           = 58762
        Token          = 'CHANGE-ME'
        RestrictToPeer = $true    # only accept connections from this machine's PeerHost
    }
}
