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

The walk ends at the boards on the wall (the slim LED strip with the trains, the blue planner under it).
`window.boardScreenRect()` prints where both screens sit in the last frame; `App/Boards.swift` (`WallBoards`) uses
those numbers, and `board-out.jpg` / `board-home.jpg` are that last frame (`f065.jpg` of `node render-move.js <folder> frames 66`).

# The app icon

`icon.js` draws the icon ("Night line") on a canvas: one line of the metro map on map paper, with the yellow glow of
your route, bending up to your stop, where the alarm bell rings. `node render-icon.js <folder>` (with `icon.js` copied
into `<folder>`) writes `icon-1024.png` (for `App/Assets.xcassets/AppIcon.appiconset/`) and the website sizes
(`icon-512`, `icon-192`, `icon-180` for `icons/apple-touch-icon.png`, `icon-32` for the favicon). Save them without
transparency.
