# MacFrame Tuning & Filter Options

## FFmpeg / mpv Filter Syntax

Inside mpv or IINA (Additional mpv options / Plugin):
```text
--vf=lavfi=[macframe=fps=120:preset=film:backend=mflow:quality=1.0:guard=0.65:smoothness=0.95:scene=1:dedup=1:static_lock=1:letterbox=1:governor=1]
```

## Parameters

| Option | Type | Default | Description |
|---|---|---|---|
| `fps` | double | `120.0` | Target output frame rate (`15.0` .. `240.0`). |
| `preset` | string | `film` | `film` (balanced cinema), `anime` (2s/3s dedup + crisp line guard), `sports` (wide search radius for fast action). |
| `backend` | string | `mflow` | `mflow` (Metal optical flow), `vtfrc` (Apple VideoToolbox ML), `auto`, or `blend`. |
| `quality` | float | `1.0` | Maximum quality ceiling (`0.0` .. `1.0`), mapped to tiers `Q0..Q4`. |
| `guard` | float | `0.65` | Artifact guard strength (`0.0` = raw optical flow, `1.0` = maximum halo/warp protection). |
| `smoothness` | float | `0.95` | Phase uniformity (`1.0` = linear phase, `<1.0` = subtle filmic cadence retention). |
| `scene` | bool | `1` | Scene-cut detection (prevents cross-cut interpolation ghosting). |
| `dedup` | bool | `1` | Collapse 2s/3s duplicate frames in animation for uniform 120Hz motion. |
| `static_lock` | bool | `1` | Lock stationary logos, HUDs, scoreboards, and subtitles to zero motion. |
| `letterbox` | bool | `1` | Detect top/bottom black bars and prevent vector bleeding across bar borders. |
| `governor` | bool | `1` | Dynamically step down quality tier (`Q4 -> Q3 -> Q2 -> Q1`) if GPU frame time approaches budget. |
| `osd` | bool | `0` | Render a top-left confidence indicator bar directly into output frames. |
