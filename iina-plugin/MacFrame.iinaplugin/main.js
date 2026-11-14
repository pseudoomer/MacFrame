// SPDX-License-Identifier: GPL-3.0-or-later
// MacFrame IINA Companion Plugin (HUD & Menu Shortcut)
// Note: Filter attachment and native-setting restoration are handled directly
// in-process by libmacframe's C++ autohook (mf_autohook.mm), so MacFrame works
// even without IINA's plugin system. This plugin provides the optional HUD (Cmd+Shift+O).

const { mpv, menu, overlay, utils } = iina;

let hudVisible = false;
let hudTimer = null;

function updateHud() {
  if (!hudVisible) {
    overlay.hide();
    return;
  }
  const srcFps = Number(mpv.getNumber("container-fps") || 0).toFixed(2);
  const vfFps = Number(mpv.getNumber("estimated-vf-fps") || 0).toFixed(1);
  const drops = Number(mpv.getNumber("frame-drop-count") || 0);
  const hwdec = mpv.getString("hwdec-current") || "none";
  const vfStr = mpv.getString("vf") || "";
  const isActive = vfStr.indexOf("macframe") !== -1;

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
      <div class="mf-title">MacFrame <span class="mf-badge">${isActive ? "ACTIVE" : "NATIVE IINA"}</span></div>
      <div>FPS: <b>${srcFps}</b> → <b>${vfFps}</b></div>
      <div>Pipeline: hwdec=<b>${hwdec}</b> | Drops: <b>${drops}</b></div>
    </div>
  `);
  overlay.show();
}

function rebuildMenu() {
  menu.removeAllItems();

  menu.addItem(
    menu.item("Open MacFrame Control Center...", () => {
      try {
        utils.exec("/usr/bin/open", ["-a", "MacFrame"]);
      } catch (_) {}
    })
  );

  menu.addItem(
    menu.item(
      "Show MacFrame Live HUD",
      () => {
        hudVisible = !hudVisible;
        if (hudVisible) {
          updateHud();
          if (!hudTimer) hudTimer = setInterval(updateHud, 500);
        } else {
          if (hudTimer) {
            clearInterval(hudTimer);
            hudTimer = null;
          }
          overlay.hide();
        }
        rebuildMenu();
      },
      { keyBinding: "Meta+Shift+o", selected: hudVisible }
    )
  );
}

rebuildMenu();
