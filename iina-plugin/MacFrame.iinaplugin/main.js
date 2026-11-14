// SPDX-License-Identifier: GPL-3.0-or-later
// MacFrame IINA Plugin: Controls the native zero-copy lavfi=[macframe=...] filter.

const { core, console, event, mpv, menu, preferences, overlay } = iina;

const FILTER_LABEL = "macframe";

let state = {
  enabled: preferences.get("enabled") !== false,
  fpsMode: preferences.get("fps_mode") || "display",
  customFps: Number(preferences.get("custom_fps") || 120),
  preset: preferences.get("preset") || "film",
  backend: preferences.get("backend") || "mflow",
  quality: Number(preferences.get("quality") ?? 1.0),
  guard: Number(preferences.get("guard") ?? 0.65),
  smoothness: Number(preferences.get("smoothness") ?? 0.95),
  scene: Number(preferences.get("scene") ?? 1),
  dedup: Number(preferences.get("dedup") ?? 1),
  staticLock: Number(preferences.get("static_lock") ?? 1),
  letterbox: Number(preferences.get("letterbox") ?? 1),
  governor: Number(preferences.get("governor") ?? 1),
  debugOsd: Number(preferences.get("debug_osd") ?? 0),
  hudVisible: false,
  hudTimer: null,
};

function savePrefs() {
  preferences.set("enabled", state.enabled);
  preferences.set("fps_mode", state.fpsMode);
  preferences.set("custom_fps", state.customFps);
  preferences.set("preset", state.preset);
  preferences.set("backend", state.backend);
  preferences.set("quality", state.quality);
  preferences.set("guard", state.guard);
  preferences.set("smoothness", state.smoothness);
  preferences.set("scene", state.scene);
  preferences.set("dedup", state.dedup);
  preferences.set("static_lock", state.staticLock);
  preferences.set("letterbox", state.letterbox);
  preferences.set("governor", state.governor);
  preferences.set("debug_osd", state.debugOsd);
  preferences.sync();
}

function computeTargetFps() {
  const srcFps = Number(mpv.getNumber("container-fps") || 24);
  const dispFps = Number(mpv.getNumber("display-fps") || 120);

  if (state.fpsMode === "double") {
    return Math.min(Math.round(srcFps * 2 * 100) / 100, 240);
  }
  if (state.fpsMode === "fixed_60") {
    return 60;
  }
  if (state.fpsMode === "fixed_120") {
    return 120;
  }
  if (state.fpsMode === "custom") {
    return Math.max(30, Math.min(240, state.customFps));
  }
  // Default "display": match ProMotion / monitor refresh rate (fallback to 120Hz if display-fps reports 0)
  return dispFps >= 48 ? Math.round(dispFps) : 120;
}

function buildFilterGraph(targetFps) {
  const dedupVal = state.preset === "anime" ? 1 : state.dedup;
  const guardVal =
    state.preset === "anime"
      ? Math.max(state.guard, 0.8)
      : state.preset === "sports"
      ? Math.max(state.guard, 0.65)
      : state.guard;
  const smoothVal = state.preset === "film" ? Math.min(state.smoothness, 0.92) : 1.0;

  const opts = [
    `fps=${targetFps}`,
    `preset=${state.preset}`,
    `backend=${state.backend}`,
    `quality=${state.quality.toFixed(2)}`,
    `guard=${guardVal.toFixed(2)}`,
    `smoothness=${smoothVal.toFixed(2)}`,
    `scene=${state.scene ? 1 : 0}`,
    `dedup=${dedupVal ? 1 : 0}`,
    `static_lock=${state.staticLock ? 1 : 0}`,
    `letterbox=${state.letterbox ? 1 : 0}`,
    `governor=${state.governor ? 1 : 0}`,
    `osd=${state.debugOsd ? 1 : 0}`,
  ].join(":");

  return `lavfi=[macframe=${opts}]`;
}

function removeFilter() {
  try {
    const vfList = mpv.getNative("vf") || [];
    const filtered = vfList.filter((item) => item && item.label !== FILTER_LABEL);
    if (filtered.length !== vfList.length) {
      mpv.setNative("vf", filtered);
    }
  } catch (e) {
    try {
      mpv.command("vf", ["remove", `@${FILTER_LABEL}`]);
    } catch (_) {}
  }
}

function applyFilter(showNotification = true) {
  removeFilter();

  if (!state.enabled) {
    if (showNotification) {
      core.osd("MacFrame: OFF");
    }
    updateHud();
    return;
  }

  const srcFps = Number(mpv.getNumber("container-fps") || 24);
  const targetFps = computeTargetFps();

  if (srcFps > 0 && srcFps >= targetFps * 0.94) {
    if (showNotification) {
      core.osd(`MacFrame: Bypassed (Source ${srcFps.toFixed(1)}fps >= Target ${targetFps}fps)`);
    }
    updateHud();
    return;
  }

  // Ensure smooth frame pacing in mpv
  try {
    const hwdec = mpv.getString("hwdec");
    if (!hwdec || hwdec === "no") {
      mpv.set("hwdec", "videotoolbox");
    }
  } catch (_) {}

  const graph = buildFilterGraph(targetFps);
  try {
    mpv.command("vf", ["add", `@${FILTER_LABEL}:${graph}`]);
    if (showNotification) {
      const bName = state.backend === "vtfrc" ? "Apple VT-FRC" : "MF-Flow Metal";
      core.osd(
        `MacFrame ON: ${srcFps ? srcFps.toFixed(0) : "24"}→${targetFps}fps [${state.preset.toUpperCase()} | ${bName}]`
      );
    }
  } catch (err) {
    console.error("Failed to attach macframe filter:", err);
    core.osd("MacFrame Error: macframe filter not found in IINA libavfilter. Run MacFrame Installer.");
  }
  updateHud();
}

function updateHud() {
  if (!state.hudVisible) {
    overlay.hide();
    return;
  }
  const srcFps = Number(mpv.getNumber("container-fps") || 0).toFixed(2);
  const vfFps = Number(mpv.getNumber("estimated-vf-fps") || 0).toFixed(1);
  const dispFps = Number(mpv.getNumber("display-fps") || 120).toFixed(0);
  const drops = Number(mpv.getNumber("frame-drop-count") || 0);
  const hwdec = mpv.getString("hwdec-current") || "none";

  overlay.simpleMode();
  overlay.setStyle(`
    body {
      margin: 0;
      padding: 0;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", monospace;
    }
    .mf-hud {
      position: fixed;
      top: 18px;
      left: 18px;
      background: rgba(16, 18, 24, 0.82);
      border: 1px solid rgba(120, 200, 255, 0.35);
      border-radius: 10px;
      padding: 10px 14px;
      color: #eef4ff;
      font-size: 12px;
      line-height: 1.55;
      backdrop-filter: blur(8px);
    }
    .mf-title {
      font-weight: 700;
      color: #5ce1e6;
      margin-bottom: 4px;
    }
    .mf-badge {
      display: inline-block;
      padding: 1px 6px;
      border-radius: 4px;
      background: rgba(92, 225, 230, 0.2);
      color: #7ef9ff;
      font-weight: 600;
    }
  `);
  overlay.setContent(`
    <div class="mf-hud">
      <div class="mf-title">MacFrame <span class="mf-badge">${state.enabled ? "ACTIVE" : "OFF"}</span></div>
      <div>Engine: <b>${state.backend.toUpperCase()}</b> | Preset: <b>${state.preset.toUpperCase()}</b></div>
      <div>FPS: <b>${srcFps}</b> → <b>${vfFps}</b> (Display ${dispFps}Hz)</div>
      <div>Pipeline: hwdec=<b>${hwdec}</b> | Drops: <b>${drops}</b></div>
      <div>Guards: Scene=${state.scene ? "ON" : "OFF"} | Dedup=${state.dedup ? "ON" : "OFF"} | HUDLock=${state.staticLock ? "ON" : "OFF"}</div>
    </div>
  `);
  overlay.show();
}

function rebuildMenu() {
  menu.removeAllItems();

  menu.addItem(
    menu.item(
      state.enabled ? "Disable MacFrame Interpolation" : "Enable MacFrame Interpolation",
      () => {
        state.enabled = !state.enabled;
        savePrefs();
        rebuildMenu();
        applyFilter(true);
      },
      { keyBinding: "Meta+Shift+m" }
    )
  );

  menu.addItem(menu.separator());

  const presets = [
    { id: "film", label: "Preset: Film / Cinema (24p Smooth)", key: "Meta+Shift+1" },
    { id: "anime", label: "Preset: Anime (2s/3s Dedup + Line Guard)", key: "Meta+Shift+2" },
    { id: "sports", label: "Preset: Sports / 120Hz High-Speed", key: "Meta+Shift+3" },
  ];
  for (const p of presets) {
    menu.addItem(
      menu.item(
        p.label,
        () => {
          state.preset = p.id;
          state.enabled = true;
          savePrefs();
          rebuildMenu();
          applyFilter(true);
        },
        { keyBinding: p.key, selected: state.preset === p.id }
      )
    );
  }

  menu.addItem(menu.separator());

  const backends = [
    { id: "mflow", label: "Backend: MF-Flow (Metal Optical Flow)" },
    { id: "vtfrc", label: "Backend: Apple VT-FRC (VideoToolbox ML)" },
    { id: "auto", label: "Backend: Auto Select" },
  ];
  for (const b of backends) {
    menu.addItem(
      menu.item(
        b.label,
        () => {
          state.backend = b.id;
          savePrefs();
          rebuildMenu();
          applyFilter(true);
        },
        { selected: state.backend === b.id }
      )
    );
  }

  menu.addItem(menu.separator());

  const fpsModes = [
    { id: "display", label: "Target FPS: Match Display (ProMotion 120Hz)" },
    { id: "fixed_120", label: "Target FPS: 120 fps" },
    { id: "fixed_60", label: "Target FPS: 60 fps" },
    { id: "double", label: "Target FPS: 2x Source Rate" },
  ];
  for (const fm of fpsModes) {
    menu.addItem(
      menu.item(
        fm.label,
        () => {
          state.fpsMode = fm.id;
          savePrefs();
          rebuildMenu();
          applyFilter(true);
        },
        { selected: state.fpsMode === fm.id }
      )
    );
  }

  menu.addItem(menu.separator());

  menu.addItem(
    menu.item(
      "Show MacFrame Live HUD",
      () => {
        state.hudVisible = !state.hudVisible;
        if (state.hudVisible) {
          updateHud();
          if (!state.hudTimer) {
            state.hudTimer = setInterval(updateHud, 500);
          }
        } else {
          if (state.hudTimer) {
            clearInterval(state.hudTimer);
            state.hudTimer = null;
          }
          overlay.hide();
        }
        rebuildMenu();
      },
      { keyBinding: "Meta+Shift+o", selected: state.hudVisible }
    )
  );
}

event.on("iina.file-loaded", () => {
  applyFilter(true);
});

rebuildMenu();
console.log("MacFrame IINA plugin initialized.");
