// SPDX-License-Identifier: GPL-3.0-or-later
// MacFrame — Standalone macOS App & Menu Bar Dashboard for IINA Frame Interpolation

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Multi-Language Localization

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en     = "en"
    case ja     = "ja"
    case ko     = "ko"
    case fr     = "fr"
    case de     = "de"
    case es     = "es"

    var id: String { rawValue }

    var resolved: AppLanguage {
        if self != .system { return self }
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if pref.hasPrefix("zh-hant") || pref.hasPrefix("zh-tw") || pref.hasPrefix("zh-hk") || pref.hasPrefix("zh-mo") {
            return .zhHant
        }
        if pref.hasPrefix("zh") { return .zhHans }
        if pref.hasPrefix("ja") { return .ja }
        if pref.hasPrefix("ko") { return .ko }
        if pref.hasPrefix("fr") { return .fr }
        if pref.hasPrefix("de") { return .de }
        if pref.hasPrefix("es") { return .es }
        return .en
    }

    func displayName(in current: AppLanguage) -> String {
        switch self {
        case .system:
            switch current.resolved {
            case .zhHans: return "跟随系统"
            case .zhHant: return "跟隨系統"
            case .ja:     return "システム設定"
            case .ko:     return "시스템 기본값"
            case .fr:     return "Système"
            case .de:     return "Systemstandard"
            case .es:     return "Sistema"
            default:      return "System Default"
            }
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en:     return "English"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        case .fr:     return "Français"
        case .de:     return "Deutsch"
        case .es:     return "Español"
        }
    }
}

struct L10n {
    let lang: AppLanguage

    // Status & Header
    var stateActive: String {
        switch lang {
        case .zhHans: return "处理中"
        case .zhHant: return "處理中"
        case .ja:     return "処理中"
        case .ko:     return "처리 중"
        case .fr:     return "Actif"
        case .de:     return "Aktiv"
        case .es:     return "Activo"
        default:      return "Active"
        }
    }
    var stateStandby: String {
        switch lang {
        case .zhHans: return "待机"
        case .zhHant: return "待機"
        case .ja:     return "待機中"
        case .ko:     return "대기 중"
        case .fr:     return "Veille"
        case .de:     return "Bereit"
        case .es:     return "En espera"
        default:      return "Standby"
        }
    }
    var stateOff: String {
        switch lang {
        case .zhHans: return "已关闭"
        case .zhHant: return "已關閉"
        case .ja:     return "オフ"
        case .ko:     return "꺼짐"
        case .fr:     return "Désactivé"
        case .de:     return "Aus"
        case .es:     return "Apagado"
        default:      return "Off"
        }
    }
    var masterToggleTip: String {
        switch lang {
        case .zhHans: return "开启或关闭实时补帧；关闭时 IINA 完全按原生设置运行"
        case .zhHant: return "開啟或關閉即時補幀；關閉時 IINA 完全按原生設定運行"
        case .ja:     return "フレーム補間のオン/オフを切り替えます。オフ時はIINA本来の設定で動作します"
        case .ko:     return "실시간 프레임 보간을 켜거나 끕니다. 끄면 IINA가 원래 설정대로 작동합니다"
        case .fr:     return "Activer/désactiver l'interpolation. Désactivé, IINA utilise ses réglages natifs"
        case .de:     return "Zwischenbildberechnung ein-/ausschalten. Wenn aus, läuft IINA nativ"
        case .es:     return "Activar o desactivar interpolación. Al apagar, IINA usa su configuración nativa"
        default:      return "Toggle real-time frame interpolation. When off, IINA runs with its native settings"
        }
    }

    // Telemetry Cards
    var metricFps: String {
        switch lang {
        case .zhHans: return "帧率"
        case .zhHant: return "幀率"
        case .ja:     return "フレームレート"
        case .ko:     return "프레임레이트"
        case .fr:     return "Cadence"
        case .de:     return "Bildrate"
        case .es:     return "Fotogramas"
        default:      return "Frame Rate"
        }
    }
    var metricGpu: String {
        switch lang {
        case .zhHans: return "GPU 耗时"
        case .zhHant: return "GPU 耗時"
        case .ja:     return "GPU 時間"
        case .ko:     return "GPU 시간"
        case .fr:     return "Temps GPU"
        case .de:     return "GPU-Zeit"
        case .es:     return "Tiempo GPU"
        default:      return "GPU Time"
        }
    }
    var metricQuality: String {
        switch lang {
        case .zhHans: return "画质与置信"
        case .zhHant: return "畫質與置信"
        case .ja:     return "品質・信頼度"
        case .ko:     return "품질·신뢰도"
        case .fr:     return "Qualité"
        case .de:     return "Qualität"
        case .es:     return "Calidad"
        default:      return "Quality"
        }
    }
    var metricGuards: String {
        switch lang {
        case .zhHans: return "切镜 / 去重"
        case .zhHant: return "切鏡 / 去重"
        case .ja:     return "カット / 重複"
        case .ko:     return "장면전환 / 중복"
        case .fr:     return "Coupes / Dédup"
        case .de:     return "Schnitte / Dedup"
        case .es:     return "Cortes / Dedup"
        default:      return "Cuts / Dedup"
        }
    }
    var idleSub: String {
        switch lang {
        case .zhHans: return "等待播放"
        case .zhHant: return "等待播放"
        case .ja:     return "再生待機中"
        case .ko:     return "재생 대기"
        case .fr:     return "En attente"
        case .de:     return "Warte auf Video"
        case .es:     return "Sin vídeo"
        default:      return "Idle"
        }
    }

    // Frame Rate Section
    var secFps: String {
        switch lang {
        case .zhHans: return "目标帧率"
        case .zhHant: return "目標幀率"
        case .ja:     return "目標フレームレート"
        case .ko:     return "목표 프레임레이트"
        case .fr:     return "Cadence cible"
        case .de:     return "Zielbildrate"
        case .es:     return "Tasa objetivo"
        default:      return "Target FPS"
        }
    }
    var secFpsTip: String {
        switch lang {
        case .zhHans: return "设置输出帧率模式与最高帧率上限（自动约束不超过显示器刷新率）"
        case .zhHant: return "設定輸出幀率模式與最高幀率上限（自動約束不超過顯示器更新率）"
        case .ja:     return "出力フレームレートモードと上限を設定します（ディスプレイのリフレッシュレート以下に自動制限）"
        case .ko:     return "출력 프레임 모드 및 최대 프레임 상한을 설정합니다"
        case .fr:     return "Définir le mode de cadence et la limite maximale d'images par seconde"
        case .de:     return "Zielbildratenmodus und maximale FPS-Obergrenze festlegen"
        case .es:     return "Configurar el modo de fotogramas y el límite máximo de FPS"
        default:      return "Configure target FPS strategy and maximum frame rate ceiling"
        }
    }
    var modeDisplay: String {
        switch lang {
        case .zhHans: return "跟随屏幕"
        case .zhHant: return "跟隨螢幕"
        case .ja:     return "画面同期"
        case .ko:     return "화면 동기화"
        case .fr:     return "Écran"
        case .de:     return "Bildschirm"
        case .es:     return "Pantalla"
        default:      return "Display"
        }
    }
    var modeFixed: String {
        switch lang {
        case .zhHans: return "固定上限"
        case .zhHant: return "固定上限"
        case .ja:     return "固定上限"
        case .ko:     return "고정 상한"
        case .fr:     return "Fixe"
        case .de:     return "Fest"
        case .es:     return "Fijo"
        default:      return "Fixed"
        }
    }
    var modeDouble: String {
        switch lang {
        case .zhHans: return "2x 倍帧"
        case .zhHant: return "2x 倍幀"
        case .ja:     return "2倍補間"
        case .ko:     return "2배속 보간"
        case .fr:     return "2x"
        case .de:     return "2x"
        case .es:     return "2x"
        default:      return "2x"
        }
    }
    var fpsCapLabel: String {
        switch lang {
        case .zhHans: return "上限"
        case .zhHant: return "上限"
        case .ja:     return "上限"
        case .ko:     return "상한"
        case .fr:     return "Plafond"
        case .de:     return "Limit"
        case .es:     return "Límite"
        default:      return "Cap"
        }
    }

    // Presets & Backend
    var secPreset: String {
        switch lang {
        case .zhHans: return "场景预设"
        case .zhHant: return "場景預設"
        case .ja:     return "プリセット"
        case .ko:     return "프리셋"
        case .fr:     return "Préréglages"
        case .de:     return "Profile"
        case .es:     return "Perfiles"
        default:      return "Presets"
        }
    }
    var presetFilm: String {
        switch lang {
        case .zhHans: return "电影"
        case .zhHant: return "電影"
        case .ja:     return "映画"
        case .ko:     return "영화"
        case .fr:     return "Cinéma"
        case .de:     return "Film"
        case .es:     return "Cine"
        default:      return "Film"
        }
    }
    var presetFilmTip: String {
        switch lang {
        case .zhHans: return "适合实拍电影与剧集：保留自然胶片感，均衡抑制遮挡光晕并启用黑边防护"
        case .zhHant: return "適合實拍電影與劇集：保留自然膠片感，均衡抑制遮擋光暈並啟用黑邊防護"
        case .ja:     return "実写映画・ドラマ向け：自然なフィルム感を保ち、ハロー抑制と黒帯保護を有効化"
        case .ko:     return "영화/드라마용: 자연스러운 필름 질감 유지 및 후광 억제·레터박스 보호 활성화"
        case .fr:     return "Idéal pour films et séries : mouvement naturel, anti-halo équilibré et protection des bandes noires"
        case .de:     return "Für Filme & Serien: natürlicher Filmlook, ausgewogener Halo-Schutz und Balkenschutz"
        case .es:     return "Para cine y series: movimiento natural, supresión de halos y protección de bordes negros"
        default:      return "Tuned for movies & shows: natural cadence, balanced halo suppression, and letterbox protection"
        }
    }
    var presetAnime: String {
        switch lang {
        case .zhHans: return "动漫"
        case .zhHant: return "動漫"
        case .ja:     return "アニメ"
        case .ko:     return "애니메이션"
        case .fr:     return "Anime"
        case .de:     return "Anime"
        case .es:     return "Anime"
        default:      return "Anime"
        }
    }
    var presetAnimeTip: String {
        switch lang {
        case .zhHans: return "适合二次元动画：开启一拍二/一拍三重复帧重建，强化线稿防重影与边缘保护"
        case .zhHant: return "適合二次元動畫：開啟一拍二/一拍三重複幀重建，強化線稿防重影與邊緣保護"
        case .ja:     return "アニメ向け：2コマ/3コマ打ち重複フレーム再構築と輪郭線の二重化防止を強化"
        case .ko:     return "애니메이션용: 2프레임/3프레임 중복 재구성 및 선화 이중선 방지 강화"
        case .fr:     return "Pour l'animation : reconstruction des doublons 2s/3s et protection accrue des contours"
        case .de:     return "Für Anime: 2er/3er-Duplikatrekonstruktion und verstärkter Schutz für Linienzeichnungen"
        case .es:     return "Para anime: reconstrucción de fotogramas duplicados 2s/3s y protección de líneas"
        default:      return "Tuned for 2D animation: 2s/3s duplicate frame reconstruction and strong line-art ghost guard"
        }
    }
    var presetSports: String {
        switch lang {
        case .zhHans: return "高速"
        case .zhHant: return "高速"
        case .ja:     return "スポーツ"
        case .ko:     return "스포츠"
        case .fr:     return "Sport"
        case .de:     return "Sport"
        case .es:     return "Deportes"
        default:      return "Sports"
        }
    }
    var presetSportsTip: String {
        switch lang {
        case .zhHans: return "适合体育赛事与高帧率视频：100% 满平滑度与大位移光流搜索，同时锁定比分牌字幕"
        case .zhHant: return "適合體育賽事與高幀率影片：100% 滿平滑度與大位移光流搜尋，同時鎖定比分牌字幕"
        case .ja:     return "スポーツ・高速映像向け：100%の滑らかさと大動き探索、スコアボード固定を有効化"
        case .ko:     return "스포츠/고속 영상용: 100% 부드러움과 빠른 움직임 탐색, 스코어보드 고정"
        case .fr:     return "Pour le sport : fluidité maximale à 100%, suivi des mouvements rapides et verrouillage HUD"
        case .de:     return "Für Sport: 100 % Glättung, große Bewegungssuche und HUD-/Spielstand-Sperre"
        case .es:     return "Para deportes: 100% de fluidez, seguimiento rápido y bloqueo de marcadores"
        default:      return "Tuned for sports & action: 100% smoothness, large-displacement search, and scoreboard lock"
        }
    }
    var presetCustom: String {
        switch lang {
        case .zhHans: return "自定义"
        case .zhHant: return "自訂"
        case .ja:     return "カスタム"
        case .ko:     return "사용자 지정"
        case .fr:     return "Perso"
        case .de:     return "Eigene"
        case .es:     return "Personal"
        default:      return "Custom"
        }
    }
    var presetCustomTip: String {
        switch lang {
        case .zhHans: return "使用手动微调的平滑度、修复强度与防护开关"
        case .zhHant: return "使用手動微調的平滑度、修復強度與防護開關"
        case .ja:     return "スライダーとスイッチで手動調整したパラメータを使用します"
        case .ko:     return "수동으로 조절한 슬라이더 및 보호 설정을 사용합니다"
        case .fr:     return "Utiliser les paramètres ajustés manuellement ci-dessous"
        case .de:     return "Manuell angepasste Regler und Schutzoptionen verwenden"
        case .es:     return "Usar parámetros ajustados manualmente"
        default:      return "Use manually adjusted sliders and protection toggles"
        }
    }

    var backendLabel: String {
        switch lang {
        case .zhHans: return "算法引擎"
        case .zhHant: return "演算法引擎"
        case .ja:     return "エンジン"
        case .ko:     return "알고리즘 엔진"
        case .fr:     return "Moteur"
        case .de:     return "Engine"
        case .es:     return "Motor"
        default:      return "Engine"
        }
    }
    var backendTip: String {
        switch lang {
        case .zhHans: return "MF-Flow 为自研零拷贝 Metal 光流引擎（推荐）；VT-FRC 调用 macOS 15 神经网络光流"
        case .zhHant: return "MF-Flow 為自研零拷貝 Metal 光流引擎（推薦）；VT-FRC 呼叫 macOS 15 神經網路光流"
        case .ja:     return "MF-Flowは独自のゼロコピーMetal光学フロー（推奨）。VT-FRCはmacOS 15のMLフレーム補間を使用"
        case .ko:     return "MF-Flow는 자체 Metal 광학 흐름 엔진(권장), VT-FRC는 macOS 15 신경망 보간 사용"
        case .fr:     return "MF-Flow : flux optique Metal sans copie (recommandé). VT-FRC : ML Apple macOS 15"
        case .de:     return "MF-Flow: eigener Zero-Copy Metal Optical Flow (empfohlen). VT-FRC: macOS 15 ML"
        case .es:     return "MF-Flow: flujo óptico Metal propio (recomendado). VT-FRC: ML de macOS 15"
        default:      return "MF-Flow: custom zero-copy Metal optical flow (recommended). VT-FRC: macOS 15 ML optical flow"
        }
    }
    var backendAuto: String {
        switch lang {
        case .zhHans: return "自动"
        case .zhHant: return "自動"
        case .ja:     return "自動"
        case .ko:     return "자동"
        case .fr:     return "Auto"
        case .de:     return "Auto"
        case .es:     return "Auto"
        default:      return "Auto"
        }
    }

    // Sliders Section
    var secTuning: String {
        switch lang {
        case .zhHans: return "参数微调"
        case .zhHant: return "參數微調"
        case .ja:     return "詳細調整"
        case .ko:     return "세부 조정"
        case .fr:     return "Réglages"
        case .de:     return "Feinabstimmung"
        case .es:     return "Ajustes"
        default:      return "Tuning"
        }
    }
    var sliderSmoothness: String {
        switch lang {
        case .zhHans: return "平滑度"
        case .zhHant: return "平滑度"
        case .ja:     return "滑らかさ"
        case .ko:     return "부드러움"
        case .fr:     return "Fluidité"
        case .de:     return "Glättung"
        case .es:     return "Fluidez"
        default:      return "Smoothness"
        }
    }
    var sliderSmoothnessTip: String {
        switch lang {
        case .zhHans: return "100% 为完全均匀插值；调低可保留部分 24p 电影感，减轻肥皂剧效应"
        case .zhHant: return "100% 為完全均勻插值；調低可保留部分 24p 電影感，減輕肥皂劇效應"
        case .ja:     return "100%で完全な均等補間。下げると24pの映画らしい質感を残しソープオペラ効果を軽減します"
        case .ko:     return "100%는 완전 균일 보간이며, 낮추면 24p 영화 질감을 일부 유지합니다"
        case .fr:     return "100 % pour une interpolation uniforme ; réduire pour préserver le grain cinéma 24p"
        case .de:     return "100 % für gleichmäßige Interpolation; senken, um den 24p-Kino-Look zu erhalten"
        case .es:     return "100% para interpolación uniforme; reducir para mantener cadencia cinematográfica"
        default:      return "100% for full uniform interpolation; lower to preserve 24p film cadence and reduce soap-opera effect"
        }
    }
    var sliderRepair: String {
        switch lang {
        case .zhHans: return "伪影修复"
        case .zhHant: return "偽影修復"
        case .ja:     return "破綻抑制"
        case .ko:     return "아티팩트 억제"
        case .fr:     return "Anti-artefacts"
        case .de:     return "Artefaktschutz"
        case .es:     return "Antihalos"
        default:      return "Artifact Guard"
        }
    }
    var sliderRepairTip: String {
        switch lang {
        case .zhHans: return "控制遮挡光晕抑制、果冻扭曲回退以及动漫线稿防双线的保护强度"
        case .zhHant: return "控制遮擋光暈抑制、果凍扭曲回退以及動漫線稿防雙線的保護強度"
        case .ja:     return "オクルージョン境界のハロー抑制、ゼリー歪み防止、アニメ線画の二重線保護の強さ"
        case .ko:     return "가림 영역 후광 억제, 젤리 왜곡 방지 및 애니메이션 선화 보호 강도"
        case .fr:     return "Intensité de la suppression des halos d'occlusion, distorsions et doublons de traits"
        case .de:     return "Stärke der Halo-Unterdrückung an Verdeckungen, Wackel-Schutz und Linienschutz"
        case .es:     return "Intensidad de supresión de halos de oclusión, distorsión gelatinosa y bordes dobles"
        default:      return "Strength of occlusion halo suppression, jello-warp fallback, and anime line-art protection"
        }
    }
    var sliderQuality: String {
        switch lang {
        case .zhHans: return "搜索精度"
        case .zhHant: return "搜尋精度"
        case .ja:     return "探索精度"
        case .ko:     return "탐색 정밀도"
        case .fr:     return "Précision"
        case .de:     return "Suchpräzision"
        case .es:     return "Precisión"
        default:      return "Search Quality"
        }
    }
    var sliderQualityTip: String {
        switch lang {
        case .zhHans: return "Q4 启用完整 6 层金字塔与 4 次亚像素细化；降低可减少笔记本发热与功耗"
        case .zhHant: return "Q4 啟用完整 6 層金字塔與 4 次亞像素細化；降低可減少筆電發熱與功耗"
        case .ja:     return "Q4は6層ピラミッド＋4回サブピクセル精緻化を使用。下げるとバッテリー消費を抑えます"
        case .ko:     return "Q4는 6단계 피라미드 및 4회 서브픽셀 정밀화를 수행하며, 낮추면 전력 소모가 줄어듭니다"
        case .fr:     return "Q4 active la pyramide 6 niveaux complète ; réduire pour économiser la batterie"
        case .de:     return "Q4 nutzt 6 Pyramidenebenen + 4× Subpixel-Verfeinerung; senken spart Akku"
        case .es:     return "Q4 activa pirámide de 6 niveles; reducir disminuye el consumo de batería"
        default:      return "Q4 enables full 6-level pyramid + 4 sub-pixel refinements; lower to save battery"
        }
    }

    // Guards Section
    var secGuards: String {
        switch lang {
        case .zhHans: return "专项防护"
        case .zhHant: return "專項防護"
        case .ja:     return "保護機能"
        case .ko:     return "보호 기능"
        case .fr:     return "Protections"
        case .de:     return "Schutzfunktionen"
        case .es:     return "Protecciones"
        default:      return "Guards"
        }
    }
    var guardScene: String {
        switch lang {
        case .zhHans: return "切镜防鬼影"
        case .zhHant: return "切鏡防鬼影"
        case .ja:     return "シーン切替保護"
        case .ko:     return "장면 전환 보호"
        case .fr:     return "Anti-fantôme coupe"
        case .de:     return "Szenenschnitt"
        case .es:     return "Cambio de escena"
        default:      return "Scene Cut"
        }
    }
    var guardSceneTip: String {
        switch lang {
        case .zhHans: return "自动识别镜头切换与闪白，在切镜边界禁用跨帧插值，彻底消除残影"
        case .zhHant: return "自動識別鏡頭切換與閃白，在切鏡邊界禁用跨幀插值，徹底消除殘影"
        case .ja:     return "カット切り替えやフラッシュを検出し、異なるシーン間の補間による残像を防止します"
        case .ko:     return "장면 전환을 자동 감지하여 이전 장면과 섞이는 잔상 현상을 방지합니다"
        case .fr:     return "Détecte les changements de plan pour éviter tout mélange entre deux scènes"
        case .de:     return "Erkennt Szenenwechsel automatisch und verhindert Geisterbilder zwischen Schnitten"
        case .es:     return "Detecta cambios de plano para evitar imágenes fantasma entre escenas"
        default:      return "Detects camera cuts and flashes to prevent cross-scene ghost frames"
        }
    }
    var guardDedup: String {
        switch lang {
        case .zhHans: return "一拍二/三去重"
        case .zhHant: return "一拍二/三去重"
        case .ja:     return "アニメ重複再構築"
        case .ko:     return "애니 중복 재구성"
        case .fr:     return "Dédup Anime 2s/3s"
        case .de:     return "Anime-Dedup"
        case .es:     return "Dedup Anime"
        default:      return "Anime Dedup"
        }
    }
    var guardDedupTip: String {
        switch lang {
        case .zhHans: return "识别动画中的重复帧（一拍二、一拍三），在真实运动帧之间均匀重建时间轴，消除顿挫"
        case .zhHant: return "識別動畫中的重複幀（一拍二、一拍三），在真實運動幀之間均勻重建時間軸，消除頓挫"
        case .ja:     return "アニメ特有の重複フレーム（2コマ・3コマ打ち）を検出し、実フレーム間を滑らかに再配分します"
        case .ko:     return "애니메이션의 2~3프레임 중복을 감지하여 실제 움직임 사이에 균일하게 보간합니다"
        case .fr:     return "Détecte les images dupliquées d'animation (2s/3s) et redistribue le mouvement"
        case .de:     return "Erkennt doppelte Anime-Frames (2er/3er) und verteilt die Bewegung gleichmäßig"
        case .es:     return "Detecta fotogramas duplicados en anime (2s/3s) y redistribuye el movimiento"
        default:      return "Detects repeated 2s/3s animation frames and evenly redistributes motion across unique keys"
        }
    }
    var guardHud: String {
        switch lang {
        case .zhHans: return "台标/字幕锁定"
        case .zhHant: return "台標/字幕鎖定"
        case .ja:     return "ロゴ・字幕固定"
        case .ko:     return "로고·자막 고정"
        case .fr:     return "Verrou HUD/Logo"
        case .de:     return "Logo-/HUD-Sperre"
        case .es:     return "Bloqueo HUD/Sub"
        default:      return "HUD / Sub Lock"
        }
    }
    var guardHudTip: String {
        switch lang {
        case .zhHans: return "锁定画面中静止的台标、比分牌、UI 与内嵌字幕，防止被背景运动拖影撕裂"
        case .zhHant: return "鎖定畫面中靜止的台標、比分牌、UI 與內嵌字幕，防止被背景運動拖影撕裂"
        case .ja:     return "静止しているロゴ、スコアボード、字幕が背景の動きに引っ張られて歪むのを防ぎます"
        case .ko:     return "고정된 방송 로고, 점수판, 내장 자막이 배경 움직임에 끌려 왜곡되는 것을 방지합니다"
        case .fr:     return "Verrouille les logos fixes, scores et sous-titres contre la déformation du fond"
        case .de:     return "Schützt statische Senderlogos, Spielstände und Untertitel vor Verzerrungen"
        case .es:     return "Protege logos fijos, marcadores y subtítulos contra tirones del fondo"
        default:      return "Locks static logos, scoreboards, HUD elements, and burned-in subtitles against background pull"
        }
    }
    var guardLetterbox: String {
        switch lang {
        case .zhHans: return "电影黑边防护"
        case .zhHant: return "電影黑邊防護"
        case .ja:     return "黒帯にじみ防止"
        case .ko:     return "레터박스 보호"
        case .fr:     return "Bandes noires"
        case .de:     return "Balkenschutz"
        case .es:     return "Bordes negros"
        default:      return "Letterbox"
        }
    }
    var guardLetterboxTip: String {
        switch lang {
        case .zhHans: return "自动检测宽银幕上下黑边，防止光流将黑边像素采样进画面或产生边缘弯曲"
        case .zhHant: return "自動檢測寬銀幕上下黑邊，防止光流將黑邊像素採樣進畫面或產生邊緣彎曲"
        case .ja:     return "シネスコ映像の上下黒帯を自動検出し、境界の歪みや黒にじみを防ぎます"
        case .ko:     return "상하단 검은 여백(레터박스)을 감지하여 경계면 번짐과 왜곡을 차단합니다"
        case .fr:     return "Détecte les bandes noires cinéma pour empêcher tout débordement sur les bords"
        case .de:     return "Erkennt Kinobalken automatisch und verhindert Ausbluten an den Bildrändern"
        case .es:     return "Detecta bandas negras de cine para evitar sangrado en los bordes"
        default:      return "Auto-detects top/bottom cinema bars and clamps motion vectors from bleeding across borders"
        }
    }
    var guardGovernor: String {
        switch lang {
        case .zhHans: return "智能温控防掉帧"
        case .zhHant: return "智慧溫控防掉幀"
        case .ja:     return "自動負荷制御"
        case .ko:     return "자동 부하 조절"
        case .fr:     return "Régulateur GPU"
        case .de:     return "Auto-Governor"
        case .es:     return "Control térmico"
        default:      return "Auto Governor"
        }
    }
    var guardGovernorTip: String {
        switch lang {
        case .zhHans: return "当 GPU 帧耗时接近刷新周期预算时，自动平滑调整光流档位（Q4..Q0），确保零掉帧与音画同步"
        case .zhHant: return "當 GPU 幀耗時接近更新週期預算時，自動平滑調整光流檔位（Q4..Q0），確保零掉幀與音畫同步"
        case .ja:     return "GPU負荷が高い場合に品質ティア(Q4〜Q0)を自動調整し、コマ落ちや音ズレを防ぎます"
        case .ko:     return "GPU 처리 시간이 프레임 예산을 초과하려 할 때 품질 단계를 자동 조절하여 프레임 드롭을 방지합니다"
        case .fr:     return "Ajuste automatiquement le palier Q4..Q0 si le GPU approche du budget temps réel"
        case .de:     return "Passt die Qualitätsstufe (Q4..Q0) bei hoher GPU-Last automatisch an, um Ruckler zu vermeiden"
        case .es:     return "Ajusta automáticamente el nivel Q4..Q0 para evitar caídas de fotogramas"
        default:      return "Automatically scales quality tier (Q4..Q0) under heavy GPU load to guarantee zero dropped frames"
        }
    }
    var guardOsd: String {
        switch lang {
        case .zhHans: return "画面置信指示条"
        case .zhHant: return "畫面置信指示條"
        case .ja:     return "デバッグ表示"
        case .ko:     return "디버그 표시줄"
        case .fr:     return "Barre de debug"
        case .de:     return "Debug-Leiste"
        case .es:     return "Barra debug"
        default:      return "Debug Bar"
        }
    }
    var guardOsdTip: String {
        switch lang {
        case .zhHans: return "在视频左上角绘制一条 4 像素高的绿/红置信度指示条，用于直观验证补帧是否生效"
        case .zhHant: return "在影片左上角繪製一條 4 像素高的綠/紅置信度指示條，用於直觀驗證補幀是否生效"
        case .ja:     return "映像の左上に4pxの緑/赤の信頼度インジケーターバーを描画します"
        case .ko:     return "영상 좌측 상단에 4픽셀 높이의 녹색/적색 신뢰도 표시줄을 렌더링합니다"
        case .fr:     return "Affiche une fine barre de confiance vert/rouge en haut à gauche de la vidéo"
        case .de:     return "Zeigt oben links im Video einen 4px hohen Grün/Rot-Konfidenzbalken an"
        case .es:     return "Muestra una barra indicadora de confianza de 4px en la esquina superior izquierda"
        default:      return "Renders a 4px green/red confidence bar at the top-left of the video frame"
        }
    }

    // IINA Section & Actions
    var secIina: String {
        switch lang {
        case .zhHans: return "IINA 集成"
        case .zhHant: return "IINA 整合"
        case .ja:     return "IINA 連携"
        case .ko:     return "IINA 연동"
        case .fr:     return "Intégration IINA"
        case .de:     return "IINA-Integration"
        case .es:     return "Integración IINA"
        default:      return "IINA Integration"
        }
    }
    var iinaInjected: String {
        switch lang {
        case .zhHans: return "已注入"
        case .zhHant: return "已注入"
        case .ja:     return "注入済み"
        case .ko:     return "주입됨"
        case .fr:     return "Injecté"
        case .de:     return "Injiziert"
        case .es:     return "Inyectado"
        default:      return "Injected"
        }
    }
    var iinaNative: String {
        switch lang {
        case .zhHans: return "未注入"
        case .zhHant: return "未注入"
        case .ja:     return "未注入"
        case .ko:     return "미주입"
        case .fr:     return "Non injecté"
        case .de:     return "Nicht injiziert"
        case .es:     return "No inyectado"
        default:      return "Not Injected"
        }
    }
    var iinaMissing: String {
        switch lang {
        case .zhHans: return "未安装 IINA"
        case .zhHant: return "未安裝 IINA"
        case .ja:     return "IINA 未検出"
        case .ko:     return "IINA 없음"
        case .fr:     return "IINA introuvable"
        case .de:     return "IINA fehlt"
        case .es:     return "Sin IINA"
        default:      return "IINA Not Found"
        }
    }
    var autoGuardToggle: String {
        switch lang {
        case .zhHans: return "更新自动重注入"
        case .zhHant: return "更新自動重注入"
        case .ja:     return "更新時に自動再注入"
        case .ko:     return "업데이트 시 자동 재주입"
        case .fr:     return "Réinjection auto"
        case .de:     return "Auto-Re-Injektion"
        case .es:     return "Reinyección auto"
        default:      return "Auto-Reinject"
        }
    }
    var autoGuardTip: String {
        switch lang {
        case .zhHans: return "当 IINA 升级覆盖内部动态库时，后台守护进程将自动重新注入补帧引擎，无需手动维护"
        case .zhHant: return "當 IINA 升級覆蓋內部動態庫時，背景守護行程將自動重新注入補幀引擎，無需手動維護"
        case .ja:     return "IINAがアップデートされた際、自動的にフレーム補間エンジンを再注入します"
        case .ko:     return "IINA가 업데이트되어도 백그라운드에서 자동으로 보간 엔진을 다시 주입합니다"
        case .fr:     return "Réinjecte automatiquement le moteur après une mise à jour d'IINA"
        case .de:     return "Injiziert die Engine nach einem IINA-Update automatisch neu"
        case .es:     return "Reinyecta automáticamente el motor cuando IINA se actualiza"
        default:      return "Automatically re-injects MacFrame whenever IINA.app updates"
        }
    }
    var btnInject: String {
        switch lang {
        case .zhHans: return "注入"
        case .zhHant: return "注入"
        case .ja:     return "注入"
        case .ko:     return "주입"
        case .fr:     return "Injecter"
        case .de:     return "Injizieren"
        case .es:     return "Inyectar"
        default:      return "Inject"
        }
    }
    var btnInjectTip: String {
        switch lang {
        case .zhHans: return "将 MacFrame 零拷贝补帧引擎直接注入 /Applications/IINA.app"
        case .zhHant: return "將 MacFrame 零拷貝補幀引擎直接注入 /Applications/IINA.app"
        case .ja:     return "/Applications/IINA.app に MacFrame エンジンを直接注入します"
        case .ko:     return "/Applications/IINA.app에 MacFrame 엔진을 직접 주입합니다"
        case .fr:     return "Injecter directement le moteur MacFrame dans /Applications/IINA.app"
        case .de:     return "MacFrame-Engine direkt in /Applications/IINA.app injizieren"
        case .es:     return "Inyectar el motor MacFrame directamente en /Applications/IINA.app"
        default:      return "Inject the MacFrame engine directly into /Applications/IINA.app"
        }
    }
    var btnRestore: String {
        switch lang {
        case .zhHans: return "还原"
        case .zhHant: return "還原"
        case .ja:     return "復元"
        case .ko:     return "복원"
        case .fr:     return "Restaurer"
        case .de:     return "Wiederherstellen"
        case .es:     return "Restaurar"
        default:      return "Restore"
        }
    }
    var btnRestoreTip: String {
        switch lang {
        case .zhHans: return "卸载补帧引擎并将 IINA 无损还原为原始签名版本"
        case .zhHant: return "卸載補幀引擎並將 IINA 無損還原為原始簽名版本"
        case .ja:     return "エンジンをアンインストールし、IINAを元の署名付き状態に完全復元します"
        case .ko:     return "보간 엔진을 제거하고 IINA를 원래 서명된 상태로 복원합니다"
        case .fr:     return "Désinstaller le moteur et restaurer IINA dans son état d'origine signé"
        case .de:     return "Engine entfernen und IINA verlustfrei in den Originalzustand zurückversetzen"
        case .es:     return "Desinstalar el motor y restaurar IINA a su estado original"
        default:      return "Remove MacFrame and losslessly restore original signed IINA.app"
        }
    }
    var btnOpenIina: String {
        switch lang {
        case .zhHans: return "打开 IINA"
        case .zhHant: return "打開 IINA"
        case .ja:     return "IINA を開く"
        case .ko:     return "IINA 열기"
        case .fr:     return "Ouvrir IINA"
        case .de:     return "IINA öffnen"
        case .es:     return "Abrir IINA"
        default:      return "Open IINA"
        }
    }
    var btnOpenSettings: String {
        switch lang {
        case .zhHans: return "控制面板"
        case .zhHant: return "控制面板"
        case .ja:     return "コントロール"
        case .ko:     return "제어판"
        case .fr:     return "Panneau"
        case .de:     return "Einstellungen"
        case .es:     return "Panel"
        default:      return "Settings"
        }
    }
    var btnQuit: String {
        switch lang {
        case .zhHans: return "退出"
        case .zhHant: return "結束"
        case .ja:     return "終了"
        case .ko:     return "종료"
        case .fr:     return "Quitter"
        case .de:     return "Beenden"
        case .es:     return "Salir"
        default:      return "Quit"
        }
    }
    var langTip: String {
        switch lang {
        case .zhHans: return "切换界面语言（默认跟随系统语言）"
        case .zhHant: return "切換介面語言（預設跟隨系統語言）"
        case .ja:     return "表示言語を切り替えます（デフォルトはシステム言語）"
        case .ko:     return "인터페이스 언어를 변경합니다 (기본값: 시스템 언어)"
        case .fr:     return "Changer la langue de l'interface (par défaut : langue du système)"
        case .de:     return "Sprache der Benutzeroberfläche ändern (Standard: Systemsprache)"
        case .es:     return "Cambiar el idioma de la interfaz (predeterminado: sistema)"
        default:      return "Switch interface language (defaults to system language)"
        }
    }
}

// MARK: - Compact Hover Info Badge

struct HoverInfoBadge: View {
    let tip: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.75))
            .help(tip)
    }
}

// MARK: - View Model

@MainActor
final class MacFrameViewModel: ObservableObject {
    @AppStorage("macframe.language") var languageRaw: String = AppLanguage.system.rawValue

    var selectedLanguage: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .system }
        set {
            languageRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var t: L10n {
        L10n(lang: selectedLanguage.resolved)
    }

    // User Control State
    @Published var enabled: Bool = true
    @Published var fpsMode: Int32 = 0          // 0=Display, 1=Fixed, 2=Double
    @Published var maxFpsCap: Double = 120.0   // 30..240
    @Published var preset: Int32 = 0           // 0=Film, 1=Anime, 2=Sports, 3=Custom
    @Published var backend: Int32 = 1          // 1=MF-Flow, 2=VT-FRC, 0=Auto
    @Published var quality: Float = 1.0
    @Published var artifactGuard: Float = 0.65
    @Published var smoothness: Float = 0.95
    @Published var sceneDetect: Bool = true
    @Published var dedup: Bool = true
    @Published var staticLock: Bool = true
    @Published var letterboxGuard: Bool = true
    @Published var governor: Bool = true
    @Published var debugOsd: Bool = false

    // Live Telemetry State from IINA
    @Published var isPlaybackActive: Bool = false
    @Published var videoWidth: Int32 = 0
    @Published var videoHeight: Int32 = 0
    @Published var sourceFps: Double = 0.0
    @Published var outputFps: Double = 0.0
    @Published var gpuTimeAvgMs: Double = 0.0
    @Published var gpuTimeP99Ms: Double = 0.0
    @Published var currentTier: Int32 = 4
    @Published var meanConfidence: Float = 1.0
    @Published var fallbackRatio: Float = 0.0
    @Published var sceneCuts: UInt64 = 0
    @Published var dedupDrops: UInt64 = 0
    @Published var framesOut: UInt64 = 0

    // IINA Integration Management
    @Published var targetIinaPath: String = "/Applications/IINA.app"
    @Published var isEngineInstalledInTarget: Bool = false
    @Published var isTargetIinaPresent: Bool = true
    @Published var autoInjectOnUpdate: Bool = true
    @Published var statusLogMessage: String = ""

    private var ipcPtr: UnsafeMutablePointer<mf_ipc_state>?
    private var timer: Timer?
    private var isLoadingInitial = false
    private var isRunningInstaller = false
    private var pollCounter: Int = 0

    init() {
        targetIinaPath = "/Applications/IINA.app"
        ipcPtr = mf_ipc_open()
        loadFromIPC()
        refreshIinaInstallStatus()
        ensureInjectedIfNeeded()

        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollTelemetry()
            }
        }
    }

    func loadFromIPC() {
        guard let st = ipcPtr else { return }
        isLoadingInitial = true
        enabled        = st.pointee.enabled != 0
        fpsMode        = st.pointee.fps_mode
        maxFpsCap      = st.pointee.max_fps_cap >= 24.0 ? st.pointee.max_fps_cap : 120.0
        preset         = st.pointee.preset
        backend        = st.pointee.backend
        quality        = st.pointee.quality
        artifactGuard  = st.pointee.artifact_guard
        smoothness     = st.pointee.smoothness
        sceneDetect    = st.pointee.scene_detect != 0
        dedup          = st.pointee.dedup != 0
        staticLock     = st.pointee.static_lock != 0
        letterboxGuard = st.pointee.letterbox_guard != 0
        governor       = st.pointee.governor != 0
        debugOsd       = st.pointee.debug_osd != 0
        isLoadingInitial = false
        syncToIPC()
    }

    func applyPresetDefaults(_ newPreset: Int32) {
        preset = newPreset
        switch newPreset {
        case 0: // Film
            smoothness     = 0.90
            artifactGuard  = 0.60
            quality        = 1.00
            dedup          = false
            sceneDetect    = true
            staticLock     = true
            letterboxGuard = true
        case 1: // Anime
            smoothness     = 1.00
            artifactGuard  = 0.82
            quality        = 1.00
            dedup          = true
            sceneDetect    = true
            staticLock     = true
            letterboxGuard = true
        case 2: // Sports
            smoothness     = 1.00
            artifactGuard  = 0.65
            quality        = 1.00
            dedup          = false
            sceneDetect    = true
            staticLock     = true
            letterboxGuard = false
        default:
            break
        }
        syncToIPC()
    }

    func syncToIPC() {
        if isLoadingInitial { return }
        guard let st = ipcPtr else { return }
        st.pointee.enabled         = enabled ? 1 : 0
        st.pointee.fps_mode        = fpsMode
        st.pointee.max_fps_cap     = maxFpsCap
        st.pointee.preset          = preset
        st.pointee.backend         = backend
        st.pointee.quality         = quality
        st.pointee.artifact_guard  = artifactGuard
        st.pointee.smoothness      = smoothness
        st.pointee.scene_detect    = sceneDetect ? 1 : 0
        st.pointee.dedup           = dedup ? 1 : 0
        st.pointee.static_lock     = staticLock ? 1 : 0
        st.pointee.letterbox_guard = letterboxGuard ? 1 : 0
        st.pointee.governor        = governor ? 1 : 0
        st.pointee.debug_osd       = debugOsd ? 1 : 0
        st.pointee.config_seq     += 1
        mf_ipc_write_plugin_json(st)
    }

    func pollTelemetry() {
        guard let st = ipcPtr else { return }
        let now = mf_ipc_now_ms()
        let hb = st.pointee.heartbeat_ms
        let active = (hb > 0 && now >= hb && (now - hb) < 2000) && enabled
        isPlaybackActive = active
        if active {
            videoWidth     = st.pointee.video_width
            videoHeight    = st.pointee.video_height
            sourceFps      = st.pointee.source_fps
            outputFps      = st.pointee.output_fps
            gpuTimeAvgMs   = st.pointee.stats.gpu_time_ms_avg
            gpuTimeP99Ms   = st.pointee.stats.gpu_time_ms_p99
            currentTier    = st.pointee.stats.current_tier
            meanConfidence = st.pointee.stats.mean_confidence
            fallbackRatio  = st.pointee.stats.fallback_ratio
            sceneCuts      = st.pointee.stats.scene_cuts
            dedupDrops     = st.pointee.stats.dedup_drops
            framesOut      = st.pointee.stats.frames_out
        }

        pollCounter += 1
        if pollCounter % 15 == 0 {
            refreshIinaInstallStatus()
            ensureInjectedIfNeeded()
        }
    }

    func ensureInjectedIfNeeded() {
        guard autoInjectOnUpdate, !isRunningInstaller else { return }
        if isTargetIinaPresent && !isEngineInstalledInTarget {
            runInstaller(install: true)
        }
    }

    func refreshIinaInstallStatus() {
        let dylibPath = targetIinaPath + "/Contents/Frameworks/libmacframe.dylib"
        if FileManager.default.fileExists(atPath: dylibPath) {
            isTargetIinaPresent = true
            isEngineInstalledInTarget = true
        } else if FileManager.default.fileExists(atPath: targetIinaPath) {
            isTargetIinaPresent = true
            isEngineInstalledInTarget = false
        } else {
            isTargetIinaPresent = false
            isEngineInstalledInTarget = false
        }
    }

    private func repoRootPath() -> String {
        let bundlePath = Bundle.main.bundlePath
        let parent1 = (bundlePath as NSString).deletingLastPathComponent
        let parent2 = (parent1 as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: parent2 + "/installer/macframe-install.sh") {
            return parent2
        }
        if FileManager.default.fileExists(atPath: parent1 + "/installer/macframe-install.sh") {
            return parent1
        }
        return FileManager.default.currentDirectoryPath
    }

    func runInstaller(install: Bool) {
        if isRunningInstaller { return }
        isRunningInstaller = true
        autoInjectOnUpdate = install
        let root = repoRootPath()
        let script = root + (install ? "/installer/macframe-install.sh" : "/installer/macframe-uninstall.sh")
        let target = targetIinaPath

        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script, target]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var output = ""
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                output = error.localizedDescription
            }
            let code = proc.terminationStatus
            let finalOutput = output
            await MainActor.run {
                self.isRunningInstaller = false
                self.refreshIinaInstallStatus()
                if code == 0 {
                    self.statusLogMessage = ""
                } else {
                    self.statusLogMessage = "Error (\(code)): \(finalOutput.suffix(120))"
                }
            }
        }
    }

    func launchTargetIina() {
        let url = URL(fileURLWithPath: targetIinaPath)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - App Icon View

struct AppBrandIcon: View {
    let size: CGFloat
    let enabled: Bool

    var body: some View {
        if let img = NSApp.applicationIconImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .saturation(enabled ? 1.0 : 0.15)
                .opacity(enabled ? 1.0 : 0.75)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: enabled ? [.cyan, .blue] : [.gray.opacity(0.4), .gray.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundColor(.white)
                )
        }
    }
}

// MARK: - Menu Bar Popover Dashboard

struct MenuBarDashboardView: View {
    @ObservedObject var vm: MacFrameViewModel
    @Environment(\.openWindow) private var openWindow

    private let fpsCaps: [Double] = [60, 90, 120, 144, 240]

    var body: some View {
        let t = vm.t
        VStack(alignment: .leading, spacing: 12) {
            // Top Status Row
            HStack(spacing: 10) {
                AppBrandIcon(size: 36, enabled: vm.enabled)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MacFrame")
                            .font(.system(size: 14, weight: .bold))
                        statusPill(t: t)
                    }
                    Text(
                        !vm.enabled
                            ? t.stateOff
                            : (vm.isPlaybackActive
                                ? String(format: "%d×%d · %.0f → %.0f fps", vm.videoWidth, vm.videoHeight, vm.sourceFps, vm.outputFps)
                                : t.idleSub)
                    )
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { vm.enabled },
                    set: { val in
                        vm.enabled = val
                        vm.syncToIPC()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(t.masterToggleTip)
            }

            // 2x2 Compact Telemetry Grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                miniMetric(
                    label: t.metricFps,
                    value: vm.isPlaybackActive ? String(format: "%.0f → %.0f", vm.sourceFps, vm.outputFps) : "—",
                    sub: vm.isPlaybackActive ? "\(vm.videoWidth)×\(vm.videoHeight)" : "\(Int(vm.maxFpsCap)) fps"
                )
                miniMetric(
                    label: t.metricGpu,
                    value: vm.isPlaybackActive ? String(format: "%.2f ms", vm.gpuTimeAvgMs) : "—",
                    sub: vm.isPlaybackActive ? String(format: "P99 %.2f ms", vm.gpuTimeP99Ms) : t.idleSub
                )
                miniMetric(
                    label: t.metricQuality,
                    value: vm.isPlaybackActive ? "Q\(vm.currentTier)" : "Q\(Int(round(vm.quality * 3) + 1))",
                    sub: vm.isPlaybackActive ? String(format: "%.0f%%", vm.meanConfidence * 100) : "MF-Flow"
                )
                miniMetric(
                    label: t.metricGuards,
                    value: vm.isPlaybackActive ? "\(vm.sceneCuts) / \(vm.dedupDrops)" : "0 / 0",
                    sub: vm.isEngineInstalledInTarget ? t.iinaInjected : t.iinaNative
                )
            }

            // Quick FPS Cap Bar
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(t.secFps)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    HoverInfoBadge(tip: t.secFpsTip)
                    Spacer()
                }
                HStack(spacing: 5) {
                    ForEach(fpsCaps, id: \.self) { cap in
                        Button {
                            vm.maxFpsCap = cap
                            vm.syncToIPC()
                        } label: {
                            Text("\(Int(cap))")
                                .font(.system(size: 11, weight: vm.maxFpsCap == cap ? .bold : .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(vm.maxFpsCap == cap ? Color.accentColor : Color.secondary.opacity(0.14))
                                .foregroundColor(vm.maxFpsCap == cap ? .white : .primary)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("\(t.fpsCapLabel): \(Int(cap)) fps")
                    }
                }
            }
            .disabled(!vm.enabled)
            .opacity(vm.enabled ? 1.0 : 0.5)

            // Quick Preset Bar
            VStack(alignment: .leading, spacing: 5) {
                Text(t.secPreset)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack(spacing: 5) {
                    miniPresetButton(id: 0, title: t.presetFilm, tip: t.presetFilmTip)
                    miniPresetButton(id: 1, title: t.presetAnime, tip: t.presetAnimeTip)
                    miniPresetButton(id: 2, title: t.presetSports, tip: t.presetSportsTip)
                    miniPresetButton(id: 3, title: t.presetCustom, tip: t.presetCustomTip)
                }
            }
            .disabled(!vm.enabled)
            .opacity(vm.enabled ? 1.0 : 0.5)

            Divider()

            // Footer Actions
            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(t.btnOpenSettings, systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    vm.launchTargetIina()
                } label: {
                    Label("IINA", systemImage: "play.tv")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(t.btnOpenIina)

                Spacer()

                languageMenu(t: t)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(t.btnQuit)
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    private func statusPill(t: L10n) -> some View {
        let color: Color = !vm.enabled ? .secondary : (vm.isPlaybackActive ? .green : .cyan)
        let text: String = !vm.enabled ? t.stateOff : (vm.isPlaybackActive ? t.stateActive : t.stateStandby)
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
    }

    private func miniMetric(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func miniPresetButton(id: Int32, title: String, tip: String) -> some View {
        Button {
            vm.applyPresetDefaults(id)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: vm.preset == id ? .bold : .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(vm.preset == id ? Color.accentColor : Color.secondary.opacity(0.14))
                .foregroundColor(vm.preset == id ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func languageMenu(t: L10n) -> some View {
        Menu {
            ForEach(AppLanguage.allCases) { item in
                Button {
                    vm.selectedLanguage = item
                } label: {
                    if vm.selectedLanguage == item {
                        Text("✓ " + item.displayName(in: vm.selectedLanguage))
                    } else {
                        Text(item.displayName(in: vm.selectedLanguage))
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help(t.langTip)
    }
}

// MARK: - Main Control Center Window

struct ControlCenterView: View {
    @ObservedObject var vm: MacFrameViewModel

    private let fpsCaps: [Double] = [60, 90, 120, 144, 240]

    var body: some View {
        let t = vm.t
        VStack(alignment: .leading, spacing: 12) {
            headerCard(t: t)
            telemetryRow(t: t)
            fpsCard(t: t)
            presetCard(t: t)
            slidersCard(t: t)
            guardsCard(t: t)
            iinaFooterCard(t: t)
        }
        .padding(18)
        .frame(width: 560)
    }

    private func headerCard(t: L10n) -> some View {
        HStack(spacing: 12) {
            AppBrandIcon(size: 44, enabled: vm.enabled)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("MacFrame")
                        .font(.system(size: 18, weight: .bold))
                    let badgeColor: Color = !vm.enabled ? .secondary : (vm.isPlaybackActive ? .green : .cyan)
                    let badgeText: String = !vm.enabled ? t.stateOff : (vm.isPlaybackActive ? t.stateActive : t.stateStandby)
                    Text(badgeText)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.16))
                        .foregroundColor(badgeColor)
                        .clipShape(Capsule())
                }
                if vm.isPlaybackActive && vm.enabled {
                    Text(String(format: "%d×%d · %.1f → %.1f fps", vm.videoWidth, vm.videoHeight, vm.sourceFps, vm.outputFps))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Language Picker
            Menu {
                ForEach(AppLanguage.allCases) { item in
                    Button {
                        vm.selectedLanguage = item
                    } label: {
                        if vm.selectedLanguage == item {
                            Text("✓ " + item.displayName(in: vm.selectedLanguage))
                        } else {
                            Text(item.displayName(in: vm.selectedLanguage))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text(vm.selectedLanguage.displayName(in: vm.selectedLanguage))
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(t.langTip)

            Toggle("", isOn: Binding(
                get: { vm.enabled },
                set: { val in
                    vm.enabled = val
                    vm.syncToIPC()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(1.15)
            .help(t.masterToggleTip)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func telemetryRow(t: L10n) -> some View {
        HStack(spacing: 10) {
            metricBox(
                title: t.metricFps,
                value: vm.isPlaybackActive ? String(format: "%.0f → %.0f", vm.sourceFps, vm.outputFps) : "—",
                sub: vm.isPlaybackActive ? "\(vm.videoWidth)×\(vm.videoHeight)" : t.idleSub
            )
            metricBox(
                title: t.metricGpu,
                value: vm.isPlaybackActive ? String(format: "%.2f ms", vm.gpuTimeAvgMs) : "—",
                sub: vm.isPlaybackActive ? String(format: "P99 %.2f ms", vm.gpuTimeP99Ms) : "0.0 ms"
            )
            metricBox(
                title: t.metricQuality,
                value: vm.isPlaybackActive ? "Q\(vm.currentTier)" : "Q\(Int(round(vm.quality * 3) + 1))",
                sub: vm.isPlaybackActive ? String(format: "%.0f%%", vm.meanConfidence * 100) : "100%"
            )
            metricBox(
                title: t.metricGuards,
                value: vm.isPlaybackActive ? "\(vm.sceneCuts) / \(vm.dedupDrops)" : "0 / 0",
                sub: "Cuts / Dedup"
            )
        }
    }

    private func metricBox(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func fpsCard(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(t.secFps)
                    .font(.system(size: 13, weight: .semibold))
                HoverInfoBadge(tip: t.secFpsTip)
                Spacer()
                Picker("", selection: Binding(
                    get: { vm.fpsMode },
                    set: { val in
                        vm.fpsMode = val
                        vm.syncToIPC()
                    }
                )) {
                    Text(t.modeDisplay).tag(Int32(0))
                    Text(t.modeFixed).tag(Int32(1))
                    Text(t.modeDouble).tag(Int32(2))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .help(t.secFpsTip)
            }

            HStack(spacing: 6) {
                ForEach(fpsCaps, id: \.self) { cap in
                    Button {
                        vm.maxFpsCap = cap
                        vm.syncToIPC()
                    } label: {
                        Text("\(Int(cap))")
                            .font(.system(size: 12, weight: vm.maxFpsCap == cap ? .bold : .medium, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(vm.maxFpsCap == cap ? Color.accentColor : Color.secondary.opacity(0.14))
                            .foregroundColor(vm.maxFpsCap == cap ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("\(t.fpsCapLabel): \(Int(cap)) fps")
                }

                Slider(
                    value: Binding(
                        get: { vm.maxFpsCap },
                        set: { val in
                            vm.maxFpsCap = round(val)
                            vm.syncToIPC()
                        }
                    ),
                    in: 30...240,
                    step: 1
                )
                .help(t.secFpsTip)

                Text("\(Int(vm.maxFpsCap)) fps")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.5)
    }

    private func presetCard(t: L10n) -> some View {
        HStack(spacing: 10) {
            Text(t.secPreset)
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 6) {
                presetPill(id: 0, icon: "film", title: t.presetFilm, tip: t.presetFilmTip)
                presetPill(id: 1, icon: "sparkles", title: t.presetAnime, tip: t.presetAnimeTip)
                presetPill(id: 2, icon: "bolt.fill", title: t.presetSports, tip: t.presetSportsTip)
                presetPill(id: 3, icon: "slider.horizontal.3", title: t.presetCustom, tip: t.presetCustomTip)
            }

            Spacer()

            HStack(spacing: 4) {
                Text(t.backendLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { vm.backend },
                    set: { val in
                        vm.backend = val
                        vm.syncToIPC()
                    }
                )) {
                    Text("MF-Flow").tag(Int32(1))
                    Text("VT-FRC").tag(Int32(2))
                    Text(t.backendAuto).tag(Int32(0))
                }
                .labelsHidden()
                .frame(width: 100)
                .help(t.backendTip)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.5)
    }

    private func presetPill(id: Int32, icon: String, title: String, tip: String) -> some View {
        Button {
            vm.applyPresetDefaults(id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: vm.preset == id ? .bold : .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(vm.preset == id ? Color.accentColor : Color.secondary.opacity(0.14))
            .foregroundColor(vm.preset == id ? .white : .primary)
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func slidersCard(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.secTuning)
                .font(.system(size: 13, weight: .semibold))

            compactSlider(
                title: t.sliderSmoothness,
                valueText: "\(Int(round(vm.smoothness * 100)))%",
                tip: t.sliderSmoothnessTip,
                value: Binding(
                    get: { Double(vm.smoothness) },
                    set: { val in
                        vm.smoothness = Float(val)
                        vm.preset = 3
                        vm.syncToIPC()
                    }
                )
            )

            compactSlider(
                title: t.sliderRepair,
                valueText: "\(Int(round(vm.artifactGuard * 100)))%",
                tip: t.sliderRepairTip,
                value: Binding(
                    get: { Double(vm.artifactGuard) },
                    set: { val in
                        vm.artifactGuard = Float(val)
                        vm.preset = 3
                        vm.syncToIPC()
                    }
                )
            )

            compactSlider(
                title: t.sliderQuality,
                valueText: "Q\(Int(round(vm.quality * 3) + 1))",
                tip: t.sliderQualityTip,
                value: Binding(
                    get: { Double(vm.quality) },
                    set: { val in
                        vm.quality = Float(val)
                        vm.syncToIPC()
                    }
                )
            )
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.5)
    }

    private func compactSlider(title: String, valueText: String, tip: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                HoverInfoBadge(tip: tip)
            }
            .frame(width: 110, alignment: .leading)

            Slider(value: value, in: 0.0...1.0)
                .help(tip)

            Text(valueText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func guardsCard(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.secGuards)
                .font(.system(size: 13, weight: .semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                guardItem(t.guardScene, tip: t.guardSceneTip, isOn: $vm.sceneDetect)
                guardItem(t.guardDedup, tip: t.guardDedupTip, isOn: $vm.dedup)
                guardItem(t.guardHud, tip: t.guardHudTip, isOn: $vm.staticLock)
                guardItem(t.guardLetterbox, tip: t.guardLetterboxTip, isOn: $vm.letterboxGuard)
                guardItem(t.guardGovernor, tip: t.guardGovernorTip, isOn: $vm.governor)
                guardItem(t.guardOsd, tip: t.guardOsdTip, isOn: $vm.debugOsd)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.5)
    }

    private func guardItem(_ label: String, tip: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Toggle(label, isOn: Binding(
                get: { isOn.wrappedValue },
                set: { val in
                    isOn.wrappedValue = val
                    vm.syncToIPC()
                }
            ))
            .font(.system(size: 12))
            .help(tip)

            HoverInfoBadge(tip: tip)
            Spacer(minLength: 0)
        }
    }

    private func iinaFooterCard(t: L10n) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(vm.isEngineInstalledInTarget ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(t.secIina)
                .font(.system(size: 12, weight: .semibold))
            Text(
                !vm.isTargetIinaPresent
                    ? t.iinaMissing
                    : (vm.isEngineInstalledInTarget ? t.iinaInjected : t.iinaNative)
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            Divider()
                .frame(height: 14)

            Toggle(t.autoGuardToggle, isOn: $vm.autoInjectOnUpdate)
                .font(.system(size: 11))
                .help(t.autoGuardTip)

            Spacer()

            Button(t.btnInject) {
                vm.runInstaller(install: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(t.btnInjectTip)

            Button(t.btnRestore) {
                vm.runInstaller(install: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(t.btnRestoreTip)

            Button(t.btnOpenIina) {
                vm.launchTargetIina()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(t.btnOpenIina)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }
}

// MARK: - Application Entry Point

@main
struct MacFrameControlApp: App {
    @StateObject private var vm = MacFrameViewModel()

    var body: some Scene {
        Window("MacFrame", id: "main") {
            ControlCenterView(vm: vm)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarDashboardView(vm: vm)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: vm.enabled ? (vm.isPlaybackActive ? "bolt.horizontal.fill" : "sparkles.tv.fill") : "tv")
                Text(
                    !vm.enabled
                        ? "OFF"
                        : (vm.isPlaybackActive ? "\(Int(round(vm.outputFps)))" : "\(Int(vm.maxFpsCap))")
                )
            }
        }
        .menuBarExtraStyle(.window)
    }
}
