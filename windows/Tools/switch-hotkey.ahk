#Requires AutoHotkey v2.0
#SingleInstance Force
; ---------------------------------------------------------------------------
;  Software HDMI switcher + lan-mouse helpers - Windows side
;
;  Win+Alt+H  ->  switch the shared Acer XF243Y back to the Arch PC (DisplayPort-1).
;  This mirrors the Arch-side SUPER+ALT+H, which switches the monitor to Windows.
;  "Each side switches the monitor away from itself" - reliable because the DDC
;  write always travels over the currently-active video link.
;
;  Win+Alt+M  ->  re-run the hidden Mouse Keys script to force the cursor visible.
;  Manual recovery for when lan-mouse control works but the cursor is invisible
;  (the post-boot Mouse Keys apply lost its race with the session coming up). It
;  re-invokes the SAME hidden launcher the LanMouseMouseKeys logon task uses, so
;  there's one source of truth. Injected keystrokes count as real input, so this
;  fires even when the combo is sent over lan-mouse from Arch. Non-blocking; the
;  cursor reappears within ~2s (and the launcher keeps re-asserting for ~20s).
; ---------------------------------------------------------------------------
#!h:: {
    RunWait('"C:\Tools\switch-to-arch.bat"', "C:\Tools", "Hide")
}

#!m:: {
    Run('wscript.exe "C:\Tools\enable-mousekeys.vbs"', "C:\Tools", "Hide")
}
