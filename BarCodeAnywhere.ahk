#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
DetectHiddenWindows true

; BarCode Anywhere — Ctrl+Alt+L opens the label printer at the bottom of the screen.
; Keeps a warm Edge --app window + local UI server for near-instant shows.

DIR := A_ScriptDir
UI_DIR := DIR "\ui"
SERVER_PS1 := DIR "\server\server.ps1"
HIDE_FLAG := DIR "\.hide-request"
WIN_TITLE := "BarCode Anywhere"
PORT := 27123
BASE := "http://127.0.0.1:" PORT
PROFILE := DIR "\.edge-app-profile"

; Wide dock along the bottom so the preview sits beside the editor.
WIN_W := 1200
WIN_H := 560

serverPid := 0
edgePid := 0
ready := false
suppressHideUntil := 0

; Don't name a variable HOTKEY — it collides with the built-in Hotkey() function.
hkLabel := "^!l"

try {
    Hotkey hkLabel, (*) => FromSelection()
} catch as err {
    MsgBox "Could not register hotkey:`n" err.Message, "BarCode Anywhere", "Iconx"
    ExitApp
}

A_IconTip := "BarCode Anywhere — Ctrl+Alt+L"
Tray := A_TrayMenu
Tray.Delete()
Tray.Add("Open label printer", (*) => ShowBarcode(String(A_Clipboard)))
Tray.Add("Warm up / restart UI", (*) => RestartUi())
Tray.Add()
Tray.Add("Exit", (*) => ExitApp())

OnExit ExitCleanup

#HotIf WinActive(WIN_TITLE)
Escape:: {
    global suppressHideUntil
    if (A_TickCount < suppressHideUntil)
        return
    HideDialog()
}
#HotIf

SetTimer WatchHideFlag, 50

StartUi()
return

FromSelection() {
    saved := ClipboardAll()
    A_Clipboard := ""
    Send "^c"
    if !ClipWait(0.35) {
        A_Clipboard := saved
        ; Nothing selected — open with an empty code and empty title.
        ShowBarcode("")
        return
    }
    text := String(A_Clipboard)
    A_Clipboard := saved
    ShowBarcode(text)
}

ShowBarcode(text) {
    global ready
    if !EnsureUi() {
        return
    }

    url := BASE "/api/show?mode=print"
    if !HttpPost(url, String(text)) {
        RestartUi()
        if !HttpPost(url, String(text)) {
            MsgBox "Could not reach the local barcode UI server.", "BarCode Anywhere", "Iconx"
            return
        }
    }
    ShowDialog()
}

StartUi() {
    global ready
    ready := false
    if !StartServer() {
        MsgBox "Could not start the local UI server on port " PORT ".", "BarCode Anywhere", "Iconx"
        return
    }
    if !StartEdgeWarm(true) {
        MsgBox "Microsoft Edge was not found or failed to start.", "BarCode Anywhere", "Iconx"
        return
    }
    ready := true
}

RestartUi() {
    StopEdge()
    StopServer()
    Sleep 150
    StartUi()
}

EnsureUi() {
    global ready, edgePid
    if ready && HttpGetOk(BASE "/api/health") {
        if WinExist(WIN_TITLE) || (edgePid && ProcessExist(edgePid))
            return true
    }
    RestartUi()
    return ready
}

StartServer() {
    global serverPid
    StopServer()
    try FileDelete(HIDE_FLAG)

    ps := FindPowerShell()
    if (ps = "")
        return false

    cmd := '"' ps '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' SERVER_PS1 '" -Port ' PORT ' -Root "' UI_DIR '" -HideFlag "' HIDE_FLAG '"'
    Run cmd, DIR, "Hide", &serverPid

    deadline := A_TickCount + 5000
    while (A_TickCount < deadline) {
        if HttpGetOk(BASE "/api/health")
            return true
        Sleep 50
    }
    return false
}

; hideAfter=true for background warm-up; false when about to show immediately.
StartEdgeWarm(hideAfter := true) {
    global edgePid
    StopEdge()

    edge := FindEdge()
    if (edge = "")
        return false

    args := '--app="' BASE '/" --user-data-dir="' PROFILE '" --window-size=' WIN_W ',' WIN_H ' --disable-features=TranslateUI'
    Run '"' edge '" ' args, , , &edgePid

    if !WinWait(WIN_TITLE, , 8)
        return false

    PlaceDialog()
    if hideAfter
        HideDialog()
    return true
}

ShowDialog() {
    global suppressHideUntil

    ; Wait until the hotkey is fully released so Edge does not see Ctrl+Alt+L.
    KeyWait "Ctrl"
    KeyWait "Alt"
    KeyWait "l"

    try FileDelete(HIDE_FLAG)
    ; Ignore hide requests for a moment (stale flag / accidental Esc on focus).
    suppressHideUntil := A_TickCount + 750

    if !WinExist(WIN_TITLE) {
        if !StartEdgeWarm(false)
            return
    }

    try WinShow(WIN_TITLE)
    try WinActivate(WIN_TITLE)
    PlaceDialog()
}

PlaceDialog() {
    ; Dock along the bottom of the monitor that holds the mouse (or primary).
    mon := MonitorGetPrimary()
    try {
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mx, &my)
        loop MonitorGetCount() {
            MonitorGet(A_Index, &ml, &mt, &mr, &mb)
            if (mx >= ml && mx < mr && my >= mt && my < mb) {
                mon := A_Index
                break
            }
        }
    } catch {
        /* keep primary */
    }

    MonitorGetWorkArea(mon, &left, &top, &right, &bottom)
    w := WIN_W
    h := WIN_H
    workW := right - left
    workH := bottom - top
    if (w > workW - 24)
        w := Max(720, workW - 24)
    if (h > workH - 24)
        h := Max(420, workH - 24)

    x := left + ((workW - w) // 2)
    y := bottom - h - 10
    try WinMove(x, y, w, h, WIN_TITLE)
}

HideDialog() {
    global suppressHideUntil
    if (A_TickCount < suppressHideUntil)
        return
    if WinExist(WIN_TITLE)
        try WinHide(WIN_TITLE)
}

WatchHideFlag() {
    global suppressHideUntil
    if (A_TickCount < suppressHideUntil)
        return
    if !FileExist(HIDE_FLAG)
        return
    try FileDelete(HIDE_FLAG)
    HideDialog()
}

StopServer() {
    global serverPid
    if (serverPid) {
        try ProcessClose(serverPid)
        serverPid := 0
    }
}

StopEdge() {
    global edgePid
    if WinExist(WIN_TITLE) {
        try WinClose(WIN_TITLE)
        Sleep 100
    }
    if (edgePid) {
        try ProcessClose(edgePid)
        edgePid := 0
    }
}

ExitCleanup(*) {
    SetTimer WatchHideFlag, 0
    StopEdge()
    StopServer()
    try FileDelete(HIDE_FLAG)
}

HttpPost(url, body) {
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", url, false)
        whr.SetTimeouts(200, 500, 1000, 1000)
        whr.SetRequestHeader("Content-Type", "text/plain; charset=utf-8")
        whr.Send(body)
        return (Integer(whr.Status) >= 200 && Integer(whr.Status) < 300)
    } catch {
        return false
    }
}

HttpGetOk(url) {
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", url, false)
        whr.SetTimeouts(200, 500, 1000, 1000)
        whr.Send()
        return (Integer(whr.Status) = 200)
    } catch {
        return false
    }
}

FindPowerShell() {
    candidates := [
        EnvGet("SystemRoot") "\System32\WindowsPowerShell\v1.0\powershell.exe",
        EnvGet("SystemRoot") "\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    ]
    for path in candidates {
        if FileExist(path)
            return path
    }
    return ""
}

FindEdge() {
    candidates := [
        A_ProgramFiles "\Microsoft\Edge\Application\msedge.exe",
        EnvGet("ProgramFiles(x86)") "\Microsoft\Edge\Application\msedge.exe",
        EnvGet("LOCALAPPDATA") "\Microsoft\Edge\Application\msedge.exe"
    ]
    for path in candidates {
        if FileExist(path)
            return path
    }
    return ""
}
