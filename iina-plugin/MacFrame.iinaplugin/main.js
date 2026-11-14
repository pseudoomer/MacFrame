// SPDX-License-Identifier: GPL-3.0-or-later
// MacFrame IINA Bridge Plugin
// Synchronizes with the standalone MacFrame.app controller.
// When interpolation is disabled, strictly preserves/restores the user's original IINA settings.

const { core, console, event, mpv, menu, preferences, overlay, utils } = iina;

const FILTER_LABEL = "macframe";

let state = {
  seq: 0,
  enabled: preferences.get("enabled") !== false,
  fpsMode: preferences.get("fps_mode") || "display",
  maxFpsCap: Number(preferences.get("custom_fps") || 120),
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

// Snapshot of the user's native IINA mpv settings prior to enabling MacFrame
let userOriginalSettings = null;
let macframeApplied = false;
let appliedTargetFps = 0;
let fileLoaded = false;

function captureUserOriginalSettings() {
  if (userOriginalSettings !== null) return;
  try {
    userOriginalSettings = {
      hwdec: mpv.getString("hwdec"),
      videoSync: mpv.getString("video-sync"),
      interpolation: mpv.getString("interpolation"),
    };
  } catch (_) {
    userOriginalSettings = {};
  }
}

function restoreUserOriginalSettings() {
  // Remove only the @macframe filter, leaving all user filters intact
  try {
    const vfList = mpv.getNative("vf") || [];
    const filtered = vfList.filter((item) => item && item.label !== FILTER_LABEL);
    if (filtered.length !== vfList.length) {
      mpv.setNative("vf", filtered);
    }
  } catch (_) {
    try {
      mpv.command("vf", ["remove", `@${FILTER_LABEL}`]);
    } catch (_) {}
  }

  if (userOriginalSettings) {
    try {
      if (userOriginalSettings.hwdec) mpv.set("hwdec", userOriginalSettings.hwdec);
      if (userOriginalSettings.videoSync) mpv.set("video-sync", userOriginalSettings.videoSync);
      if (userOriginalSettings.interpolation) mpv.set("interpolation", userOriginalSettings.interpolation);
    } catch (_) {}
  }
  macframeApplied = false;
  appliedTargetFps = 0;
}

function computeTargetFps() {
  const srcFps = Number(mpv.getNumber("container-fps") || 24);
  const dispFps = Number(mpv.getNumber("display-fps") || 120);
  const cap = Math.max(24, Math.min(240, Number(state.maxFpsCap || 120)));

  if (state.fpsMode === "fixed" || state.fpsMode === "fixed_60" || state.fpsMode === "fixed_120") {
    if (state.fpsMode === "fixed_60") return 60;
    if (state.fpsMode === "fixed_120") return 120;
    return Math.round(cap);
  }
  if (state.fpsMode === "double") {
    return Math.min(Math.round(srcFps * 2 * 100) / 100, cap);
  }
  const baseDisp = dispFps >= 48 ? Math.round(dispFps) : 120;
  return Math.min(baseDisp, Math.round(cap));
}

function buildFilterGraph(targetFps) {
  const opts = [
    `fps=${targetFps}`,
    `preset=${state.preset}`,
    `backend=${state.backend}`,
    `quality=${Number(state.quality).toFixed(2)}`,
    `guard=${Number(state.guard).toFixed(2)}`,
    `smoothness=${Number(state.smoothness).toFixed(2)}`,
    `scene=${state.scene ? 1 : 0}`,
    `dedup=${state.dedup ? 1 : 0}`,
    `static_lock=${state.staticLock ? 1 : 0}`,
    `letterbox=${state.letterbox ? 1 : 0}`,
    `governor=${state.governor ? 1 : 0}`,
    `osd=${state.debugOsd ? 1 : 0}`,
  ].join(":");
  return `lavfi=[macframe=${opts}]`;
}

function applyOrRestore(showNotification = false) {
  if (!fileLoaded) return;

  // When disabled, strictly restore user's original IINA configuration and do nothing else!
  if (!state.enabled) {
    if (macframeApplied) {
      restoreUserOriginalSettings();
      if (showNotification) {
        core.osd("MacFrame: OFF (Restored native IINA settings)");
      }
    }
    updateHud();
    return;
  }

  const srcFps = Number(mpv.getNumber("container-fps") || 24);
  const targetFps = computeTargetFps();

  if (srcFps > 0 && srcFps >= targetFps * 0.94) {
    if (macframeApplied) {
      restoreUserOriginalSettings();
    }
    if (showNotification) {
      core.osd(`MacFrame: Bypassed (${srcFps.toFixed(1)}fps >= Cap ${targetFps}fps)`);
    }
    updateHud();
    return;
  }

  captureUserOriginalSettings();

  // If already applied and only fine-grained parameters changed (smoothness, guard, quality, etc.),
  // libmacframe's shared-memory IPC updates them in real time without rebuilding the filter graph!
  if (macframeApplied && Math.abs(appliedTargetFps - targetFps) < 0.5) {
    updateHud();
    return;
  }

  restoreUserOriginalSettings();

  const graph = buildFilterGraph(targetFps);
  try {
    mpv.command("vf", ["add", `@${FILTER_LABEL}:${graph}`]);
    macframeApplied = true;
    appliedTargetFps = targetFps;
    if (showNotification) {
      const bName = state.backend === "vtfrc" ? "Apple VT-FRC" : "MF-Flow Metal";
      core.osd(
        `MacFrame ON: ${srcFps ? srcFps.toFixed(0) : "24"}→${targetFps}fps [${state.preset.toUpperCase()} | ${bName}]`
      );
    }
  } catch (err) {
    console.error("Failed to attach macframe filter:", err);
  }
  updateHud();
}

function pollExternalAppConfig() {
  try {
    if (utils && typeof utils.fileExists === "function" && utils.fileExists("live_config.json")) {
      const raw = utils.readFile("live_config.json");
      if (!raw) return;
      const cfg = JSON.parse(raw);
      if (cfg && cfg.seq && cfg.seq !== state.seq) {
        const prevEnabled = state.enabled;
        const prevCap = state.maxFpsCap;
        const prevMode = state.fpsMode;

        state.seq = cfg.seq;
        state.enabled = Boolean(cfg.enabled);
        state.fpsMode = cfg.fps_mode || "display";
        state.maxFpsCap = Number(cfg.max_fps_cap || 120);
        state.preset = cfg.preset || "film";
        state.backend = cfg.backend || "mflow";
        state.quality = Number(cfg.quality ?? 1.0);
        state.guard = Number(cfg.guard ?? 0.65);
        state.smoothness = Number(cfg.smoothness ?? 0.95);
        state.scene = Number(cfg.scene ?? 1);
        state.dedup = Number(cfg.dedup ?? 1);
        state.staticLock = Number(cfg.static_lock ?? 1);
        state.letterbox = Number(cfg.letterbox ?? 1);
        state.governor = Number(cfg.governor ?? 1);
        state.debugOsd = Number(cfg.debug_osd ?? 0);

        rebuildMenu();
        const notify = prevEnabled !== state.enabled || prevCap !== state.maxFpsCap || prevMode !== state.fpsMode;
        applyOrRestore(notify);
      }
    }
  } catch (_) {}
}

function updateHud() {
  if (!state.hudVisible) {
    overlay.hide();
    return;
  }
  const srcFps = Number(mpv.getNumber("container-fps") || 0).toFixed(2);
  const vfFps = Number(mpv.getNumber("estimated-vf-fps") || 0).toFixed(1);
  const drops = Number(mpv.getNumber("frame-drop-count") || 0);
  const hwdec = mpv.getString("hwdec-current") || "none";

  overlay.simpleMode();
  overlay.setStyle(`
    body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, monospace; }
    .mf-hud {
      position: fixed; top: 18px; left: 18px;
      background: rgba(16, 18, 24, 0.82);
      border: 1px solid rgba(120, 200, 255, 0.35);
      border-radius: 10px; padding: 10px 14px;
      color: #eef4ff; font-size: 12px; line-height: 1.55;
      backdrop-filter: blur(8px);
    }
    .mf-title { font-weight: 700; color: #5ce1e6; margin-bottom: 4px; }
    .mf-badge {
      display: inline-block; padding: 1px 6px; border-radius: 4px;
      background: rgba(92, 225, 230, 0.2); color: #7ef9ff; font-weight: 600;
    }
  `);
  overlay.setContent(`
    <div class="mf-hud">
      <div class="mf-title">MacFrame <span class="mf-badge">${state.enabled ? "ACTIVE" : "NATIVE IINA"}</span></div>
      <div>Engine: <b>${state.backend.toUpperCase()}</b> | Preset: <b>${state.preset.toUpperCase()}</b></div>
      <div>FPS: <b>${srcFps}</b> → <b>${vfFps}</b> (Cap ${state.maxFpsCap}fps)</div>
      <div>Smoothness: <b>${Math.round(state.smoothness * 100)}%</b> | Repair Guard: <b>${Math.round(state.guard * 100)}%</b></div>
      <div>Pipeline: hwdec=<b>${hwdec}</b> | Drops: <b>${drops}</b></div>
    </div>
  `);
  overlay.show();
}

function rebuildMenu() {
  menu.removeAllItems();

  menu.addItem(
    menu.item("Open MacFrame Control Center App...", () => {
      try {
        utils.exec("/usr/bin/open", ["-a", "/Applications/MacFrame.app"]);
      } catch (_) {}
    })
  );

  menu.addItem(menu.separator());

  menu.addItem(
    menu.item(
      state.enabled ? "Disable MacFrame (Use Native IINA Settings)" : "Enable MacFrame Interpolation",
      () => {
        state.enabled = !state.enabled;
        appliedTargetFps = 0;
        rebuildMenu();
        applyOrRestore(true);
      },
      { keyBinding: "Meta+Shift+m" }
    )
  );

  menu.addItem(
    menu.item(
      "Show MacFrame Live HUD",
      () => {
        state.hudVisible = !state.hudVisible;
        if (state.hudVisible) {
          updateHud();
          if (!state.hudTimer) state.hudTimer = setInterval(updateHud, 500);
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
  fileLoaded = true;
  userOriginalSettings = null;
  macframeApplied = false;
  appliedTargetFps = 0;
  pollExternalAppConfig();
  applyOrRestore(state.enabled);
});

setInterval(pollExternalAppConfig, 400);
rebuildMenu();
