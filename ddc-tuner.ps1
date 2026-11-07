<#
    ddc-tuner.ps1  -  "Tuner" window: tune each monitor live and save the result into a profile.
    Dot-sourced by ddc-hotkeys.ps1 (Tune hotkey / wheel slice) and ddc.ps1 (`ddc.ps1 tune`).

    1. Click a profile (Normal, Gaming, Reading, or + New) - its current settings are loaded onto
       the monitors so you start from it.
    2. Drag the sliders / click the presets on each monitor's card. Changes show on the monitor
       live (they are batched, so dragging doesn't flood the monitor).
    3. Save writes them to saved.psd1 -> Profiles, layered over config.psd1. Revert (or closing
       without saving) puts the monitors back the way they were.
    Only monitors showing this machine can be tuned; the other card says so.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -ReferencedAssemblies WindowsBase -TypeDefinition @"
using System;
using System.Windows.Threading;
public static class UiPost {
    // Wrap a UI callback so it can be called from any thread: it runs on the dispatcher's thread.
    public static Action<string> Wrap(Dispatcher d, Action<string> a) { return s => d.BeginInvoke(a, s); }
}
"@ -ErrorAction SilentlyContinue

$script:TunerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Monitor tuner" Width="1060" SizeToContent="Height" MinHeight="400"
        WindowStartupLocation="CenterScreen" Background="#15161B" Foreground="#F2F2F5"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="AccentBrush" Color="#FFC857"/>
    <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    <Style x:Key="H2" TargetType="TextBlock"><Setter Property="FontSize" Value="17"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,4"/></Style>
    <Style x:Key="Muted" TargetType="TextBlock"><Setter Property="Foreground" Value="#9A9CA8"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style x:Key="Label" TargetType="TextBlock"><Setter Property="Foreground" Value="#B9BBC6"/><Setter Property="FontSize" Value="11.5"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,14,0,6"/></Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#1E1F26"/><Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="20,16"/><Setter Property="Margin" Value="8"/>
      <Setter Property="BorderBrush" Value="#2C2E38"/><Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#F2F2F5"/><Setter Property="Background" Value="#2A2C35"/>
      <Setter Property="Padding" Value="16,8"/><Setter Property="Margin" Value="6,0,0,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="AccentBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FFC857"/><Setter Property="Foreground" Value="#141418"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E6E6EA"/><Setter Property="Margin" Value="0,0,6,6"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="#2A2C35" CornerRadius="13" Padding="12,5" BorderBrush="#363945" BorderThickness="1">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#353845"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="#FFC857"/><Setter TargetName="b" Property="BorderBrush" Value="#FFC857"/>
              <Setter Property="Foreground" Value="#141418"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="TrackFill" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Border Height="4" CornerRadius="2" Background="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Slider}}"/>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="TrackEmpty" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Knob" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Ellipse Width="16" Height="16" Fill="#FFFFFF" Stroke="#15161B" StrokeThickness="2"/>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="Foreground" Value="#FFC857"/><Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/><Setter Property="TickFrequency" Value="1"/>
      <Setter Property="SmallChange" Value="1"/><Setter Property="LargeChange" Value="5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Grid Height="24" Background="Transparent">
            <Border Height="4" CornerRadius="2" Background="#33FFFFFF" VerticalAlignment="Center"/>
            <Track x:Name="PART_Track">
              <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Style="{StaticResource TrackFill}"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Style="{StaticResource TrackEmpty}"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource Knob}"/></Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#D6D7DE"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#2A2C35"/><Setter Property="Foreground" Value="#F2F2F5"/><Setter Property="BorderBrush" Value="#363945"/>
      <Setter Property="CaretBrush" Value="#F2F2F5"/><Setter Property="Padding" Value="6,4"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="8,0,8,4">
      <TextBlock Text="Monitor tuner" Style="{StaticResource H1}"/>
      <TextBlock Style="{StaticResource Muted}" Margin="0,4,0,0"
                 Text="1. Pick a profile to load it.   2. Tune each monitor (changes show live).   3. Save it to the profile. Revert or closing without saving puts things back."/>
    </StackPanel>

    <Border Grid.Row="1" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="PROFILE" Style="{StaticResource Label}" Margin="0,0,0,8"/>
        <WrapPanel x:Name="ProfilePanel"/>
        <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
          <TextBox x:Name="NewName" Width="170" ToolTip="Name for a new profile"/>
          <Button x:Name="AddBtn" Content="+ New profile" Style="{StaticResource Btn}" Padding="12,5"/>
          <CheckBox x:Name="LinkBox" Content="Move both monitors' brightness and contrast together" Margin="24,0,0,0" IsChecked="False"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <UniformGrid Grid.Row="2" x:Name="Cards" Rows="1"/>

    <DockPanel Grid.Row="3" Margin="8,10,8,0" LastChildFill="True">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="RevertBtn" Content="Revert" Style="{StaticResource Btn}"/>
        <Button x:Name="SaveBtn" Content="Save" Style="{StaticResource AccentBtn}" MinWidth="150"/>
        <Button x:Name="CloseBtn" Content="Close" Style="{StaticResource Btn}"/>
      </StackPanel>
      <TextBlock x:Name="Status" Style="{StaticResource Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Text="Reading monitors..."/>
    </DockPanel>
  </Grid>
</Window>
'@

# Show the tuner (modal). $Call runs a ddc-lib function and calls back on the UI thread:
#   & $Call <FunctionName> <string[] args> <scriptblock param($resultText)>
# The daemon routes it to its DDC worker thread; the CLI runs it directly.
function Show-DdcTuner {
    param([Parameter(Mandatory)][scriptblock]$Call, [string]$StartProfile, [scriptblock]$TestHook)

    $win = [Windows.Markup.XamlReader]::Parse($script:TunerXaml)
    $ui = @{}
    foreach ($n in 'ProfilePanel', 'NewName', 'AddBtn', 'LinkBox', 'Cards', 'RevertBtn', 'SaveBtn', 'CloseBtn', 'Status') { $ui[$n] = $win.FindName($n) }

    # Replies can arrive after the window has closed (Save or Revert on close). By then this
    # function has returned, so its callbacks would run with no $st / Set-Status and throw; in the
    # daemon that exception escaped the message loop and took every hotkey with it. So once the
    # window is closed, replies are dropped (the monitor write itself still happens), and while
    # it's open a failing callback shows in the status line instead of escaping.
    # (GetNewClosure only captures the current scope's variables, hence the local copies.)
    $life = @{ Open = $true }
    $rawCall = $Call
    $Call = {
        param($c, $a, $done)
        $lf = $life; $st0 = $ui.Status; $cb = $done
        $guarded = {
            param($r)
            if (-not $lf.Open) { return }
            try { & $cb $r } catch { try { $st0.Text = 'Error: ' + $_.Exception.Message } catch { $null = $_ } }
        }.GetNewClosure()
        & $rawCall $c $a $guarded
    }.GetNewClosure()
    $st = @{
        Sig = ''; Ctl = @{}; Loading = $false; Dirty = $false; Busy = $false; Refresh = $false; Linking = $false
        Pending = @{}; Snapshot = $null; Profile = $StartProfile; Profiles = @(); Reachable = @(); Closing = $false
    }
    $labels = @{ PictureMode = 'PICTURE MODE'; ColorTemp = 'COLOUR PRESET'; Brightness = 'BRIGHTNESS'; Contrast = 'CONTRAST'
                 RedGain = 'RED'; GreenGain = 'GREEN'; BlueGain = 'BLUE' }
    $tints = @{ RedGain = '#FF6B6B'; GreenGain = '#5FD38D'; BlueGain = '#5BA8FF' }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(110)

    function Set-Status([string]$t) { $ui.Status.Text = $t }

    # A result from ddc-lib -> one short status line.
    function Get-Summary([string]$r) {
        $lines = @($r -split "`n" | Where-Object { $_ })
        $bad = @($lines | Where-Object { $_ -match '^\[(FAIL|SKIP)\]|^Error' })
        if ($bad.Count) { return ($bad -join '   ') }
        return "Applied ($(Get-Date -Format 'HH:mm:ss'))"
    }

    function Update-Buttons {
        $ui.SaveBtn.IsEnabled = [bool]$st.Profile -and $st.Reachable.Count -gt 0
        $ui.SaveBtn.Content = if ($st.Profile) { "Save to '$($st.Profile)'" + $(if ($st.Dirty) { ' *' }) } else { 'Pick a profile to save' }
        $ui.RevertBtn.IsEnabled = $null -ne $st.Snapshot
    }

    # Values currently on the controls: @{ <monitor> = [ordered]@{ <feature> = '<value>' } }
    function Get-ControlValues {
        $out = @{}
        foreach ($key in $st.Ctl.Keys) {
            $mon, $f = $key -split '\|', 2
            $c = $st.Ctl[$key]
            $v = if ($c.Kind -eq 'Range') { [string][int]$c.Slider.Value } else { ($c.Chips | Where-Object { $_.IsChecked } | Select-Object -First 1).Content }
            if ($null -eq $v) { continue }
            if (-not $out[$mon]) { $out[$mon] = [ordered]@{} }
            $out[$mon][$f] = [string]$v
        }
        return $out
    }

    function Get-StateValues($s) {
        $out = @{}
        foreach ($m in @($s.Monitors)) {
            if (-not $m.Reachable) { continue }
            $vals = [ordered]@{}
            foreach ($p in $m.Features.PSObject.Properties) { $vals[$p.Name] = [string]$p.Value.Value }
            $out[$m.Name] = $vals
        }
        return $out
    }

    function Add-ProfileChip([string]$name) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.Style = $win.FindResource('Chip'); $rb.Content = $name; $rb.GroupName = 'profile'; $rb.Tag = $name
        $rb.IsChecked = ($name -eq $st.Profile)
        $rb.Add_Checked({ param($src, $evt) if (-not $st.Loading) { Select-Profile ([string]$src.Tag) } })
        [void]$ui.ProfilePanel.Children.Add($rb)
    }

    function Build-ProfileChips {
        $st.Loading = $true
        try {
            $ui.ProfilePanel.Children.Clear()
            $names = @($st.Profiles)
            if ($st.Profile -and $names -notcontains $st.Profile) { $names += $st.Profile }
            foreach ($n in $names) { Add-ProfileChip $n }
        } finally { $st.Loading = $false }
    }

    # Picking an existing profile applies it so tuning starts from it. A new one starts from what's on screen.
    function Select-Profile([string]$name) {
        if ($st.Dirty -and $st.Profile -and $st.Profile -ne $name) {
            $ans = [Windows.MessageBox]::Show($win, "Discard your unsaved changes to '$($st.Profile)'?", 'Monitor tuner', 'YesNo', 'Question')
            if ($ans -ne 'Yes') { Build-ProfileChips; return }
        }
        $st.Profile = $name
        if ($st.Profiles -notcontains $name) { $st.Dirty = $true; Update-Buttons; Set-Status "New profile '$name': tune, then Save."; return }
        $st.Pending = @{}; $timer.Stop()
        $st.Busy = $true
        Set-Status "Loading '$name'..."
        & $Call 'Invoke-DdcAction' @("Profile:$name") {
            param($r)
            $st.Busy = $false; $st.Dirty = $false
            Set-Status ("Loaded '$($st.Profile)'. " + (Get-Summary $r))
            Request-State
        }
        Update-Buttons
    }

    function Request-State {
        & $Call 'Get-DdcTuneState' @() {
            param($json)
            if ($json -notmatch '^\s*\{') { Set-Status ("Couldn't read the monitors: " + $json); return }
            Show-State ($json | ConvertFrom-Json)
        }
    }

    function Show-State($s) {
        if ($null -eq $st.Snapshot) { $st.Snapshot = Get-StateValues $s }
        $st.Profiles = @($s.Profiles)
        $st.Reachable = @($s.Monitors | Where-Object { $_.Reachable } | ForEach-Object { $_.Name })
        if ($ui.ProfilePanel.Children.Count -eq 0) { Build-ProfileChips }
        $sig = (@($s.Monitors) | ForEach-Object {
            $m = $_
            "$($m.Name):$($m.Reachable):" + $(if ($m.Features) { (@($m.Features.PSObject.Properties) | ForEach-Object { $_.Name + '=' + (@($_.Value.Options) -join '/') + '/' + $_.Value.Max }) -join ',' })
        }) -join ';'
        if ($sig -ne $st.Sig) { Build-Cards $s; $st.Sig = $sig }
        $st.Loading = $true
        try {
            foreach ($m in @($s.Monitors)) {
                if (-not $m.Reachable) { continue }
                foreach ($p in $m.Features.PSObject.Properties) {
                    if ($st.Pending[$m.Name] -and $st.Pending[$m.Name].Contains($p.Name)) { continue }   # don't fight a drag in progress
                    $c = $st.Ctl["$($m.Name)|$($p.Name)"]
                    if (-not $c) { continue }
                    if ($c.Kind -eq 'Range') { $c.Slider.Value = [double]$p.Value.Value; $c.Label.Text = [string]$p.Value.Value }
                    else { foreach ($rb in $c.Chips) { $rb.IsChecked = ([string]$rb.Content -eq [string]$p.Value.Value) } }
                }
            }
        } finally { $st.Loading = $false }
        if ($ui.Status.Text -eq 'Reading monitors...') { Set-Status 'Pick a profile to load it, or tune what is on screen now.' }
        Update-Buttons
    }

    function New-Text([string]$text, [string]$style) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $text
        if ($style) { $t.Style = $win.FindResource($style) }
        return $t
    }

    function Build-Cards($s) {
        $ui.Cards.Children.Clear(); $st.Ctl = @{}
        $ui.Cards.Columns = [Math]::Max(1, @($s.Monitors).Count)
        foreach ($m in @($s.Monitors)) {
            $card = New-Object Windows.Controls.Border; $card.Style = $win.FindResource('Card')
            $sp = New-Object Windows.Controls.StackPanel; $card.Child = $sp
            [void]$sp.Children.Add((New-Text $m.Name 'H2'))
            if (-not $m.Reachable) {
                [void]$sp.Children.Add((New-Text 'Showing the other machine, so it can only be tuned from there. Switch it to this machine (wheel > Layout) to tune it here.' 'Muted'))
                [void]$ui.Cards.Children.Add($card); continue
            }
            $hasGain = $false
            foreach ($f in $script:TuneFeatures) {
                $p = $m.Features.$f
                if (-not $p) { continue }
                $key = "$($m.Name)|$f"
                $lab = New-Text $labels[$f] 'Label'
                [void]$sp.Children.Add($lab)
                if ($null -ne $p.Options) {
                    $wrap = New-Object Windows.Controls.WrapPanel
                    $chips = @()
                    foreach ($o in @($p.Options)) {
                        $rb = New-Object Windows.Controls.RadioButton
                        $rb.Style = $win.FindResource('Chip'); $rb.Content = [string]$o; $rb.GroupName = $key
                        $rb.Tag = @{ Mon = $m.Name; Feature = $f; Value = [string]$o }
                        $rb.Add_Checked({ param($src, $evt) if ($st.Loading) { return }; $t = $src.Tag; Add-Change $t.Mon $t.Feature $t.Value $true })
                        [void]$wrap.Children.Add($rb); $chips += $rb
                    }
                    [void]$sp.Children.Add($wrap)
                    $st.Ctl[$key] = @{ Kind = 'List'; Chips = $chips }
                } else {
                    if ($f -like '*Gain') { $hasGain = $true; $lab.Margin = '0,8,0,2' }
                    $g = New-Object Windows.Controls.Grid
                    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '*'
                    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '44'
                    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
                    $sl = New-Object Windows.Controls.Slider
                    $sl.Minimum = 0; $sl.Maximum = [double]$p.Max; $sl.Value = [double]$p.Value
                    if ($tints[$f]) { $sl.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($tints[$f]) }
                    $sl.Tag = @{ Mon = $m.Name; Feature = $f }
                    $val = New-Text ([string]$p.Value) $null
                    $val.HorizontalAlignment = 'Right'; $val.VerticalAlignment = 'Center'; $val.FontWeight = 'SemiBold'
                    [Windows.Controls.Grid]::SetColumn($val, 1)
                    [void]$g.Children.Add($sl); [void]$g.Children.Add($val)
                    [void]$sp.Children.Add($g)
                    $st.Ctl[$key] = @{ Kind = 'Range'; Slider = $sl; Label = $val }
                    $sl.Add_ValueChanged({
                        param($src, $evt)
                        $t = $src.Tag
                        $v = [int]$src.Value
                        $st.Ctl["$($t.Mon)|$($t.Feature)"].Label.Text = [string]$v
                        if ($st.Loading) { return }
                        Add-Change $t.Mon $t.Feature ([string]$v) $false
                        if ($ui.LinkBox.IsChecked -and $t.Feature -in 'Brightness', 'Contrast' -and -not $st.Linking) {
                            $st.Linking = $true
                            try {
                                foreach ($k in @($st.Ctl.Keys)) {
                                    if ($k -like "*|$($t.Feature)" -and $k -ne "$($t.Mon)|$($t.Feature)") { $st.Ctl[$k].Slider.Value = $src.Value }
                                }
                            } finally { $st.Linking = $false }
                        }
                    })
                }
            }
            if ($hasGain) {
                $note = New-Text 'Red / green / blue usually only take effect in a User colour preset, and some monitors ignore them over DDC.' 'Muted'
                $note.Margin = '0,10,0,0'; $note.FontSize = 11.5
                [void]$sp.Children.Add($note)
            }
            [void]$ui.Cards.Children.Add($card)
        }
    }

    # Queue a change; it's sent after a short pause, and never while the previous batch is running.
    function Add-Change([string]$mon, [string]$feature, [string]$value, [bool]$isList) {
        if (-not $st.Pending[$mon]) { $st.Pending[$mon] = [ordered]@{} }
        $st.Pending[$mon][$feature] = $value
        if ($isList) { $st.Refresh = $true }   # a preset can change other values: re-read afterwards
        $st.Dirty = $true
        Update-Buttons
        $timer.Stop(); $timer.Start()
    }

    function Send-Pending {
        if ($st.Busy -or $st.Pending.Count -eq 0) { return }
        $json = $st.Pending | ConvertTo-Json -Compress -Depth 4
        $st.Pending = @{}
        $st.Busy = $true
        & $Call 'Set-DdcTuneSettings' @($json) {
            param($r)
            $st.Busy = $false
            if (-not $st.Closing) { Set-Status (Get-Summary $r) }
            if ($st.Pending.Count) { Send-Pending }
            elseif ($st.Refresh -and -not $st.Closing) { $st.Refresh = $false; Request-State }
        }
    }
    $timer.Add_Tick({ $timer.Stop(); Send-Pending })

    function Save-Current {
        $vals = Get-ControlValues
        if (-not $vals.Count) { Set-Status 'Nothing to save: no monitor on this machine.'; return }
        $json = $vals | ConvertTo-Json -Compress -Depth 4
        $name = $st.Profile
        $st.Pending = @{}; $timer.Stop()
        & $Call 'Set-DdcTuneSettings' @($json) { param($r) }   # make sure the monitors show exactly what's saved
        & $Call 'Save-DdcTuneProfile' @($name, $json) {
            param($r)
            if (-not $st.Closing) { Set-Status ($r + '. Copy saved.psd1 to the other machine too.') }
        }
        $st.Snapshot = $vals; $st.Dirty = $false
        if ($st.Profiles -notcontains $name) { $st.Profiles += $name }
        Update-Buttons
    }

    function Undo-Changes([string]$message) {
        if ($null -eq $st.Snapshot) { return }
        $st.Pending = @{}; $timer.Stop()
        $json = $st.Snapshot | ConvertTo-Json -Compress -Depth 4
        & $Call 'Set-DdcTuneSettings' @($json) {
            param($r)
            if (-not $st.Closing) { Set-Status $message; Request-State }
        }
        $st.Dirty = $false
        Update-Buttons
    }

    $ui.AddBtn.Add_Click({
        $n = $ui.NewName.Text.Trim()
        if ($n -notmatch '^[\w][\w \-]{0,31}$') { Set-Status 'Profile names: letters, digits, space, - and _ (up to 32).'; return }
        $ui.NewName.Text = ''
        if ($st.Profiles -notcontains $n) { $st.Loading = $true; try { Add-ProfileChip $n } finally { $st.Loading = $false } }
        foreach ($c in $ui.ProfilePanel.Children) { if ([string]$c.Tag -eq $n) { $c.IsChecked = $true } }
        if ($st.Profile -ne $n) { Select-Profile $n }
    })
    $ui.SaveBtn.Add_Click({ Save-Current })
    $ui.RevertBtn.Add_Click({ Undo-Changes 'Reverted to how the monitors were.' })
    $ui.CloseBtn.Add_Click({ $win.Close() })
    $win.Add_KeyDown({ param($src, $evt) if ($evt.Key -eq 'Escape') { $win.Close() } })
    $win.Add_Closing({
        param($src, $evt)
        $timer.Stop()
        if ($st.Dirty) {
            $q = if ($st.Profile) { "Save your changes to '$($st.Profile)'?`n`nNo puts the monitors back how they were." } else { "Keep these settings on the monitors?`n`nNo puts them back how they were. (Pick a profile to save them.)" }
            $ans = [Windows.MessageBox]::Show($win, $q, 'Monitor tuner', 'YesNoCancel', 'Question')
            if ($ans -eq 'Cancel') { $evt.Cancel = $true; return }
            $st.Closing = $true
            if ($ans -eq 'Yes') { if ($st.Profile) { Save-Current } else { Send-Pending } }
            else { Undo-Changes '' }
        } else {
            $st.Closing = $true
            Send-Pending
        }
    })
    if ($TestHook) {
        # Tests: keep the window off-screen and inactive, then hand control to the hook.
        $win.WindowStartupLocation = 'Manual'; $win.Left = -20000; $win.Top = -20000
        $win.ShowActivated = $false; $win.ShowInTaskbar = $false
        $win.Add_Loaded({ Update-Buttons; Request-State; & $TestHook })
    } else {
        $win.Add_Loaded({ $win.Activate(); Update-Buttons; Request-State })
    }
    try { [void]$win.ShowDialog() } finally { $life.Open = $false }
}
