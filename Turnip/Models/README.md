# Models

The app expects a MoveNet Thunder model file here, named exactly:

```
movenet_thunder_int8.tflite
```

This file is **not committed to the repo** (see the root `.gitignore`) — it's a ~7 MB binary
ML artifact, and downloading it automatically without a human confirming provenance/license/
variant isn't something the tooling does on your behalf. The app builds and runs without it;
the pose diagnostic screen will just show a "model not found" error until it's in place.

## Getting the file

1. Go to the Kaggle Models page for MoveNet:
   `https://www.kaggle.com/models/google/movenet/tfLite/singlepose-thunder-tflite-int8`
   (**unverified by this scaffolding** — confirm the page still hosts the int8 singlepose
   Thunder variant under Apache 2.0, per `docs/DESIGN.md`'s licensing claim, before using it.)
2. Download the int8-quantized singlepose Thunder `.tflite` file.
3. Rename/place it at `Turnip/Models/movenet_thunder_int8.tflite`.
4. Record its checksum below so future contributors can verify they have the same bytes:

```
$ shasum -a 256 Turnip/Models/movenet_thunder_int8.tflite
b72fed22707cd6fb94b5a248b9bddb9c062b9f445471b4fa263407cf6d222011
```

## Why a folder reference

`project.yml` references this directory as an XcodeGen **folder reference**, not a group. That
means Xcode picks up the file the moment you drop it in — you don't need to rerun
`xcodegen generate` just because the model file didn't exist yet when the project was first
generated.
