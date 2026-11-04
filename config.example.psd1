@{
    # SHARED config: copy to config.psd1 and keep it IDENTICAL on both machines.
    # config.psd1 is git-ignored because it holds your Network.Token.

    # Monitors: an ordered list. Each physical monitor gets the Name of the FIRST rule whose Match
    # criteria all pass. Criteria (all optional): MinAspect, MaxAspect, Width, Height.
    # Aspect ratio is the most robust (resolution can be reported DPI-scaled); `ddc.ps1 list` shows
    # what your monitors report. An empty Match matches anything - keep it last as the fallback.
    #
    # Every other plain key is a "side" (a machine) -> that machine's DDC input code (VCP 0x60) on
    # this monitor. Find them with `ddc.ps1 capture PC` / `ddc.ps1 capture Laptop`, run while the
    # monitors are showing that machine.
    #
    # Optional PictureModes / ColorTemps rename that monitor's VCP 0xDC / 0x14 values to what its
    # on-screen menu calls them; they also become the wheel's choices. `ddc.ps1 caps` lists the
    # values a monitor supports. Without them, the MCCS standard names are used.
    # Optional Codes moves a feature to a vendor-specific VCP code. Only do this for a code you
    # have tested while watching the on-screen menu; values must then be listed by name.
    Monitors = @(
        # 34" 21:9 ultrawide. Codes 0x02 and 0x05 are advertised but don't reliably select the OSD's
        # Read / Night modes, so they're left out.
        @{ Name = 'X340 PRO';  Match = @{ MinAspect = 2.0 }; PC = 0x08; Laptop = 0x05
           PictureModes = @{ Standard = 0x00; Movie = 0x03 }
           ColorTemps   = @{ '6500K' = 0x05; '9300K' = 0x08; User1 = 0x0B; User2 = 0x0C } }
        # 27" 16:9 (fallback). Its picture modes are on vendor code 0xE0, in OSD menu order.
        @{ Name = 'F270i PRO'; Match = @{};                  PC = 0x0F; Laptop = 0x11
           Codes        = @{ PictureMode = 0xE0 }
           PictureModes = @{ Standard = 0; RTS = 1; FPS = 2; MOBA = 3; Movie = 4; Reading = 5; Night = 6; EyeCare = 7; MAC = 8; eBook = 9 }
           ColorTemps   = @{ '6500K' = 0x05; '7500K' = 0x06; '9300K' = 0x08; User1 = 0x0B; User2 = 0x0C; User3 = 0x0D } }
    )

    # Named presets: monitor Name -> which side it should show.
    Presets = @{
        'A'         = @{ 'X340 PRO' = 'Laptop'; 'F270i PRO' = 'PC' }       # side-by-side
        'B'         = @{ 'X340 PRO' = 'PC';     'F270i PRO' = 'Laptop' }   # swapped
        'AllPC'     = @{ 'X340 PRO' = 'PC';     'F270i PRO' = 'PC' }       # classic KVM -> PC
        'AllLaptop' = @{ 'X340 PRO' = 'Laptop'; 'F270i PRO' = 'Laptop' }   # classic KVM -> Laptop
    }
    # Optional friendlier names for presets on the wheel.
    PresetLabels = @{ A = 'Laptop wide'; B = 'PC wide'; AllPC = 'All PC'; AllLaptop = 'All Laptop' }

    # Profiles: named sets of monitor settings. Features: PictureMode, ColorTemp, Brightness,
    # Contrast, RedGain, GreenGain, BlueGain, Volume, Mute. Use absolute values (40, not +10).
    # A block named after a monitor overrides values for that monitor only.
    # 'Reading' gets its own wheel slice and is toggled: switching it on saves the current settings,
    # switching it off restores them. 'Normal' is the fallback when nothing was saved.
    # The F270i has a built-in Reading mode, so Reading selects it. The X340's can't be selected over
    # DDC, and it ignores RGB gains sent over DDC, so its block drops the mode ($null) and switches to
    # the User1 colour preset (set it to warm colours once in the X340's own menu) and dims it.
    Profiles = @{
        Reading = @{
            PictureMode = 'Reading'
            'X340 PRO'  = @{ PictureMode = $null; ColorTemp = 'User1'; Brightness = 40 }
        }
        Normal  = @{ PictureMode = 'Standard'; ColorTemp = '6500K' }
    }

    # Saved looks and brightness calibration aren't in this file: `ddc.ps1 save <Name>` and
    # `ddc.ps1 calibrate` write them to saved.psd1 next to it. Copy that to the other machine too.

    # Global hotkeys (daemon). Modifiers: Ctrl, Alt, Shift, Win. Keys: A-Z, 0-9, F1-F24, Space,
    # Up, Down, Left, Right, PageUp, PageDown.
    # Action: a preset name, 'Wheel' (radial menu), or Set:<Feature>=<Value>[@<Monitor>],
    # Profile:<Name>[@<Monitor>], Toggle:<Name>[@<Monitor>], Look:<Name>[@<Monitor>].
    # Values: 40, 40%, +10, -10, a name, or Next / Prev for picture mode and colour temp.
    # Relative steps (+10 / -10) repeat while the keys are held; add Repeat = $false to stop that.
    Hotkeys = @(
        @{ Keys = 'Ctrl+Alt+1';     Action = 'A' }
        @{ Keys = 'Ctrl+Alt+2';     Action = 'B' }
        @{ Keys = 'Ctrl+Alt+P';     Action = 'AllPC' }
        @{ Keys = 'Ctrl+Alt+L';     Action = 'AllLaptop' }
        @{ Keys = 'Ctrl+Alt+Space'; Action = 'Wheel' }
        @{ Keys = 'Ctrl+Alt+Up';    Action = 'Set:Brightness=+10' }
        @{ Keys = 'Ctrl+Alt+Down';  Action = 'Set:Brightness=-10' }
        @{ Keys = 'Ctrl+Alt+R';     Action = 'Toggle:Reading' }
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
