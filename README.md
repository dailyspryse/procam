# ProCam

iPhone als Profi-Webcam für den Mac (Windows folgt). Das iPhone filmt, gradet auf der GPU und
streamt per WLAN; **ProCam Studio** auf dem Mac steuert alles und gibt das Bild als virtuelle
Kamera „ProCam iPhone“ an Zoom/Teams/OBS/FaceTime weiter.

## Aufbau
- `Shared/` – Protokoll (`Wire.swift`) + Einstellungsmodell (`CameraModel.swift`) + `.cube`-Parser. Von iOS **und** Mac kompiliert – das ist der Vertrag.
- `iOS/` – `CameraEngine` (AVFoundation, alle manuellen Regler), `Grade.metal` + `GradeRenderer` (YUV→RGB, Apple-Log-Umwandlung, Grading, LUT, Hintergrund-Blur), `VideoEncoder` (HEVC/H.264, latenzarm), `StreamServer` (Bonjour `_procam._tcp`, Port 47800).
- `Mac/` – `PhoneLink` (Suche/Verbindung), `VideoDecoder`, `PreviewView` + `Preview.metal` (Zebra, Peaking, Falschfarben – nur Vorschau), `Scopes`, `VirtualCamera` (CMIO-Sink + Installer), UI.
- `CameraExtension/` – CoreMediaIO-Kameraerweiterung (Quelle + Sink-Stream, Platzhalterbild ohne iPhone).

## Bauen
```
xcodegen generate
xcodebuild -scheme ProCamStudio -derivedDataPath build -allowProvisioningUpdates build
ditto "build/Build/Products/Debug/ProCam Studio.app" "/Applications/ProCam Studio.app"
xcodebuild -scheme ProCam -destination 'id=00008130-001A029A3640001C' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008130-001A029A3640001C build/Build/Products/Debug-iphoneos/ProCam.app
```

## Fallstricke
- Studio **muss in /Applications** liegen, sonst lädt macOS die Kameraerweiterung nicht. Nicht auf den Desktop bauen (iCloud zerstört Signaturen).
- Erweiterung nach „Webcam einrichten“ in Systemeinstellungen → Anmeldeobjekte & Erweiterungen → Kameraerweiterungen erlauben.
- Mach-Service-Name der Erweiterung muss mit ihrer App-Group beginnen (`8TV3YVJUTQ.de.procam.studio.camera`).
- Info.plist/Entitlements werden von XcodeGen erzeugt – alles in `project.yml` unter `properties:`.
- Braucht die Metal-Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
- Mac merkt sich die letzten Einstellungen und spielt sie beim Verbinden zurück aufs iPhone.

## Stresstest
`swiftc -O tools/stress/main.swift Shared/Wire.swift Shared/CameraModel.swift -o build/stress && build/stress 0.5`
(ProCam Studio vorher beenden, iPhone-App offen.) Fährt jedes Objektiv × Format × fps × Log/HDR und alle
Regler über ihre Grenzen; meldet Abstürze, abgelehnte Werte und Stufen ohne Bild samt Pipeline-Zählern.

## Gelernt
- AVFoundation wirft NSExceptions bei ungültigen Werten → alle Geräte-Aufrufe über `ObjCTry` (`safely`).
- Messwerte nie vom Main-Thread lesen, während die Session umkonfiguriert → nur auf `sessionQueue`.
- VideoToolbox-Encoder kann in EncodeFrame dauerhaft hängen (4K-Wechsel, war mit MaxFrameDelayCount=1) → `EncoderHost` mit Wächter.
- Apple Log gibt es auf dem 15 Pro nur als 10-Bit **4:2:2** (`x422`), nicht als `x420`.

## Stand (08.10.2026)
Getestet: Verbindung, Live-Bild 1080p30 HEVC, Objektiverkennung, Automatik-Werte, Scopes.
Stresstest grün (306 Schritte, inkl. Apple Log, Blur, alle Regler). Noch nicht getestet: virtuelle Kamera (Freigabe nötig), LUT-Datei.
Offen: USB-Verbindung, Ton (virtuelles Mikrofon), Windows-Version.
