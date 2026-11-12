# Rendering the station videos

The station behind the app is the low-poly 3D scene from the website, rendered to short videos so the
phone only has to play them.

- `station-scene.html`: the scene, with the metro map on the wall and the camera move from the map to the platform.
- `render-move.js`: renders the camera move frames with Playwright (`node render-move.js <folder> frames 48`, where
  `<folder>/stage/station-scene.html` is this file renamed to `stage.html`), then:

```
ffmpeg -framerate 30 -i out/f%03d.jpg -c:v libx264 -pix_fmt yuv420p -crf 25 -movflags +faststart move-out.mp4
ffmpeg -i move-out.mp4 -vf reverse -c:v libx264 -pix_fmt yuv420p -crf 25 -movflags +faststart move-out-back.mp4
```

`window.posterRect()` prints where the map sits in the first frame; `App/Map.swift` (`MapSpot`) uses those numbers to
put the app's own map exactly over it.

# The app icon

`icon.js` draws the icon on a canvas: an "H" (for halte) made of metro lines on the station's tiled wall, with the pink
neon border and the smiley sticker. `node render-icon.js <folder>` (with `icon.js` copied into `<folder>` as `draw.js`)
writes `big.png` (1024, for `App/Assets.xcassets/AppIcon.appiconset/icon-1024.png`) and the website sizes
(`s512`, `s192`, `s180` for `icons/apple-touch-icon.png`, `s32` for the favicon, which leaves out the sticker).
Save them without transparency.
