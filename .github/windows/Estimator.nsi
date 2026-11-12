; Estimator-Setup-<version>.exe: one file that installs a finished Windows build for the current user (no admin).
;   makensis /DBUILD=<build folder> /DVERSION=5.2.0 /DOUTDIR=<folder> ship\windows\Estimator.nsi
; The build is unpacked to a temporary folder and installed by its own Install Estimator.ps1, the same verified step
; the app's update path uses: versions\<commit> under %LOCALAPPDATA%\Programs\Estimator, version.json, and Desktop and
; Start menu shortcuts. A running Estimator keeps running and offers Update now. /S installs silently; a failed
; install exits non-zero. Uninstall (uninstall.ps1) removes only what Setup and the installer created, never through a
; link or junction, and never jobs or %LOCALAPPDATA%\Estimator (settings, library, sign-in).

!ifndef BUILD
  !error "Pass /DBUILD=<build folder>"
!endif
!ifndef VERSION
  !error "Pass /DVERSION=<version>"
!endif
!ifndef OUTDIR
  !define OUTDIR "."
!endif

!define ICON "${BUILD}\app\src\estimator\application\assets\estimator.ico"

; A tester build (/DTESTER, from ship/tester_build.sh) carries no McCormick data: packaging stops if any of its three
; data files still has some (!system halts when its comparison is false).
!ifdef TESTER
  !define DATA "${BUILD}\app\src\estimator"
  !system 'findstr /c:"MCCORMICK:" "${DATA}\costing\mccormick_descriptions.json" >nul' <> 0
  !system 'findstr /r /c:",[0-9][0-9]*," "${DATA}\costing\mccormick_abbreviations.csv" >nul' <> 0
  !system 'findstr /c:"the generated part is empty" "${DATA}\project\family_splitters.json" >nul' = 0
!endif
; Apps & Features shows the version without a build's commit: 5.2.0-beta4-965da3ba reads 5.2.0-beta4.
!define SHOWN_VERSION "${VERSION}"
!searchparse /noerrors "${VERSION}-" "" VERSION_BASE "-" VERSION_LABEL "-"
!if "${VERSION_LABEL}" != ""
  !define /redef SHOWN_VERSION "${VERSION_BASE}-${VERSION_LABEL}"
!endif
!define ROOT "$LOCALAPPDATA\Programs\Estimator"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Estimator"

Unicode true
ManifestDPIAware true
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64
Name "Takeoff Pal"
OutFile "${OUTDIR}\Estimator-Setup-${VERSION}.exe"
InstallDir "${ROOT}\setup"
ShowInstDetails nevershow
ShowUninstDetails nevershow

!include MUI2.nsh
!include LogicLib.nsh
!include x64.nsh
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Open Takeoff Pal"
!define MUI_FINISHPAGE_RUN_FUNCTION OpenEstimator
; Plain words on the two pages Setup already has; installing starts on open, so Finish is the only click.
!define MUI_PAGE_HEADER_TEXT "Installing Takeoff Pal"
!define MUI_PAGE_HEADER_SUBTEXT "This takes about a minute."
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "Takeoff Pal is installed"
!define MUI_FINISHPAGE_TEXT "It's on your Desktop and in the Start menu."
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; Setup is 32-bit: without this, $SYSDIR is the 32-bit PowerShell, which can't read 64-bit processes' paths.
Section
  ${DisableX64FSRedirection}
  SetShellVarContext current
  InitPluginsDir
  DetailPrint "Unpacking Takeoff Pal..."
  SetOutPath "$PLUGINSDIR"
  File "setup_install.ps1"
  SetOutPath "$PLUGINSDIR\build"
  File /r "${BUILD}\*"
  ; setup_install.ps1 checks the uninstaller's folder (NSIS writes it itself) by the installer's own rule, then runs
  ; the build's installer. A failure shows one plain line; its code is only under Details and in the setup log.
  DetailPrint "Installing Takeoff Pal..."
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\setup_install.ps1" -Build "$PLUGINSDIR\build" -Setup "$INSTDIR" -Reason "$PLUGINSDIR\reason.txt"'
  Pop $0
  SetOutPath "$TEMP"  ; Let go of the unpacked build so it is deleted on exit.
  ${If} $0 != 0
    StrCpy $1 "Takeoff Pal couldn't be installed. Restart the PC, then run Setup again."
    ClearErrors
    FileOpen $2 "$PLUGINSDIR\reason.txt" r
    ${IfNot} ${Errors}
      FileRead $2 $1
      FileClose $2
    ${EndIf}
    DetailPrint "Setup stopped (code $0)."
    SetErrorLevel 1
    MessageBox MB_ICONSTOP "$1" /SD IDOK
    Quit  ; Not Abort: that would still show the finish page with "Open Takeoff Pal".
  ${EndIf}
  ; A file that can't be written (a full disk, say) sets the error flag: then nothing is registered and Setup fails.
  ClearErrors
  SetOutPath "$INSTDIR"
  File "/oname=estimator.ico" "${ICON}"
  File "uninstall.ps1"
  WriteUninstaller "$INSTDIR\Uninstall Estimator.exe"
  ${If} ${Errors}
    DetailPrint "Setup stopped: the uninstaller could not be written."
    SetErrorLevel 1
    MessageBox MB_ICONSTOP "Takeoff Pal couldn't be installed. Restart the PC, then run Setup again." /SD IDOK
    Quit
  ${EndIf}
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Takeoff Pal"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${SHOWN_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Takeoff Pal"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\estimator.ico"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "${ROOT}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall Estimator.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall Estimator.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Function OpenEstimator
  SetShellVarContext current
  ExecShell "" "$SMPROGRAMS\Takeoff Pal.lnk"
FunctionEnd

; Uninstall removes every installed version, so it waits until nothing from them is running.
Function un.onInit
  ${DisableX64FSRedirection}
  System::Call 'kernel32::SetEnvironmentVariable(t "ESTIMATOR_VERSIONS", t "${ROOT}\versions\")'
  running:
    nsExec::Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "if (Get-Process | Where-Object { $$_.Path -and $$_.Path.StartsWith($$env:ESTIMATOR_VERSIONS, [StringComparison]::OrdinalIgnoreCase) }) { exit 3 }"'
    Pop $0
    ${If} $0 == 3
      MessageBox MB_OKCANCEL|MB_ICONINFORMATION "Close Takeoff Pal first, then click OK." /SD IDCANCEL IDOK running
      Abort
    ${EndIf}
FunctionEnd

; The Apps & Features entry goes only once removal has succeeded, so a failed one can be run again.
Section "Uninstall"
  remove:
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1" -Root "${ROOT}"'
    Pop $0
    ${If} $0 == 4
      MessageBox MB_RETRYCANCEL|MB_ICONINFORMATION "Some of Takeoff Pal's files are in use. Close the program using them, then click Retry." /SD IDCANCEL IDRETRY remove
      SetErrorLevel 4
      Quit
    ${ElseIf} $0 != 0
      MessageBox MB_ICONSTOP "Takeoff Pal couldn't remove all of its files. Restart the PC, then uninstall it again." /SD IDOK
      SetErrorLevel 5
      Quit
    ${EndIf}
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
