#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir

; ============================================================
;  OLED Taskbar Dimmer  v3.1  -  AutoHotkey v2
;
;  - Black click-through overlay on the taskbar (multi-monitor)
;  - Mouse OVER the taskbar   -> taskbar returns to normal (fast fade)
;  - Mouse LEAVES the taskbar -> taskbar darkens gradually (fade)
;  - Left-click on the tray icon -> opacity slider popup (drag or mouse wheel)
;  - Right-click on the tray icon -> "Enable / Disable", "Start with Windows", "Exit"
;  - Ctrl+Alt+D            -> toggle on/off (animated)
;  - Ctrl+Alt+Up / Down    -> opacity +5% / -5%  (with tooltip)
;  - Ctrl+Alt+O            -> cycle presets 25 / 50 / 75 / 95 %
;  - Settings are saved to settings.ini
; ============================================================

; -- Animation (milliseconds) --------------------------------
global FADE_UNDIM_MS  := 120   ; hover: taskbar returns to normal
global FADE_DIM_MS    := 300   ; leave: taskbar darkens again
global FADE_TOGGLE_MS := 250   ; Ctrl+Alt+D toggle

; -- Config --------------------------------------------------
global CFG_FILE := A_ScriptDir "\settings.ini"

; Alpha: 0 = invisible overlay, 255 = solid black
; Opacity shown in the slider = (255 - Alpha) / 255 * 100
global TARGET_ALPHA := Integer(IniRead(CFG_FILE, "Settings", "Alpha", "13"))
global PRESETS := [25, 50, 75, 95]

; -- State ---------------------------------------------------
global g_enabled      := true
global g_hovering     := false
global g_overlays     := Map()   ; taskbarHwnd -> Gui
global g_curAlpha     := 0
global g_animFrom     := 0
global g_animTo       := 0
global g_animStart    := 0
global g_animDur      := 1
global g_animActive   := false
global g_hookCb       := 0
global g_hook         := 0
global g_shellFlyout  := false   ; Start menu / Search / flyouts are in the foreground
global g_fsMon        := Map()   ; monitors currently covered by a fullscreen window
global g_pctLabel     := 0
global g_slider       := 0
global g_settingsOpen := false
global g_sGui         := 0
global g_pic          := 0       ; picture control of the popup
global g_hbm          := 0       ; current popup bitmap
global g_popS         := 1       ; DPI scale of the popup
global g_popW         := 0
global g_popH         := 0
global g_lastClose    := 0
global g_openTick     := 0
global g_wasActive    := false
global g_gdipToken    := 0
global g_iconFile     := A_ScriptDir "\OLEDTaskbarDimmer.ico"

Main()

Main() {
    global g_hookCb, g_hook, g_iconFile
    GdipStart()
    try CreateIconFile(g_iconFile)
    SetupTray()
    SyncOverlays()

    ; Startup: dim immediately (no animation)
    SetAlpha(TARGET_ALPHA)

    OnMessage(0x404, OnTrayClick)
    OnMessage(0x201, PopupLButtonDown)   ; WM_LBUTTONDOWN (slider)
    OnMessage(0x20A, PopupWheel)         ; WM_MOUSEWHEEL (slider)

    ; React immediately whenever the foreground window changes
    ; (EVENT_SYSTEM_FOREGROUND = 0x0003), so the overlay is put back on top
    ; of the taskbar right after you click another program.
    g_hookCb := CallbackCreate(OnForeground, "F", 7)
    g_hook   := DllCall("SetWinEventHook",
        "UInt", 0x0003, "UInt", 0x0003, "Ptr", 0, "Ptr", g_hookCb,
        "UInt", 0, "UInt", 0, "UInt", 0x0002)   ; WINEVENT_SKIPOWNPROCESS

    Hotkey "^!d",     ToggleDimmer
    Hotkey "^!Up",    (*) => NudgeOpacity(+5)
    Hotkey "^!Down",  (*) => NudgeOpacity(-5)
    Hotkey "^!o",     CyclePreset

    SetTimer CheckMouseHover, 20
    SetTimer SyncOverlays, 2000
    SetTimer UpdateFullscreen, 300
}

; ============================================================
;  TRAY
; ============================================================
SetupTray() {
    try {
        TraySetIcon(g_iconFile)
    } catch {
        TraySetIcon("imageres.dll", 97)
    }
    A_IconTip := "OLED Taskbar Dimmer"

    tray := A_TrayMenu
    tray.Delete()   ; remove all default items
    tray.Add "Enable / Disable  [Ctrl+Alt+D]", ToggleDimmer
    tray.Check "Enable / Disable  [Ctrl+Alt+D]"   ; enabled at startup
    tray.Add()
    tray.Add "Start with Windows", ToggleStartup
    UpdateStartupCheck()
    tray.Add()
    tray.Add "Exit", (*) => ExitApp()
}

; Keeps the check mark of the Enable / Disable item in sync with the state
UpdateEnabledCheck() {
    global g_enabled
    try {
        if g_enabled
            A_TrayMenu.Check "Enable / Disable  [Ctrl+Alt+D]"
        else
            A_TrayMenu.Uncheck "Enable / Disable  [Ctrl+Alt+D]"
    }
}

; Single left-click on the tray icon opens the settings popup
OnTrayClick(wParam, lParam, msg, hwnd) {
    if (lParam = 0x202) {   ; WM_LBUTTONUP
        ShowSettings()
        return 0
    }
}

; ============================================================
;  START WITH WINDOWS
;  Creates / deletes a shortcut in the user's Startup folder.
; ============================================================
StartupLnkPath() => A_Startup "\OLEDTaskbarDimmer.lnk"
IsStartupEnabled() => FileExist(StartupLnkPath()) ? true : false

ToggleStartup(*) {
    lnk := StartupLnkPath()
    if IsStartupEnabled()
        FileDelete lnk
    else
        FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"', "OLED Taskbar Dimmer", FileExist(g_iconFile) ? g_iconFile : "imageres.dll", "", FileExist(g_iconFile) ? 1 : 97)
    UpdateStartupCheck()
}

UpdateStartupCheck() {
    try {
        if IsStartupEnabled()
            A_TrayMenu.Check "Start with Windows"
        else
            A_TrayMenu.Uncheck "Start with Windows"
    }
}

; ============================================================
;  OVERLAYS (one per taskbar: primary + secondary monitors)
; ============================================================
GetTaskbars() {
    list := []
    for hwnd in WinGetList("ahk_class Shell_TrayWnd")
        list.Push(hwnd)
    for hwnd in WinGetList("ahk_class Shell_SecondaryTrayWnd")
        list.Push(hwnd)
    return list
}

SyncOverlays() {
    global g_overlays, g_curAlpha
    alive := Map()

    for tb in GetTaskbars() {
        alive[tb] := true
        try WinGetPos &x, &y, &w, &h, "ahk_id " tb
        catch
            continue

        if !g_overlays.Has(tb) {
            g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x80000", "OLEDDimmerOverlay")
            g.BackColor := "000000"
            g.Show("x" x " y" y " w" w " h" h " NoActivate")
            SetOverlayAlpha(g.Hwnd, g_curAlpha)
            g_overlays[tb] := g
        }

        DllCall("SetWindowPos",
            "Ptr", g_overlays[tb].Hwnd,
            "Ptr", 0,
            "Int", x, "Int", y, "Int", w, "Int", h,
            "UInt", 0x0010 | 0x0004)   ; SWP_NOACTIVATE | SWP_NOZORDER
        SetOverlayAlpha(g_overlays[tb].Hwnd, g_curAlpha)
    }

    ; Remove overlays whose taskbar no longer exists
    for tb, g in g_overlays.Clone() {
        if !alive.Has(tb) {
            g.Destroy()
            g_overlays.Delete(tb)
        }
    }
    RaiseOverlays()
}

SetAlpha(a) {
    global g_curAlpha, g_overlays
    g_curAlpha := a
    for tb, g in g_overlays
        SetOverlayAlpha(g.Hwnd, a)
}

; Sets the opacity directly through the Windows API. Unlike WinSetTransparent
; it also works on hidden windows (the overlay is hidden while a fullscreen
; game is running), so it can never throw "Target window not found".
SetOverlayAlpha(hwnd, a) {
    DllCall("SetLayeredWindowAttributes",
        "Ptr", hwnd, "UInt", 0, "UChar", a, "UInt", 0x2)   ; LWA_ALPHA
}

; ============================================================
;  ANIMATION ENGINE (time-based, cubic ease-out)
; ============================================================
AnimateTo(alpha, ms) {
    global g_curAlpha, g_animFrom, g_animTo, g_animStart, g_animDur
    global g_animActive
    if (ms <= 0 || alpha = g_curAlpha) {
        SetTimer AnimFrame, 0
        g_animActive := false
        SetAlpha(alpha)
        return
    }
    g_animActive := true
    g_animFrom  := g_curAlpha
    g_animTo    := alpha
    g_animStart := A_TickCount
    g_animDur   := ms
    SetTimer AnimFrame, 10
}

AnimFrame() {
    global g_animFrom, g_animTo, g_animStart, g_animDur, g_animActive
    t := Min(1, (A_TickCount - g_animStart) / g_animDur)
    e := 1 - (1 - t) ** 3                      ; ease-out
    SetAlpha(Round(g_animFrom + (g_animTo - g_animFrom) * e))
    if (t >= 1) {
        SetTimer AnimFrame, 0
        g_animActive := false
    }
}

; Moves the overlay to the correct level for the current state
ApplyLevel(ms) {
    global g_enabled, g_hovering, TARGET_ALPHA
    UpdateEnabledCheck()
    if (g_enabled && !g_hovering)
        AnimateTo(TARGET_ALPHA, ms)
    else
        AnimateTo(0, ms)
}

; ============================================================
;  TASKBAR HOVER DETECTION
; ============================================================
; Brings every overlay back above the taskbar. Windows raises the taskbar
; itself on hover/click, which would otherwise bury the overlay beneath it.
RaiseOverlays() {
    global g_overlays
    for tb, g in g_overlays {
        ; Fullscreen / borderless game on this monitor: hide the overlay
        if IsMonitorFullscreen(tb) {
            if DllCall("IsWindowVisible", "Ptr", g.Hwnd)
                g.Hide()
            continue
        }
        if !DllCall("IsWindowVisible", "Ptr", g.Hwnd)
            g.Show("NoActivate")
        DllCall("SetWindowPos",
            "Ptr", g.Hwnd,
            "Ptr", -1,                 ; HWND_TOPMOST
            "Int", 0, "Int", 0, "Int", 0, "Int", 0,
            "UInt", 0x0010 | 0x0002 | 0x0001)   ; NOACTIVATE | NOMOVE | NOSIZE
    }
}

; True if a fullscreen window currently covers the monitor of this taskbar
IsMonitorFullscreen(tb) {
    global g_fsMon
    hMon := DllCall("MonitorFromWindow", "Ptr", tb, "UInt", 2, "Ptr")
    return g_fsMon.Has(hMon)
}

; Detects a fullscreen / borderless-fullscreen foreground window (games, videos)
; and remembers which monitor it covers.
UpdateFullscreen() {
    global g_fsMon, g_shellFlyout
    cur := Map()
    flyout := false
    try {
        hwnd := WinExist("A")

        ; Start menu / Search / Action Center in the foreground: they are part of
        ; the shell, not a game. The taskbar stays normal while they are open.
        if hwnd {
            proc := WinGetProcessName("ahk_id " hwnd)
            if (proc = "StartMenuExperienceHost.exe" || proc = "SearchHost.exe"
              || proc = "SearchApp.exe" || proc = "ShellExperienceHost.exe")
                flyout := true
        }

        if (hwnd && !flyout && WinGetMinMax("ahk_id " hwnd) != -1) {
            cls := WinGetClass("ahk_id " hwnd)
            if !(cls = "Progman" || cls = "WorkerW"
              || cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd"
              || cls = "Windows.UI.Core.CoreWindow") {
                WinGetPos &x, &y, &w, &h, "ahk_id " hwnd
                hMon := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
                mi := Buffer(40, 0)
                NumPut("UInt", 40, mi, 0)
                if DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", mi) {
                    l := NumGet(mi, 4, "Int"),  t := NumGet(mi, 8, "Int")
                    r := NumGet(mi, 12, "Int"), b := NumGet(mi, 16, "Int")
                    if (x <= l && y <= t && x + w >= r && y + h >= b)
                        cur[hMon] := true
                }
            }
        }
    }

    g_shellFlyout := flyout

    changed := (cur.Count != g_fsMon.Count)
    if !changed {
        for k, v in cur
            if !g_fsMon.Has(k)
                changed := true
    }
    if changed {
        g_fsMon := cur
        RaiseOverlays()    ; hides or shows the overlays accordingly
    }
}

; Called by Windows when the foreground window changes
OnForeground(hHook, event, hwnd, idObject, idChild, idThread, time) {
    UpdateFullscreen()
    RaiseOverlays()
    SetTimer RaiseOverlays, -60     ; and again shortly after, once the
                                    ; taskbar has finished reordering itself
}

CheckMouseHover() {
    global g_hovering, g_enabled, g_curAlpha, g_animActive, g_shellFlyout, FADE_UNDIM_MS, FADE_DIM_MS, TARGET_ALPHA
    static lastRaise := 0

    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    mx := NumGet(pt, 0, "Int"), my := NumGet(pt, 4, "Int")
    isOver := false
    for tb in GetTaskbars() {
        try WinGetPos &x, &y, &w, &h, "ahk_id " tb
        catch
            continue
        if (mx >= x && mx < x + w && my >= y && my < y + h) {
            isOver := true
            break
        }
    }

    ; Keep the taskbar normal while the Start menu / Search is open
    if g_shellFlyout
        isOver := true

    ; While dimmed and not hovering, keep the overlay above the taskbar
    if (!isOver && g_enabled && A_TickCount - lastRaise > 150) {
        RaiseOverlays()
        lastRaise := A_TickCount
    }

    if (isOver = g_hovering) {
        ; Self-healing: if nothing is animating but the overlay is not at the
        ; level it should be, bring it back (covers any missed state change).
        if (g_enabled && !g_animActive) {
            want := isOver ? 0 : TARGET_ALPHA
            if (g_curAlpha != want)
                AnimateTo(want, 100)
        }
        return
    }
    g_hovering := isOver
    if !g_enabled
        return

    if isOver {
        AnimateTo(0, FADE_UNDIM_MS)              ; back to normal
    } else {
        RaiseOverlays()                          ; make sure we are on top first
        lastRaise := A_TickCount
        AnimateTo(TARGET_ALPHA, FADE_DIM_MS)     ; darken again
    }
}

; ============================================================
;  TOGGLE AND QUICK LEVELS
; ============================================================
ToggleDimmer(*) {
    global g_enabled, FADE_TOGGLE_MS
    g_enabled := !g_enabled
    ApplyLevel(FADE_TOGGLE_MS)
    ShowOSD(g_enabled ? "Dimmer ON  (" CurrentPct() "%)" : "Dimmer OFF")
}

CurrentPct() {
    global TARGET_ALPHA
    return Round((255 - TARGET_ALPHA) / 255 * 100)
}

SetOpacityPct(pct, save := true) {
    global TARGET_ALPHA, CFG_FILE
    pct := Max(0, Min(100, pct))
    TARGET_ALPHA := Round((100 - pct) / 100 * 255)
    if save
        IniWrite TARGET_ALPHA, CFG_FILE, "Settings", "Alpha"
}

NudgeOpacity(delta) {
    global g_enabled
    SetOpacityPct(CurrentPct() + delta)
    if !g_enabled
        g_enabled := true
    ApplyLevel(80)
    ShowOSD("Opacity: " CurrentPct() "%")
}

CyclePreset(*) {
    global PRESETS, g_enabled
    cur := CurrentPct()
    next := PRESETS[1]
    for p in PRESETS {
        if (p > cur) {
            next := p
            break
        }
    }
    SetOpacityPct(next)
    if !g_enabled
        g_enabled := true
    ApplyLevel(150)
    ShowOSD("Opacity: " next "%")
}

ShowOSD(text) {
    ToolTip text
    SetTimer HideOSD, -900
}

HideOSD() {
    ToolTip
}

; ============================================================
;  SETTINGS POPUP  (borderless dark card, no buttons)
;  Click the tray icon to open it. Drag the slider or use the mouse wheel.
;  It closes by itself when you click anywhere else (or press Esc).
; ============================================================
; Layout in DIPs (scaled by the screen DPI)
global POP_W  := 236
global POP_H  := 98
global SL_X0  := 18
global SL_X1  := 160
global SL_Y   := 76

ShowSettings(*) {
    global g_settingsOpen, g_sGui, g_pic, g_hbm, g_lastClose, g_openTick
    global g_wasActive, g_popS, g_popW, g_popH, POP_W, POP_H

    if g_settingsOpen {          ; clicking the tray icon again closes it
        ClosePopup()
        return
    }
    if (A_TickCount - g_lastClose < 300)   ; it was just closed by clicking the tray icon
        return

    g_popS := A_ScreenDPI / 96
    g_popW := Round(POP_W * g_popS)
    g_popH := Round(POP_H * g_popS)

    g_hbm := MakePopupBitmap(CurrentPct())

    sGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale", "OLED Taskbar Dimmer")
    sGui.MarginX := 0
    sGui.MarginY := 0
    sGui.BackColor := "2B2B2B"
    sGui.OnEvent("Escape", (*) => ClosePopup())
    g_pic := sGui.Add("Picture", "x0 y0 w" g_popW " h" g_popH " +0x100", "HBITMAP:" g_hbm)  ; SS_NOTIFY

    ; Position: above the taskbar, centered on the cursor (the tray icon)
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    cx := NumGet(pt, 0, "Int"), cy := NumGet(pt, 4, "Int")
    l := 0, t := 0, r := A_ScreenWidth, b := A_ScreenHeight
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (cx >= ml && cx < mr && cy >= mt && cy < mb) {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            break
        }
    }
    x := Min(Max(cx - g_popW // 2, l + Round(8 * g_popS)), r - g_popW - Round(8 * g_popS))
    y := b - g_popH - Round(12 * g_popS)

    g_sGui := sGui
    g_settingsOpen := true
    g_wasActive := false
    g_openTick := A_TickCount

    sGui.Show("x" x " y" y " w" g_popW " h" g_popH)
    ApplyPopupStyle(sGui.Hwnd)
    try WinActivate "ahk_id " sGui.Hwnd
    SetTimer PopupWatch, 100
}

; Closes the popup as soon as it loses focus (click anywhere else)
PopupWatch() {
    global g_settingsOpen, g_sGui, g_wasActive, g_openTick
    if !g_settingsOpen {
        SetTimer PopupWatch, 0
        return
    }
    if WinActive("ahk_id " g_sGui.Hwnd) {
        g_wasActive := true
    } else if g_wasActive {
        ClosePopup()
    } else if (A_TickCount - g_openTick > 600) {
        try WinActivate "ahk_id " g_sGui.Hwnd      ; focus was refused: try again
        if (A_TickCount - g_openTick > 2500)
            ClosePopup()
    }
}

ClosePopup() {
    global g_settingsOpen, g_sGui, g_hbm, g_lastClose
    SetTimer PopupWatch, 0
    if !g_settingsOpen
        return
    g_settingsOpen := false
    g_lastClose := A_TickCount
    try g_sGui.Destroy()
    if g_hbm {
        DllCall("DeleteObject", "Ptr", g_hbm)
        g_hbm := 0
    }
}

; Rounded corners, thin border and shadow (Windows 11; harmless on Windows 10)
ApplyPopupStyle(hwnd) {
    corner := 2            ; DWMWCP_ROUND
    border := 0x00404040   ; COLORREF (BGR)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 33, "Int*", &corner, "UInt", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "UInt*", &border, "UInt", 4)
    try {
        m := Buffer(16, 0)
        NumPut("Int", 1, "Int", 1, "Int", 1, "Int", 1, m)
        DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", m)
    }
}

; -- Mouse handling ------------------------------------------
PopupHitSlider(x, y) {
    global g_popS, SL_X0, SL_X1, SL_Y
    return (x >= (SL_X0 - 10) * g_popS && x <= (SL_X1 + 10) * g_popS
         && Abs(y - SL_Y * g_popS) <= 14 * g_popS)
}

PopupLButtonDown(wParam, lParam, msg, hwnd) {
    global g_settingsOpen, g_sGui, g_pic
    if (!g_settingsOpen || (hwnd != g_pic.Hwnd && hwnd != g_sGui.Hwnd))
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if !PopupHitSlider(x, y)
        return
    DragSlider()
    return 0
}

DragSlider() {
    global g_sGui, g_popS, g_enabled, SL_X0, SL_X1
    g_enabled := true
    last := -1
    pt := Buffer(8, 0)
    while GetKeyState("LButton", "P") {
        DllCall("GetCursorPos", "Ptr", pt)
        DllCall("ScreenToClient", "Ptr", g_sGui.Hwnd, "Ptr", pt)
        px := NumGet(pt, 0, "Int")
        pct := Round(Max(0, Min(100, (px - SL_X0 * g_popS) / ((SL_X1 - SL_X0) * g_popS) * 100)))
        if (pct != last) {
            last := pct
            ApplyPopupPct(pct, false)     ; live preview, not saved yet
        }
        Sleep 8
    }
    if (last >= 0)
        ApplyPopupPct(last, true)         ; save when the mouse is released
}

PopupWheel(wParam, lParam, msg, hwnd) {
    global g_settingsOpen, g_enabled
    if !g_settingsOpen
        return
    d := (wParam >> 16) & 0xFFFF
    if (d >= 0x8000)
        d -= 0x10000
    g_enabled := true
    ApplyPopupPct(Max(0, Min(100, CurrentPct() + (d > 0 ? 5 : -5))), true)
    return 0
}

ApplyPopupPct(pct, save) {
    SetOpacityPct(pct, save)
    RedrawPopup()
    ApplyLevel(0)
}

RedrawPopup() {
    global g_pic, g_hbm, g_settingsOpen
    if !g_settingsOpen
        return
    hbm := MakePopupBitmap(CurrentPct())
    old := DllCall("SendMessage", "Ptr", g_pic.Hwnd, "UInt", 0x172, "Ptr", 0, "Ptr", hbm, "Ptr")   ; STM_SETIMAGE
    if old
        DllCall("DeleteObject", "Ptr", old)
    if (g_hbm && g_hbm != old)
        DllCall("DeleteObject", "Ptr", g_hbm)
    g_hbm := hbm
    g_pic.Redraw()
}

; ============================================================
;  DRAWING (GDI+)  -  popup card and tray icon
; ============================================================
GdipStart() {
    global g_gdipToken
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    tok := 0
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &tok, "Ptr", si, "Ptr", 0)
    g_gdipToken := tok
}

; Thin yellow sun: circle + 8 rays (same look as the tray icon)
DrawSun(g, cx, cy, size, argb) {
    pen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", Max(1.2, size * 0.085), "Int", 2, "Ptr*", &pen)
    DllCall("gdiplus\GdipSetPenLineCap197819", "Ptr", pen, "Int", 2, "Int", 2, "Int", 0)
    r := size * 0.20
    DllCall("gdiplus\GdipDrawEllipse", "Ptr", g, "Ptr", pen,
        "Float", cx - r, "Float", cy - r, "Float", 2 * r, "Float", 2 * r)
    Loop 8 {
        a := (A_Index - 1) * 0.7853981634
        c := Cos(a), sn := Sin(a)
        DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pen,
            "Float", cx + c * size * 0.34, "Float", cy + sn * size * 0.34,
            "Float", cx + c * size * 0.47, "Float", cy + sn * size * 0.47)
    }
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

DrawLineRound(g, x1, y1, x2, y2, width, argb) {
    pen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 2, "Ptr*", &pen)
    DllCall("gdiplus\GdipSetPenLineCap197819", "Ptr", pen, "Int", 2, "Int", 2, "Int", 0)
    DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pen,
        "Float", x1, "Float", y1, "Float", x2, "Float", y2)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

DrawText(g, text, x, y, w, h, family, px, argb) {
    fam := 0, font := 0, fmt := 0, brush := 0
    if DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", family, "Ptr", 0, "Ptr*", &fam)
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Arial", "Ptr", 0, "Ptr*", &fam)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", 0, "Int", 2, "Ptr*", &font)
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "UShort", 0, "Ptr*", &fmt)
    DllCall("gdiplus\GdipSetStringFormatFlags", "Ptr", fmt, "Int", 0x1000)   ; no wrap
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &brush)
    rc := Buffer(16, 0)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rc)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1,
        "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
}

; Draws the whole popup card into an HBITMAP
MakePopupBitmap(pct) {
    global POP_W, POP_H, SL_X0, SL_X1, SL_Y
    s := A_ScreenDPI / 96
    W := Round(POP_W * s), H := Round(POP_H * s)

    bmp := 0, g := 0, hbm := 0, brush := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", W, "Int", H, "Int", 0,
        "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp)          ; 32bpp ARGB
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)       ; anti-alias
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)   ; anti-alias text
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0xFF2B2B2B)

    ; Header: sun + title
    DrawSun(g, 24 * s, 21 * s, 14 * s, 0xFFF2E26C)
    DrawText(g, "OLED Taskbar Dimmer", 40 * s, 12 * s, 190 * s, 20 * s, "Segoe UI Semibold", 12 * s, 0xFFFFFFFF)

    ; Label
    DrawText(g, "Taskbar Opacity", 16 * s, 45 * s, 160 * s, 20 * s, "Segoe UI", 12 * s, 0xFFC8C8C8)

    ; Slider
    x0 := SL_X0 * s, x1 := SL_X1 * s, ty := SL_Y * s
    tx := x0 + (x1 - x0) * pct / 100
    DrawLineRound(g, x0, ty, x1, ty, 3 * s, 0xFF7C7C7C)         ; empty track
    if (tx > x0)
        DrawLineRound(g, x0, ty, tx, ty, 3 * s, 0xFFFFFFFF)     ; filled track
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFFFFFFF, "Ptr*", &brush)
    r := 6.5 * s
    DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", brush,
        "Float", tx - r, "Float", ty - r, "Float", 2 * r, "Float", 2 * r)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)

    ; Percentage
    DrawText(g, pct "%", 176 * s, (SL_Y - 9) * s, 54 * s, 20 * s, "Segoe UI Semibold", 12 * s, 0xFFFFFFFF)

    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", bmp, "Ptr*", &hbm, "UInt", 0xFF2B2B2B)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    return hbm
}

; Builds a multi-size .ico (PNG frames) with the yellow sun, used for the tray
; icon and the startup shortcut.
CreateIconFile(path) {
    sizes := [16, 20, 24, 32, 48, 64]
    pngs := []
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)   ; PNG encoder

    for sz in sizes {
        bmp := 0, g := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", sz, "Int", sz, "Int", 0,
            "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0x00000000)   ; transparent
        DrawSun(g, sz / 2, sz / 2, sz, 0xFFF2E26C)
        tmp := A_Temp "\oledtd_" sz ".png"
        DllCall("gdiplus\GdipSaveImageToFile", "Ptr", bmp, "WStr", tmp, "Ptr", clsid, "Ptr", 0)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
        pngs.Push(FileRead(tmp, "RAW"))
        FileDelete tmp
    }

    n := pngs.Length
    total := 6 + 16 * n
    for p in pngs
        total += p.Size
    buf := Buffer(total, 0)
    NumPut("UShort", 0, "UShort", 1, "UShort", n, buf, 0)
    off := 6 + 16 * n
    for i, p in pngs {
        sz := sizes[i]
        NumPut("UChar", sz, "UChar", sz, "UChar", 0, "UChar", 0,
               "UShort", 1, "UShort", 32, "UInt", p.Size, "UInt", off, buf, 6 + 16 * (i - 1))
        DllCall("RtlMoveMemory", "Ptr", buf.Ptr + off, "Ptr", p.Ptr, "UPtr", p.Size)
        off += p.Size
    }
    f := FileOpen(path, "w")
    f.RawWrite(buf, total)
    f.Close()
}
