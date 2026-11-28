// SPDX-License-Identifier: GPL-3.0-or-later
// MacFrame — Standalone macOS App & Silent Menu Bar Controller for Frame Interpolation

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import ServiceManagement
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
            case .de:     return "System"
            case .es:     return "Sistema"
            default:      return "System"
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

enum MainTab: String, CaseIterable, Identifiable {
    case live     = "live"
    case settings = "settings"

    var id: String { rawValue }
}

struct L10n {
    let lang: AppLanguage

    // Tabs
    var tabLive: String {
        switch lang {
        case .zhHans: return "实时补帧"
        case .zhHant: return "即時補幀"
        case .ja:     return "リアルタイム補間"
        case .ko:     return "실시간 보간"
        case .fr:     return "Temps réel"
        case .de:     return "Echtzeit"
        case .es:     return "Tiempo real"
        default:      return "Live Interpolation"
        }
    }
    var tabSettings: String {
        switch lang {
        case .zhHans: return "设置"
        case .zhHant: return "設定"
        case .ja:     return "設定"
        case .ko:     return "설정"
        case .fr:     return "Réglages"
        case .de:     return "Einstellungen"
        case .es:     return "Ajustes"
        default:      return "Settings"
        }
    }

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
    var headerSubOff: String {
        switch lang {
        case .zhHans: return "播放器原生直通模式"
        case .zhHant: return "播放器原生直通模式"
        case .ja:     return "ネイティブパススルー"
        case .ko:     return "기본 패스스루 모드"
        case .fr:     return "Mode natif direct"
        case .de:     return "Nativer Modus"
        case .es:     return "Modo nativo directo"
        default:      return "Native Passthrough"
        }
    }
    var masterToggleTip: String {
        switch lang {
        case .zhHans: return "开启或关闭实时补帧；关闭时播放器完全按原生设置运行"
        case .zhHant: return "開啟或關閉即時補幀；關閉時播放器完全按原生設定運行"
        case .ja:     return "フレーム補間のオン/オフを切り替えます。オフ時はプレーヤー本来の設定で動作します"
        case .ko:     return "실시간 프레임 보간을 켜거나 끕니다. 끄면 플레이어가 원래 설정대로 작동합니다"
        case .fr:     return "Activer/désactiver l'interpolation. Désactivé, le lecteur utilise ses réglages natifs"
        case .de:     return "Zwischenbildberechnung ein-/ausschalten. Wenn aus, läuft der Player nativ"
        case .es:     return "Activar o desactivar interpolación. Al apagar, el reproductor usa su configuración nativa"
        default:      return "Toggle real-time frame interpolation. When off, the player runs natively"
        }
    }

    // Telemetry Cards
    var metricFps: String {
        switch lang {
        case .zhHans: return "实时帧率"
        case .zhHant: return "即時幀率"
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
        case .zhHans: return "画质档位"
        case .zhHant: return "畫質檔位"
        case .ja:     return "品質・信頼度"
        case .ko:     return "품질·신뢰도"
        case .fr:     return "Qualité"
        case .de:     return "Qualität"
        case .es:     return "Calidad"
        default:      return "Quality Tier"
        }
    }
    var metricGuards: String {
        switch lang {
        case .zhHans: return "切镜 / 去重"
        case .zhHant: return "切鏡 / 去重"
        case .ja:     return "カット / 重複"
        case .ko:     return "전환 / 중복"
        case .fr:     return "Coupes / Dédup"
        case .de:     return "Schnitte / Dedup"
        case .es:     return "Cortes / Dedup"
        default:      return "Cuts / Dedup"
        }
    }
    var idleSub: String {
        switch lang {
        case .zhHans: return "等待播放视频"
        case .zhHant: return "等待播放影片"
        case .ja:     return "再生待機中"
        case .ko:     return "재생 대기 중"
        case .fr:     return "En attente"
        case .de:     return "Warte auf Video"
        case .es:     return "Sin vídeo"
        default:      return "Waiting for video"
        }
    }
    var confidenceWord: String {
        switch lang {
        case .zhHans: return "置信度"
        case .zhHant: return "置信度"
        case .ja:     return "信頼度"
        case .ko:     return "신뢰도"
        case .fr:     return "Confiance"
        case .de:     return "Konfidenz"
        case .es:     return "Confianza"
        default:      return "Confidence"
        }
    }

    // Frame Rate Section
    var secFps: String {
        switch lang {
        case .zhHans: return "帧率策略"
        case .zhHant: return "幀率策略"
        case .ja:     return "フレームレート設定"
        case .ko:     return "프레임레이트 설정"
        case .fr:     return "Cadence cible"
        case .de:     return "Zielbildrate"
        case .es:     return "Tasa de fotogramas"
        default:      return "Frame Rate Strategy"
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
        case .de:     return "Monitor"
        case .es:     return "Pantalla"
        default:      return "Display Sync"
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
        default:      return "Fixed Cap"
        }
    }
    var modeDouble: String {
        switch lang {
        case .zhHans: return "2x 倍帧"
        case .zhHant: return "2x 倍幀"
        case .ja:     return "2倍補間"
        case .ko:     return "2배속"
        case .fr:     return "Double 2x"
        case .de:     return "2x Modus"
        case .es:     return "Doble 2x"
        default:      return "2x Rate"
        }
    }
    var fpsCapLabel: String {
        switch lang {
        case .zhHans: return "帧率上限"
        case .zhHant: return "幀率上限"
        case .ja:     return "上限 FPS"
        case .ko:     return "최대 FPS"
        case .fr:     return "Plafond FPS"
        case .de:     return "FPS-Limit"
        case .es:     return "Límite FPS"
        default:      return "FPS Ceiling"
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
        default:      return "Scene Presets"
        }
    }
    var secAdvanced: String {
        switch lang {
        case .zhHans: return "高级微调"
        case .zhHant: return "進階微調"
        case .ja:     return "詳細チューニング"
        case .ko:     return "고급 세부 조정"
        case .fr:     return "Réglages avancés"
        case .de:     return "Erweiterte Feinabstimmung"
        case .es:     return "Ajustes avanzados"
        default:      return "Advanced Tuning"
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
        case .ko:     return "애니"
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
        case .es:     return "Deporte"
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
        case .ko:     return "커스텀"
        case .fr:     return "Perso"
        case .de:     return "Eigene"
        case .es:     return "Personal"
        default:      return "Custom"
        }
    }
    var presetCustomTip: String {
        switch lang {
        case .zhHans: return "展开高级微调并使用手动平滑度、修复强度与专项防护开关"
        case .zhHant: return "展開進階微調並使用手動平滑度、修復強度與專項防護開關"
        case .ja:     return "詳細チューニングを展開し、手動パラメータを使用します"
        case .ko:     return "고급 조정을 펼쳐 수동 파라미터를 사용합니다"
        case .fr:     return "Ouvre les réglages avancés avec paramètres manuels"
        case .de:     return "Öffnet die Feinabstimmung mit manuellen Reglern"
        case .es:     return "Abre los ajustes avanzados con parámetros manuales"
        default:      return "Expand Advanced Tuning and use manually adjusted parameters"
        }
    }

    var backendLabel: String {
        switch lang {
        case .zhHans: return "算法引擎"
        case .zhHant: return "演算法引擎"
        case .ja:     return "補間エンジン"
        case .ko:     return "보간 엔진"
        case .fr:     return "Moteur"
        case .de:     return "Engine"
        case .es:     return "Motor"
        default:      return "Engine"
        }
    }
    var backendTip: String {
        switch lang {
        case .zhHans: return "MF-Flow 为自研零拷贝 Metal 光流引擎（推荐）；VT-FRC 调用 macOS 神经网络光流"
        case .zhHant: return "MF-Flow 為自研零拷貝 Metal 光流引擎（推薦）；VT-FRC 呼叫 macOS 神經網路光流"
        case .ja:     return "MF-Flowは独自のゼロコピーMetal光学フロー（推奨）。VT-FRCはmacOS MLフレーム補間を使用"
        case .ko:     return "MF-Flow는 자체 Metal 광학 흐름 엔진(권장), VT-FRC는 macOS 신경망 보간 사용"
        case .fr:     return "MF-Flow : flux optique Metal sans copie (recommandé). VT-FRC : ML Apple"
        case .de:     return "MF-Flow: eigener Zero-Copy Metal Optical Flow (empfohlen). VT-FRC: macOS ML"
        case .es:     return "MF-Flow: flujo óptico Metal propio (recomendado). VT-FRC: ML de macOS"
        default:      return "MF-Flow: custom zero-copy Metal optical flow (recommended). VT-FRC: macOS ML optical flow"
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
    var sliderSmoothness: String {
        switch lang {
        case .zhHans: return "运动平滑度"
        case .zhHant: return "運動平滑度"
        case .ja:     return "動きの滑らかさ"
        case .ko:     return "움직임 부드러움"
        case .fr:     return "Fluidité du mouvement"
        case .de:     return "Bewegungsglättung"
        case .es:     return "Fluidez de movimiento"
        default:      return "Motion Smoothness"
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
        case .zhHans: return "伪影修复强度"
        case .zhHant: return "偽影修復強度"
        case .ja:     return "アーティファクト抑制"
        case .ko:     return "아티팩트 억제 강도"
        case .fr:     return "Protection anti-halo"
        case .de:     return "Artefaktschutz"
        case .es:     return "Supresión de halos"
        default:      return "Artifact Suppression"
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
        case .zhHans: return "光流搜索精度"
        case .zhHant: return "光流搜尋精度"
        case .ja:     return "オプティカルフロー精度"
        case .ko:     return "광학 흐름 탐색 정밀도"
        case .fr:     return "Précision de recherche"
        case .de:     return "Suchpräzision"
        case .es:     return "Precisión de búsqueda"
        default:      return "Optical Flow Precision"
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
        case .ja:     return "アーティファクト保護"
        case .ko:     return "아티팩트 보호 기능"
        case .fr:     return "Protections visuelles"
        case .de:     return "Schutzfunktionen"
        case .es:     return "Protecciones visuales"
        default:      return "Artifact Guards"
        }
    }
    var guardScene: String {
        switch lang {
        case .zhHans: return "切镜防鬼影"
        case .zhHant: return "切鏡防鬼影"
        case .ja:     return "シーン切替保護"
        case .ko:     return "장면 전환 보호"
        case .fr:     return "Coupure de scène"
        case .de:     return "Szenenschnitt-Schutz"
        case .es:     return "Cambio de escena"
        default:      return "Scene Cut Guard"
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
        case .ja:     return "アニメ重複フレーム再構築"
        case .ko:     return "애니 중복 프레임 재구성"
        case .fr:     return "Déduplication Anime"
        case .de:     return "Anime-Duplikatfilter"
        case .es:     return "Deduplicación Anime"
        default:      return "Anime 2s/3s Dedup"
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
        case .zhHans: return "台标与字幕锁定"
        case .zhHant: return "台標與字幕鎖定"
        case .ja:     return "ロゴ・字幕の固定"
        case .ko:     return "로고 및 자막 고정"
        case .fr:     return "Verrouillage HUD / Logos"
        case .de:     return "Logo- & Untertitel-Sperre"
        case .es:     return "Bloqueo de logos y sub"
        default:      return "Static Logo & HUD Lock"
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
        case .ja:     return "シネスコ黒帯保護"
        case .ko:     return "레터박스 검은 여백 보호"
        case .fr:     return "Protection bandes noires"
        case .de:     return "Kinobalken-Schutz"
        case .es:     return "Protección bordes negros"
        default:      return "Cinema Letterbox Guard"
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
        case .zhHans: return "自适应防掉帧"
        case .zhHant: return "自適應防掉幀"
        case .ja:     return "自動負荷ガバナー"
        case .ko:     return "자동 프레임 드롭 방지"
        case .fr:     return "Régulateur thermique"
        case .de:     return "Dynamischer Governor"
        case .es:     return "Regulador de carga GPU"
        default:      return "Adaptive Performance Governor"
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
        case .ja:     return "信頼度デバッグバー"
        case .ko:     return "신뢰도 디버그 표시줄"
        case .fr:     return "Barre de diagnostic"
        case .de:     return "Konfidenz-Debugleiste"
        case .es:     return "Barra de diagnóstico"
        default:      return "On-Screen Confidence Bar"
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

    // Settings: A/B Split Test Mode
    var secAbTest: String {
        switch lang {
        case .zhHans: return "A/B 分屏对比测试"
        case .zhHant: return "A/B 分屏對比測試"
        case .ja:     return "A/B 分割比較テスト"
        case .ko:     return "A/B 분할 비교 테스트"
        case .fr:     return "Comparaison A/B"
        case .de:     return "A/B-Vergleichstest"
        case .es:     return "Comparación A/B"
        default:      return "A/B Split Comparison"
        }
    }
    var secAbTestTip: String {
        switch lang {
        case .zhHans: return "将画面分割为 A（原始未补帧）与 B（实时补帧），支持 HDR 安全分割线与方向切换"
        case .zhHant: return "將畫面分割為 A（原始未補幀）與 B（即時補幀），支援 HDR 安全分割線與方向切換"
        case .ja:     return "画面をA（補間なし）とB（補間あり）に分割表示します（HDR対応・4方向）"
        case .ko:     return "화면을 A(원본)와 B(보간)로 분할 비교합니다 (HDR 안전·4방향)"
        case .fr:     return "Divise l'image entre A (original) et B (interpolé) dans 4 directions"
        case .de:     return "Teilt das Bild in A (Original) und B (Interpoliert) in 4 Richtungen"
        case .es:     return "Divide el vídeo en A (original) y B (interpolado) en 4 direcciones"
        default:      return "Splits playback between A (original un-interpolated) and B (interpolated) with 4-way orientation"
        }
    }
    var abOff: String {
        switch lang {
        case .zhHans: return "关闭"
        case .zhHant: return "關閉"
        case .ja:     return "オフ"
        case .ko:     return "꺼짐"
        case .fr:     return "Désactivé"
        case .de:     return "Aus"
        case .es:     return "Apagado"
        default:      return "Off"
        }
    }
    var abLR: String {
        switch lang {
        case .zhHans: return "左原右补"
        case .zhHant: return "左原右補"
        case .ja:     return "左原 / 右補"
        case .ko:     return "좌원 / 우보"
        case .fr:     return "G:Orig / D:Int"
        case .de:     return "L:Orig / R:Int"
        case .es:     return "I:Orig / D:Int"
        default:      return "L:Orig / R:Int"
        }
    }
    var abRL: String {
        switch lang {
        case .zhHans: return "右原左补"
        case .zhHant: return "右原左補"
        case .ja:     return "右原 / 左補"
        case .ko:     return "우원 / 좌보"
        case .fr:     return "D:Orig / G:Int"
        case .de:     return "R:Orig / L:Int"
        case .es:     return "D:Orig / I:Int"
        default:      return "R:Orig / L:Int"
        }
    }
    var abTB: String {
        switch lang {
        case .zhHans: return "上原下补"
        case .zhHant: return "上原下補"
        case .ja:     return "上原 / 下補"
        case .ko:     return "상원 / 하보"
        case .fr:     return "H:Orig / B:Int"
        case .de:     return "O:Orig / U:Int"
        case .es:     return "A:Orig / B:Int"
        default:      return "T:Orig / B:Int"
        }
    }
    var abBT: String {
        switch lang {
        case .zhHans: return "下原上补"
        case .zhHant: return "下原上補"
        case .ja:     return "下原 / 上補"
        case .ko:     return "하원 / 상보"
        case .fr:     return "B:Orig / H:Int"
        case .de:     return "U:Orig / O:Int"
        case .es:     return "B:Orig / A:Int"
        default:      return "B:Orig / T:Int"
        }
    }
    var abSplitPos: String {
        switch lang {
        case .zhHans: return "分割线位置"
        case .zhHant: return "分割線位置"
        case .ja:     return "分割位置"
        case .ko:     return "분할 위치"
        case .fr:     return "Position"
        case .de:     return "Trennlinie"
        case .es:     return "Posición"
        default:      return "Split Position"
        }
    }
    var abOrigTag: String {
        switch lang {
        case .zhHans: return "A · 原画"
        case .zhHant: return "A · 原畫"
        case .ja:     return "A · 原画"
        case .ko:     return "A · 원본"
        case .fr:     return "A · Orig"
        case .de:     return "A · Orig"
        case .es:     return "A · Orig"
        default:      return "A · Orig"
        }
    }
    var abInterpTag: String {
        switch lang {
        case .zhHans: return "B · 补帧"
        case .zhHant: return "B · 補幀"
        case .ja:     return "B · 補間"
        case .ko:     return "B · 보간"
        case .fr:     return "B · Interp"
        case .de:     return "B · Interp"
        case .es:     return "B · Interp"
        default:      return "B · Interp"
        }
    }

    // Settings: Startup & Hotkey
    var secStartupHotkey: String {
        switch lang {
        case .zhHans: return "启动与快捷键"
        case .zhHant: return "啟動與快捷鍵"
        case .ja:     return "起動とショートカット"
        case .ko:     return "시작 및 단축키"
        case .fr:     return "Démarrage & Raccourci"
        case .de:     return "Autostart & Kurzbefehl"
        case .es:     return "Inicio y atajo"
        default:      return "Startup & Hotkey"
        }
    }
    var launchAtLoginLabel: String {
        switch lang {
        case .zhHans: return "开机自启"
        case .zhHant: return "開機自啟"
        case .ja:     return "ログイン時に起動"
        case .ko:     return "로그인 시 자동 실행"
        case .fr:     return "Lancer à l'ouverture"
        case .de:     return "Bei Anmeldung starten"
        case .es:     return "Abrir al iniciar sesión"
        default:      return "Launch at Login"
        }
    }
    var launchAtLoginSub: String {
        switch lang {
        case .zhHans: return "随系统静默启动至菜单栏，不弹出主窗口"
        case .zhHant: return "隨系統靜默啟動至選單列，不彈出主視窗"
        case .ja:     return "起動時はメニューバーに静かに常駐します"
        case .ko:     return "시스템 시작 시 메뉴 막대로 조용히 실행됩니다"
        case .fr:     return "Démarre silencieusement dans la barre des menus"
        case .de:     return "Startet lautlos in der Menüleiste ohne Hauptfenster"
        case .es:     return "Inicia en silencio en la barra de menús"
        default:      return "Starts silently in the menu bar without opening the main window"
        }
    }
    var hotkeyLabel: String {
        switch lang {
        case .zhHans: return "全局开关补帧快捷键"
        case .zhHant: return "全域開關補幀快捷鍵"
        case .ja:     return "グローバル切替ショートカット"
        case .ko:     return "전역 보간 전환 단축키"
        case .fr:     return "Raccourci global"
        case .de:     return "Globaler Kurzbefehl"
        case .es:     return "Atajo global"
        default:      return "Global Toggle Hotkey"
        }
    }
    var hotkeyTip: String {
        switch lang {
        case .zhHans: return "在任意全屏播放器中直接开关实时补帧（默认 ⌥⇧F）"
        case .zhHant: return "在任意全螢幕播放器中直接開關即時補幀（預設 ⌥⇧F）"
        case .ja:     return "全画面プレーヤー再生中でも即座に補間をオン/オフできます（既定 ⌥⇧F）"
        case .ko:     return "전체 화면 재생 중에도 보간을 즉시 켜고 끌 수 있습니다 (기본 ⌥⇧F)"
        case .fr:     return "Active ou désactive l'interpolation depuis n'importe quelle application (⌥⇧F)"
        case .de:     return "Schaltet die Interpolation auch im Vollbildmodus sofort um (Standard ⌥⇧F)"
        case .es:     return "Activa o desactiva la interpolación desde cualquier reproductor (⌥⇧F)"
        default:      return "Toggle real-time interpolation globally, even in fullscreen players (default ⌥⇧F)"
        }
    }
    var hotkeyRecording: String {
        switch lang {
        case .zhHans: return "按下快捷键..."
        case .zhHant: return "按下快捷鍵..."
        case .ja:     return "キーを入力..."
        case .ko:     return "단축키 입력..."
        case .fr:     return "Appuyez..."
        case .de:     return "Taste drücken..."
        case .es:     return "Pulsa tecla..."
        default:      return "Press keys..."
        }
    }
    var hotkeyReset: String {
        switch lang {
        case .zhHans: return "重置"
        case .zhHant: return "重設"
        case .ja:     return "リセット"
        case .ko:     return "초기화"
        case .fr:     return "Réinit."
        case .de:     return "Zurücksetzen"
        case .es:     return "Restablecer"
        default:      return "Reset"
        }
    }

    // IINA Section & Actions
    var secIina: String {
        switch lang {
        case .zhHans: return "播放器集成 · IINA"
        case .zhHant: return "播放器整合 · IINA"
        case .ja:     return "プレーヤー連携 · IINA"
        case .ko:     return "플레이어 연동 · IINA"
        case .fr:     return "Intégration · IINA"
        case .de:     return "Player-Integration · IINA"
        case .es:     return "Integración · IINA"
        default:      return "Player Integration · IINA"
        }
    }
    var iinaInjected: String {
        switch lang {
        case .zhHans: return "已注入引擎"
        case .zhHant: return "已注入引擎"
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
        case .es:     return "Sin inyectar"
        default:      return "Not Injected"
        }
    }
    var iinaMissing: String {
        switch lang {
        case .zhHans: return "未检测到"
        case .zhHant: return "未檢測到"
        case .ja:     return "未検出"
        case .ko:     return "미설치"
        case .fr:     return "Introuvable"
        case .de:     return "Fehlt"
        case .es:     return "No encontrado"
        default:      return "Not Found"
        }
    }
    var autoGuardToggle: String {
        switch lang {
        case .zhHans: return "更新后自动重注入"
        case .zhHant: return "更新後自動重注入"
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
        case .zhHans: return "当播放器升级覆盖内部动态库时，后台守护进程将自动重新注入补帧引擎"
        case .zhHant: return "當播放器升級覆蓋內部動態庫時，背景守護行程將自動重新注入補幀引擎"
        case .ja:     return "プレーヤー更新時にフレーム補間エンジンを自動的に再注入します"
        case .ko:     return "플레이어 업데이트 시 자동으로 보간 엔진을 다시 주입합니다"
        case .fr:     return "Réinjecte automatiquement le moteur après une mise à jour du lecteur"
        case .de:     return "Injiziert die Engine nach einem Player-Update automatisch neu"
        case .es:     return "Reinyecta automáticamente el motor cuando el reproductor se actualiza"
        default:      return "Automatically re-injects MacFrame whenever the player updates"
        }
    }
    var btnInject: String {
        switch lang {
        case .zhHans: return "注入到 IINA"
        case .zhHant: return "注入到 IINA"
        case .ja:     return "IINA に注入"
        case .ko:     return "IINA에 주입"
        case .fr:     return "Injecter"
        case .de:     return "Injizieren"
        case .es:     return "Inyectar"
        default:      return "Inject into IINA"
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
        case .zhHans: return "还原原版"
        case .zhHant: return "還原原版"
        case .ja:     return "純正に復元"
        case .ko:     return "순정 복원"
        case .fr:     return "Restaurer"
        case .de:     return "Wiederherstellen"
        case .es:     return "Restaurar"
        default:      return "Restore Original"
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
        case .zhHans: return "启动 IINA"
        case .zhHant: return "啟動 IINA"
        case .ja:     return "IINA を起動"
        case .ko:     return "IINA 실행"
        case .fr:     return "Ouvrir IINA"
        case .de:     return "IINA starten"
        case .es:     return "Abrir IINA"
        default:      return "Launch IINA"
        }
    }
    var btnOpenMainWindow: String {
        switch lang {
        case .zhHans: return "打开主窗口"
        case .zhHant: return "打開主視窗"
        case .ja:     return "メインウィンドウを開く"
        case .ko:     return "메인 창 열기"
        case .fr:     return "Ouvrir la fenêtre"
        case .de:     return "Hauptfenster öffnen"
        case .es:     return "Abrir ventana principal"
        default:      return "Open Main Window"
        }
    }
    var btnQuitApp: String {
        switch lang {
        case .zhHans: return "退出 MacFrame"
        case .zhHant: return "結束 MacFrame"
        case .ja:     return "MacFrame を終了"
        case .ko:     return "MacFrame 종료"
        case .fr:     return "Quitter MacFrame"
        case .de:     return "MacFrame beenden"
        case .es:     return "Salir de MacFrame"
        default:      return "Quit MacFrame"
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
    var statusWorking: String {
        switch lang {
        case .zhHans: return "正在处理..."
        case .zhHant: return "正在處理..."
        case .ja:     return "処理中..."
        case .ko:     return "처리 중..."
        case .fr:     return "En cours..."
        case .de:     return "Wird ausgeführt..."
        case .es:     return "Procesando..."
        default:      return "Working..."
        }
    }
    var statusInjectedOk: String {
        switch lang {
        case .zhHans: return "已成功注入 IINA，打开视频即可自动补帧"
        case .zhHant: return "已成功注入 IINA，打開影片即可自動補幀"
        case .ja:     return "IINA への注入が完了しました"
        case .ko:     return "IINA 주입이 완료되었습니다"
        case .fr:     return "Moteur injecté dans IINA avec succès"
        case .de:     return "Engine erfolgreich in IINA injiziert"
        case .es:     return "Motor inyectado en IINA correctamente"
        default:      return "Injected into IINA successfully"
        }
    }
    var statusRestoredOk: String {
        switch lang {
        case .zhHans: return "已无损还原原版 IINA 与原始签名"
        case .zhHant: return "已無損還原原版 IINA 與原始簽名"
        case .ja:     return "純正状態の IINA に復元しました"
        case .ko:     return "순정 IINA 상태로 복원되었습니다"
        case .fr:     return "IINA restauré dans son état d'origine"
        case .de:     return "Original-IINA erfolgreich wiederhergestellt"
        case .es:     return "IINA restaurado a su estado original"
        default:      return "Original signed IINA restored"
        }
    }
    var errScriptMissing: String {
        switch lang {
        case .zhHans: return "未找到内置安装脚本，请重新下载完整安装包"
        case .zhHant: return "未找到內建安裝腳本，請重新下載完整安裝包"
        case .ja:     return "内蔵インストーラーが見つかりません"
        case .ko:     return "내장 설치 스크립트를 찾을 수 없습니다"
        case .fr:     return "Script d'installation intégré introuvable"
        case .de:     return "Integriertes Installationsskript nicht gefunden"
        case .es:     return "No se encontró el script de instalación integrado"
        default:      return "Bundled installer script not found"
        }
    }
}

struct HoverTip: Equatable {
    let text: String
    let rect: CGRect
    let space: String
}

// MARK: - Global Hotkey Manager (Carbon RegisterEventHotKey)

@MainActor
final class GlobalHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    private static let hotKeySignature: OSType = 0x4D46524D // 'MFRM'
    private static let hotKeyID: UInt32 = 1

    func start(enabled: Bool, keyCode: UInt32, carbonModifiers: UInt32) {
        installHandlerIfNeeded()
        update(enabled: enabled, keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    func update(enabled: Bool, keyCode: UInt32, carbonModifiers: UInt32) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        guard enabled else { return }
        installHandlerIfNeeded()
        let hkID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status == noErr {
            hotKeyRef = newRef
        }
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let eh = eventHandlerRef {
            RemoveEventHandler(eh)
            eventHandlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let userData = userData, let event = event else {
                return OSStatus(eventNotHandledErr)
            }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if err == noErr && hkID.signature == GlobalHotkeyManager.hotKeySignature && hkID.id == GlobalHotkeyManager.hotKeyID {
                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    mgr.onTrigger?()
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, selfPtr, &eventHandlerRef)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mod: UInt32 = 0
        if flags.contains(.control) { mod |= UInt32(controlKey) }
        if flags.contains(.option)  { mod |= UInt32(optionKey) }
        if flags.contains(.shift)   { mod |= UInt32(shiftKey) }
        if flags.contains(.command) { mod |= UInt32(cmdKey) }
        return mod
    }

    static func formatShortcut(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var s = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { s += "⌃" }
        if (carbonModifiers & UInt32(optionKey))  != 0 { s += "⌥" }
        if (carbonModifiers & UInt32(shiftKey))   != 0 { s += "⇧" }
        if (carbonModifiers & UInt32(cmdKey))     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:  return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab:    return "⇥"
        case kVK_F1:     return "F1"
        case kVK_F2:     return "F2"
        case kVK_F3:     return "F3"
        case kVK_F4:     return "F4"
        case kVK_F5:     return "F5"
        case kVK_F6:     return "F6"
        case kVK_F7:     return "F7"
        case kVK_F8:     return "F8"
        case kVK_F9:     return "F9"
        case kVK_F10:    return "F10"
        case kVK_F11:    return "F11"
        case kVK_F12:    return "F12"
        case kVK_ANSI_Minus:        return "-"
        case kVK_ANSI_Equal:        return "="
        case kVK_ANSI_LeftBracket:  return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon:    return ";"
        case kVK_ANSI_Quote:        return "'"
        case kVK_ANSI_Comma:        return ","
        case kVK_ANSI_Period:       return "."
        case kVK_ANSI_Slash:        return "/"
        case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Grave:        return "`"
        default: return "Key\(keyCode)"
        }
    }
}

// MARK: - View Model

@MainActor
final class MacFrameViewModel: ObservableObject {
    @AppStorage("macframe.language") var languageRaw: String = AppLanguage.system.rawValue
    @Published var activeTip: HoverTip? = nil
    @Published var selectedTab: MainTab = .live
    @Published var isAdvancedExpanded: Bool = false

    var selectedLanguage: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .system }
        set {
            languageRaw = newValue.rawValue
            objectWillChange.send()
            onStatusBarUpdate?()
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
    @Published var abMode: Int32 = 0           // 0=Off, 1=LR, 2=RL, 3=TB, 4=BT
    @Published var abSplit: Float = 0.5        // 0.1..0.9

    // Live Telemetry State
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
    @Published var isHdr: Int32 = 0            // 0=SDR, 1=HDR10/PQ, 2=HLG
    @Published var activeClient: String = ""

    // Startup & Global Hotkey
    @Published var launchAtLogin: Bool = false
    @Published var hotkeyEnabled: Bool = true
    @Published var hotkeyCode: UInt32 = UInt32(kVK_ANSI_F)
    @Published var hotkeyModifiers: UInt32 = UInt32(optionKey | shiftKey)
    @Published var isRecordingHotkey: Bool = false

    // IINA Integration Management
    @Published var targetIinaPath: String = "/Applications/IINA.app"
    @Published var isEngineInstalledInTarget: Bool = false
    @Published var isTargetIinaPresent: Bool = true
    @Published var autoInjectOnUpdate: Bool = true
    @Published var isRunningInstaller: Bool = false
    @Published var statusLogMessage: String = ""
    @Published var statusLogIsError: Bool = false

    // AppDelegate hooks
    var onOpenMainWindow: (() -> Void)?
    var onStatusBarUpdate: (() -> Void)?

    let hotkeyManager = GlobalHotkeyManager()
    private var hotkeyMonitor: Any?

    private static let autoInjectKey = "macframe.autoInjectOnUpdate"
    private static let hkEnabledKey  = "macframe.hotkey.enabled"
    private static let hkCodeKey     = "macframe.hotkey.keyCode"
    private static let hkModsKey     = "macframe.hotkey.modifiers"

    private var ipcPtr: UnsafeMutablePointer<mf_ipc_state>?
    private var timer: Timer?
    private var isLoadingInitial = false
    private var didAttemptAutoInject = false
    private var pollCounter: Int = 0

    init(startRuntime: Bool = true) {
        targetIinaPath = "/Applications/IINA.app"
        if UserDefaults.standard.object(forKey: Self.autoInjectKey) != nil {
            autoInjectOnUpdate = UserDefaults.standard.bool(forKey: Self.autoInjectKey)
        }
        if UserDefaults.standard.object(forKey: Self.hkEnabledKey) != nil {
            hotkeyEnabled = UserDefaults.standard.bool(forKey: Self.hkEnabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.hkCodeKey) != nil {
            hotkeyCode = UInt32(UserDefaults.standard.integer(forKey: Self.hkCodeKey))
        }
        if UserDefaults.standard.object(forKey: Self.hkModsKey) != nil {
            hotkeyModifiers = UInt32(UserDefaults.standard.integer(forKey: Self.hkModsKey))
        }

        ipcPtr = mf_ipc_open()
        loadFromIPC()
        isAdvancedExpanded = (preset == 3)
        refreshIinaInstallStatus()

        if startRuntime {
            refreshLaunchAtLoginStatus()
            hotkeyManager.onTrigger = { [weak self] in
                self?.toggleEnabledViaHotkey()
            }
            hotkeyManager.start(enabled: hotkeyEnabled, keyCode: hotkeyCode, carbonModifiers: hotkeyModifiers)

            ensureInjectedIfNeeded()
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pollTelemetry()
                }
            }
        }
    }

    var formattedHotkey: String {
        GlobalHotkeyManager.formatShortcut(keyCode: hotkeyCode, carbonModifiers: hotkeyModifiers)
    }

    func toggleEnabledViaHotkey() {
        enabled.toggle()
        syncToIPC()
        onStatusBarUpdate?()
    }

    func setHotkeyEnabled(_ on: Bool) {
        hotkeyEnabled = on
        UserDefaults.standard.set(on, forKey: Self.hkEnabledKey)
        hotkeyManager.update(enabled: hotkeyEnabled, keyCode: hotkeyCode, carbonModifiers: hotkeyModifiers)
    }

    func resetHotkeyToDefault() {
        stopHotkeyRecording()
        hotkeyCode = UInt32(kVK_ANSI_F)
        hotkeyModifiers = UInt32(optionKey | shiftKey)
        UserDefaults.standard.set(Int(hotkeyCode), forKey: Self.hkCodeKey)
        UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Self.hkModsKey)
        hotkeyManager.update(enabled: hotkeyEnabled, keyCode: hotkeyCode, carbonModifiers: hotkeyModifiers)
    }

    func startHotkeyRecording() {
        if isRecordingHotkey {
            stopHotkeyRecording()
            return
        }
        isRecordingHotkey = true
        hotkeyManager.update(enabled: false, keyCode: hotkeyCode, carbonModifiers: hotkeyModifiers)
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopHotkeyRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let hasPrimaryMod = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
            guard hasPrimaryMod else {
                NSSound.beep()
                return nil
            }
            let carbonMods = GlobalHotkeyManager.carbonModifiers(from: flags)
            self.hotkeyCode = UInt32(event.keyCode)
            self.hotkeyModifiers = carbonMods
            self.hotkeyEnabled = true
            UserDefaults.standard.set(true, forKey: Self.hkEnabledKey)
            UserDefaults.standard.set(Int(self.hotkeyCode), forKey: Self.hkCodeKey)
            UserDefaults.standard.set(Int(self.hotkeyModifiers), forKey: Self.hkModsKey)
            self.stopHotkeyRecording()
            return nil
        }
    }

    func stopHotkeyRecording() {
        isRecordingHotkey = false
        if let mon = hotkeyMonitor {
            NSEvent.removeMonitor(mon)
            hotkeyMonitor = nil
        }
        hotkeyManager.update(enabled: hotkeyEnabled, keyCode: hotkeyCode, carbonModifiers: hotkeyModifiers)
    }

    func refreshLaunchAtLoginStatus() {
        let st = SMAppService.mainApp.status
        launchAtLogin = (st == .enabled)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            refreshLaunchAtLoginStatus()
            if on && !launchAtLogin && SMAppService.mainApp.status == .requiresApproval {
                launchAtLogin = true
            }
        } catch {
            refreshLaunchAtLoginStatus()
            statusLogIsError = true
            statusLogMessage = error.localizedDescription
        }
        onStatusBarUpdate?()
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
        abMode         = min(max(st.pointee.ab_mode, 0), 4)
        abSplit        = (st.pointee.ab_split >= 0.1 && st.pointee.ab_split <= 0.9) ? st.pointee.ab_split : 0.5
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
        case 3: // Custom
            withAnimation(.easeInOut(duration: 0.18)) {
                isAdvancedExpanded = true
            }
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
        st.pointee.ab_mode         = min(max(abMode, 0), 4)
        st.pointee.ab_split        = min(max(abSplit, 0.1), 0.9)
        st.pointee.config_seq     += 1
        mf_ipc_write_plugin_json(st)
        onStatusBarUpdate?()
    }

    func pollTelemetry() {
        guard let st = ipcPtr else { return }
        let now = mf_ipc_now_ms()
        let hb = st.pointee.heartbeat_ms
        let active = (hb > 0 && now >= hb && (now - hb) < 2000) && enabled
        let prevActive = isPlaybackActive
        let prevOutFps = outputFps
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
            isHdr          = st.pointee.is_hdr
            activeClient   = withUnsafePointer(to: &st.pointee.active_client) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 32) { cstr in
                    String(cString: cstr)
                }
            }
        } else if prevActive {
            isHdr = 0
            activeClient = ""
        }
        if prevActive != active || abs(prevOutFps - outputFps) >= 0.5 {
            onStatusBarUpdate?()
        }

        pollCounter += 1
        if pollCounter % 15 == 0 {
            refreshIinaInstallStatus()
            ensureInjectedIfNeeded()
        }
    }

    func setAutoInjectOnUpdate(_ enabled: Bool) {
        autoInjectOnUpdate = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoInjectKey)
        if !enabled {
            let plistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/io.github.pseudoomer.macframe.autoinject.plist")
            if FileManager.default.fileExists(atPath: plistPath) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                proc.arguments = ["unload", plistPath]
                try? proc.run()
                proc.waitUntilExit()
                try? FileManager.default.removeItem(atPath: plistPath)
            }
        } else {
            didAttemptAutoInject = false
            ensureInjectedIfNeeded()
        }
    }

    func ensureInjectedIfNeeded() {
        guard autoInjectOnUpdate, !isRunningInstaller, !didAttemptAutoInject else { return }
        if isTargetIinaPresent && !isEngineInstalledInTarget {
            didAttemptAutoInject = true
            runInstaller(install: true, isAuto: true)
        }
    }

    func refreshIinaInstallStatus() {
        let dylibPath = targetIinaPath + "/Contents/Frameworks/libmacframe.dylib"
        let wasInstalled = isEngineInstalledInTarget
        if FileManager.default.fileExists(atPath: dylibPath) {
            isTargetIinaPresent = true
            isEngineInstalledInTarget = true
            didAttemptAutoInject = false
        } else if FileManager.default.fileExists(atPath: targetIinaPath) {
            isTargetIinaPresent = true
            isEngineInstalledInTarget = false
            if wasInstalled {
                didAttemptAutoInject = false
            }
        } else {
            isTargetIinaPresent = false
            isEngineInstalledInTarget = false
        }
    }

    private func installerSource(install: Bool) -> (script: String, isEmbedded: Bool)? {
        let rel = install ? "/installer/macframe-install.sh" : "/installer/macframe-uninstall.sh"
        let fm = FileManager.default
        if let resPath = Bundle.main.resourcePath, fm.fileExists(atPath: resPath + rel) {
            return (resPath + rel, true)
        }
        let bundlePath = Bundle.main.bundlePath
        let parent1 = (bundlePath as NSString).deletingLastPathComponent
        let parent2 = (parent1 as NSString).deletingLastPathComponent
        for dir in [parent2, parent1, fm.currentDirectoryPath] {
            if fm.fileExists(atPath: dir + rel) {
                return (dir + rel, false)
            }
        }
        return nil
    }

    func runInstaller(install: Bool, isAuto: Bool = false) {
        if isRunningInstaller { return }
        guard let source = installerSource(install: install) else {
            statusLogIsError = true
            statusLogMessage = t.errScriptMissing
            return
        }
        isRunningInstaller = true
        statusLogIsError = false
        statusLogMessage = ""
        if !isAuto {
            didAttemptAutoInject = false
            autoInjectOnUpdate = install
            UserDefaults.standard.set(install, forKey: Self.autoInjectKey)
        }
        let target = targetIinaPath
        let bundlePath = Bundle.main.bundlePath
        let isInApplications = bundlePath.hasPrefix("/Applications/") ||
            bundlePath.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/")
        var args = [source.script]
        if install && source.isEmbedded && isInApplications {
            args.append("--skip-app-copy")
        }
        args.append(target)

        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = args
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
            let lines = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let errorSummary = lines.last(where: { $0.contains("[ERROR]") || $0.contains("[FAIL]") })
                ?? lines.last
                ?? "exit code \(code)"
            await MainActor.run {
                self.isRunningInstaller = false
                self.refreshIinaInstallStatus()
                if code == 0 {
                    self.statusLogIsError = false
                    self.statusLogMessage = install ? self.t.statusInjectedOk : self.t.statusRestoredOk
                } else {
                    self.statusLogIsError = true
                    self.statusLogMessage = String(errorSummary.prefix(140))
                }
            }
        }
    }

    func launchTargetIina() {
        let url = URL(fileURLWithPath: targetIinaPath)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Minimalist Monochrome Design Tokens & Hover Tooltip Engine

enum MFTheme {
    static let activeDot = Color(red: 0.20, green: 0.74, blue: 0.44)

    static func surfaceFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.03)
    }
    static func surfaceBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }
    static func pillIdleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
    }
    static func pillActiveFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.90) : Color.black.opacity(0.86)
    }
    static func pillActiveText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black : Color.white
    }
    static func innerCardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)
    }
}

final class FastTipNSView: NSView {
    var tipText: String = ""
    var spaceName: String = ""
    var targetRect: CGRect = .zero
    weak var vm: MacFrameViewModel?
    private var trackingArea: NSTrackingArea?
    private var workItem: DispatchWorkItem?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        workItem?.cancel()
        let text = tipText
        let space = spaceName
        guard !text.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var rootView: NSView = self
            while let sv = rootView.superview {
                rootView = sv
                if String(describing: type(of: rootView)).contains("NSHostingView") {
                    break
                }
            }
            let r = self.convert(self.bounds, to: rootView)
            let finalRect: CGRect
            if rootView.isFlipped {
                finalRect = r
            } else {
                finalRect = CGRect(
                    x: r.minX,
                    y: rootView.bounds.height - r.maxY,
                    width: r.width,
                    height: r.height
                )
            }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.1)) {
                    self.vm?.activeTip = HoverTip(text: text, rect: finalRect, space: space)
                }
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        workItem?.cancel()
        workItem = nil
        let text = tipText
        Task { @MainActor in
            if self.vm?.activeTip?.text == text {
                withAnimation(.easeOut(duration: 0.08)) {
                    self.vm?.activeTip = nil
                }
            }
        }
    }
}

struct FastTipRepresentable: NSViewRepresentable {
    let text: String
    let space: String
    let rect: CGRect
    let vm: MacFrameViewModel

    func makeNSView(context: Context) -> FastTipNSView {
        let v = FastTipNSView()
        v.tipText = text
        v.spaceName = space
        v.targetRect = rect
        v.vm = vm
        return v
    }

    func updateNSView(_ nsView: FastTipNSView, context: Context) {
        nsView.tipText = text
        nsView.spaceName = space
        if rect.width > 0 {
            nsView.targetRect = rect
        }
        nsView.vm = vm
    }
}

struct FloatingTipBanner: View {
    let tip: HoverTip?
    let space: String
    let containerSize: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let tip = tip, tip.space == space {
            let maxW = min(max(containerSize.width - 16, 180), 420)
            let halfClamp = min(maxW * 0.5 + 8, containerSize.width * 0.45)
            let nearBottomEdge = (tip.rect.maxY + 42) > containerSize.height
            let topY = nearBottomEdge ? max(8, tip.rect.minY - 34) : (tip.rect.maxY + 6)
            let clampedCenterX = min(max(tip.rect.midX, halfClamp), max(halfClamp, containerSize.width - halfClamp))

            VStack(spacing: 0) {
                Text(tip.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colorScheme == .dark
                                  ? Color(NSColor(calibratedWhite: 0.14, alpha: 0.96))
                                  : Color(NSColor(calibratedWhite: 0.98, alpha: 0.97)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 8, x: 0, y: 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxW)
                Spacer(minLength: 0)
            }
            .frame(width: maxW, height: 80, alignment: .top)
            .position(x: clampedCenterX, y: topY + 40)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MFTheme.surfaceFill(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MFTheme.surfaceBorder(colorScheme), lineWidth: 1)
            )
    }
}

extension View {
    func fastTip(_ text: String, space: String = "main", vm: MacFrameViewModel) -> some View {
        self.overlay(
            GeometryReader { geo in
                FastTipRepresentable(
                    text: text,
                    space: space,
                    rect: geo.frame(in: .named(space)),
                    vm: vm
                )
            }
            .allowsHitTesting(false)
        )
    }

    func cardSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

struct AppBrandIcon: View {
    let size: CGFloat
    let enabled: Bool

    var body: some View {
        let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns")
        if let path = iconPath, let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .saturation(enabled ? 0.65 : 0.05)
                .opacity(enabled ? 1.0 : 0.65)
        } else if let img = NSApp.applicationIconImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .saturation(enabled ? 0.65 : 0.05)
                .opacity(enabled ? 1.0 : 0.65)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.primary.opacity(enabled ? 0.85 : 0.25))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundColor(Color(NSColor.windowBackgroundColor))
                )
        }
    }
}

// MARK: - Compact Silent Menu Bar Popover (~268pt)

struct MenuBarDashboardView: View {
    @ObservedObject var vm: MacFrameViewModel
    @Environment(\.colorScheme) private var colorScheme

    private let fpsCaps: [Double] = [60, 90, 120, 144, 240]

    var body: some View {
        let t = vm.t
        VStack(alignment: .leading, spacing: 11) {
            // 1. Header Row: Brand + 1-line status + Master Switch
            HStack(spacing: 9) {
                AppBrandIcon(size: 32, enabled: vm.enabled)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MacFrame")
                            .font(.system(size: 13.5, weight: .semibold))
                            .fixedSize()
                        Circle()
                            .fill(!vm.enabled ? Color.secondary.opacity(0.45) : (vm.isPlaybackActive ? MFTheme.activeDot : Color.primary.opacity(0.45)))
                            .frame(width: 6, height: 6)
                    }
                    Text(oneLineStatus(t: t))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { vm.enabled },
                    set: { val in
                        vm.enabled = val
                        vm.syncToIPC()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(MFTheme.activeDot)
                .labelsHidden()
                .fastTip(t.masterToggleTip, space: "dash", vm: vm)
            }

            Divider()
                .opacity(0.45)

            // 2. Quick FPS Pills
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(t.fpsCapLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(vm.maxFpsCap)) fps")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }
                HStack(spacing: 4) {
                    ForEach(fpsCaps, id: \.self) { cap in
                        let selected = vm.maxFpsCap == cap
                        Button {
                            vm.maxFpsCap = cap
                            vm.syncToIPC()
                        } label: {
                            Text("\(Int(cap))")
                                .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                                .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(!vm.enabled)
            .opacity(vm.enabled ? 1.0 : 0.45)

            // 3. Quick Presets
            VStack(alignment: .leading, spacing: 5) {
                Text(t.secPreset)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    dashPresetButton(id: 0, title: t.presetFilm)
                    dashPresetButton(id: 1, title: t.presetAnime)
                    dashPresetButton(id: 2, title: t.presetSports)
                    dashPresetButton(id: 3, title: t.presetCustom)
                }
            }
            .disabled(!vm.enabled)
            .opacity(vm.enabled ? 1.0 : 0.45)

            // 4. Launch at Login Toggle
            HStack {
                Text(t.launchAtLoginLabel)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { val in vm.setLaunchAtLogin(val) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(MFTheme.activeDot)
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(MFTheme.innerCardFill(colorScheme)))

            // 5. Footer: Open Main Window + Language
            HStack(spacing: 6) {
                Button {
                    vm.onOpenMainWindow?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11, weight: .medium))
                        Text(t.btnOpenMainWindow)
                            .font(.system(size: 11.5, weight: .semibold))
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(MFTheme.pillActiveFill(colorScheme))
                    .foregroundColor(MFTheme.pillActiveText(colorScheme))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)

                languageMenu(t: t)
            }
        }
        .padding(14)
        .frame(width: 268)
        .coordinateSpace(name: "dash")
        .overlay(
            GeometryReader { geo in
                FloatingTipBanner(tip: vm.activeTip, space: "dash", containerSize: geo.size)
            }
            .allowsHitTesting(false)
        )
    }

    private func oneLineStatus(t: L10n) -> String {
        if !vm.enabled {
            return "\(t.stateOff) · \(vm.formattedHotkey)"
        }
        if vm.isPlaybackActive {
            return String(format: "%.0f→%.0f fps · %.1fms", vm.sourceFps, vm.outputFps, vm.gpuTimeAvgMs)
        }
        return "\(t.stateStandby) · \(Int(vm.maxFpsCap)) fps"
    }

    private func dashPresetButton(id: Int32, title: String) -> some View {
        let selected = vm.preset == id
        return Button {
            vm.applyPresetDefaults(id)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 12))
                .frame(width: 28, height: 26)
                .background(MFTheme.pillIdleFill(colorScheme))
                .cornerRadius(7)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .fastTip(t.langTip, space: "dash", vm: vm)
    }
}

// MARK: - Main Control Center Window (Minimalist Monochrome, 2-Tab Layout)

struct ControlCenterView: View {
    @ObservedObject var vm: MacFrameViewModel
    @Environment(\.colorScheme) private var colorScheme

    private let fpsCaps: [Double] = [60, 90, 120, 144, 240]

    var body: some View {
        let t = vm.t
        VStack(alignment: .leading, spacing: 14) {
            headerSection(t: t)
            tabSwitcher(t: t)

            if vm.selectedTab == .live {
                liveTabView(t: t)
            } else {
                settingsTabView(t: t)
            }
        }
        .padding(20)
        .frame(width: 650)
        .coordinateSpace(name: "main")
        .overlay(
            GeometryReader { geo in
                FloatingTipBanner(tip: vm.activeTip, space: "main", containerSize: geo.size)
            }
            .allowsHitTesting(false)
        )
    }

    // 1. Header Card
    private func headerSection(t: L10n) -> some View {
        HStack(spacing: 12) {
            AppBrandIcon(size: 42, enabled: vm.enabled)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("MacFrame")
                        .font(.system(size: 18, weight: .bold))
                        .fixedSize()

                    statusBadge(t: t)

                    if vm.isPlaybackActive && vm.isHdr > 0 {
                        Text(vm.isHdr == 1 ? "HDR10" : "HLG")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MFTheme.pillIdleFill(colorScheme))
                            .cornerRadius(4)
                    }
                }

                Text(
                    !vm.enabled
                        ? t.headerSubOff
                        : (vm.isPlaybackActive
                            ? String(format: "%d×%d · %.1f → %.1f fps", vm.videoWidth, vm.videoHeight, vm.sourceFps, vm.outputFps)
                            : "\(t.idleSub) · \(Int(vm.maxFpsCap)) fps")
                )
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize()
            }

            Spacer()

            // Language Switcher Menu
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
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 11.5))
                    Text(vm.selectedLanguage.displayName(in: vm.selectedLanguage))
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(MFTheme.pillIdleFill(colorScheme))
                .cornerRadius(7)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .fastTip(t.langTip, space: "main", vm: vm)

            Toggle("", isOn: Binding(
                get: { vm.enabled },
                set: { val in
                    vm.enabled = val
                    vm.syncToIPC()
                }
            ))
            .toggleStyle(.switch)
            .tint(MFTheme.activeDot)
            .labelsHidden()
            .scaleEffect(1.08)
            .fastTip(t.masterToggleTip, space: "main", vm: vm)
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func statusBadge(t: L10n) -> some View {
        let dotColor: Color = !vm.enabled ? Color.secondary.opacity(0.5) : (vm.isPlaybackActive ? MFTheme.activeDot : Color.primary.opacity(0.45))
        let text: String = !vm.enabled ? t.stateOff : (vm.isPlaybackActive ? t.stateActive : t.stateStandby)
        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(vm.isPlaybackActive && vm.enabled ? .primary : .secondary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(MFTheme.pillIdleFill(colorScheme))
        .clipShape(Capsule())
    }

    // 2. Top Segmented Tab Switcher
    private func tabSwitcher(t: L10n) -> some View {
        HStack(spacing: 4) {
            tabPill(tab: .live, icon: "waveform.path", title: t.tabLive)
            tabPill(tab: .settings, icon: "gearshape", title: t.tabSettings)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(MFTheme.surfaceFill(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MFTheme.surfaceBorder(colorScheme), lineWidth: 1)
        )
    }

    private func tabPill(tab: MainTab, icon: String, title: String) -> some View {
        let selected = vm.selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                vm.selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selected ? MFTheme.pillActiveFill(colorScheme) : Color.clear)
            .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .secondary)
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 1: Live Interpolation

    private func liveTabView(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            telemetrySection(t: t)
            fpsSection(t: t)
            presetAndAdvancedSection(t: t)
        }
    }

    private func telemetrySection(t: L10n) -> some View {
        HStack(spacing: 10) {
            metricCard(
                title: t.metricFps,
                value: vm.isPlaybackActive ? String(format: "%.0f → %.0f", vm.sourceFps, vm.outputFps) : "—",
                sub: vm.isPlaybackActive ? "\(vm.videoWidth)×\(vm.videoHeight)" : t.idleSub
            )
            metricCard(
                title: t.metricGpu,
                value: vm.isPlaybackActive ? String(format: "%.2f ms", vm.gpuTimeAvgMs) : "—",
                sub: vm.isPlaybackActive ? String(format: "P99 %.2f ms", vm.gpuTimeP99Ms) : "0.0 ms"
            )
            metricCard(
                title: t.metricQuality,
                value: vm.isPlaybackActive ? "Q\(vm.currentTier)" : "Q\(Int(round(vm.quality * 3) + 1))",
                sub: vm.isPlaybackActive ? String(format: "%@ %.0f%%", t.confidenceWord, vm.meanConfidence * 100) : "100%"
            )
            metricCard(
                title: t.metricGuards,
                value: vm.isPlaybackActive ? "\(vm.sceneCuts) / \(vm.dedupDrops)" : "0 / 0",
                sub: vm.isEngineInstalledInTarget ? "IINA · \(t.iinaInjected)" : "IINA · \(t.iinaNative)"
            )
        }
    }

    private func metricCard(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize()
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .fixedSize()
            Text(sub)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 10)
    }

    private func fpsSection(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Text(t.secFps)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()

                Spacer()

                HStack(spacing: 6) {
                    modePill(id: 0, title: t.modeDisplay, tip: t.secFpsTip)
                    modePill(id: 1, title: t.modeFixed, tip: t.secFpsTip)
                    modePill(id: 2, title: t.modeDouble, tip: t.secFpsTip)
                }
            }

            Divider().opacity(0.45)

            HStack(spacing: 10) {
                Text(t.fpsCapLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize()

                HStack(spacing: 5) {
                    ForEach(fpsCaps, id: \.self) { cap in
                        let selected = vm.maxFpsCap == cap
                        Button {
                            vm.maxFpsCap = cap
                            vm.syncToIPC()
                        } label: {
                            Text("\(Int(cap))")
                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium, design: .rounded))
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                                .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .fastTip("\(t.fpsCapLabel): \(Int(cap)) fps", space: "main", vm: vm)
                    }
                }

                Slider(
                    value: Binding(
                        get: { vm.maxFpsCap },
                        set: { val in
                            vm.maxFpsCap = round(val)
                            vm.syncToIPC()
                        }
                    ),
                    in: 30...240
                )
                .tint(.primary)
                .fastTip(t.secFpsTip, space: "main", vm: vm)

                Text("\(Int(vm.maxFpsCap)) fps")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 60, alignment: .trailing)
                    .fixedSize()
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.45)
    }

    private func modePill(id: Int32, title: String, tip: String) -> some View {
        let selected = vm.fpsMode == id
        return Button {
            vm.fpsMode = id
            vm.syncToIPC()
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .fastTip(tip, space: "main", vm: vm)
    }

    private func presetAndAdvancedSection(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(t.secPreset)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()

                Spacer()

                HStack(spacing: 6) {
                    Text(t.backendLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    HStack(spacing: 4) {
                        backendPill(id: 1, title: "MF-Flow", tip: t.backendTip)
                        backendPill(id: 2, title: "VT-FRC", tip: t.backendTip)
                        backendPill(id: 0, title: t.backendAuto, tip: t.backendTip)
                    }
                }
            }

            HStack(spacing: 8) {
                presetCardButton(id: 0, icon: "film", title: t.presetFilm, tip: t.presetFilmTip)
                presetCardButton(id: 1, icon: "sparkles", title: t.presetAnime, tip: t.presetAnimeTip)
                presetCardButton(id: 2, icon: "bolt.fill", title: t.presetSports, tip: t.presetSportsTip)
                presetCardButton(id: 3, icon: "slider.horizontal.3", title: t.presetCustom, tip: t.presetCustomTip)
            }

            Divider().opacity(0.45)

            // Collapsible Advanced Tuning Header
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    vm.isAdvancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vm.isAdvancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Text(t.secAdvanced)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%d%% · %d%% · Q%d",
                                Int(round(vm.smoothness * 100)),
                                Int(round(vm.artifactGuard * 100)),
                                Int(round(vm.quality * 3) + 1)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if vm.isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 11) {
                    fullWidthSliderRow(
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

                    fullWidthSliderRow(
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

                    fullWidthSliderRow(
                        title: t.sliderQuality,
                        valueText: "Q\(Int(round(vm.quality * 3) + 1)) (\(Int(round(vm.quality * 100)))%)",
                        tip: t.sliderQualityTip,
                        value: Binding(
                            get: { Double(vm.quality) },
                            set: { val in
                                vm.quality = Float(val)
                                vm.syncToIPC()
                            }
                        )
                    )

                    Divider().opacity(0.45)

                    Text(t.secGuards)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                        guardSwitchRow(t.guardScene, tip: t.guardSceneTip, isOn: $vm.sceneDetect)
                        guardSwitchRow(t.guardDedup, tip: t.guardDedupTip, isOn: $vm.dedup)
                        guardSwitchRow(t.guardHud, tip: t.guardHudTip, isOn: $vm.staticLock)
                        guardSwitchRow(t.guardLetterbox, tip: t.guardLetterboxTip, isOn: $vm.letterboxGuard)
                        guardSwitchRow(t.guardGovernor, tip: t.guardGovernorTip, isOn: $vm.governor)
                        guardSwitchRow(t.guardOsd, tip: t.guardOsdTip, isOn: $vm.debugOsd)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.45)
    }

    private func backendPill(id: Int32, title: String, tip: String) -> some View {
        let selected = vm.backend == id
        return Button {
            vm.backend = id
            vm.syncToIPC()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .fastTip(tip, space: "main", vm: vm)
    }

    private func presetCardButton(id: Int32, icon: String, title: String, tip: String) -> some View {
        let selected = vm.preset == id
        return Button {
            vm.applyPresetDefaults(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
            .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .fastTip(tip, space: "main", vm: vm)
    }

    private func fullWidthSliderRow(title: String, valueText: String, tip: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
                .frame(minWidth: 155, alignment: .leading)

            Slider(value: value, in: 0.0...1.0)
                .tint(.primary)

            Text(valueText)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize()
                .frame(minWidth: 66, alignment: .trailing)
        }
        .fastTip(tip, space: "main", vm: vm)
    }

    private func guardSwitchRow(_ label: String, tip: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5, weight: .regular))
                .fixedSize()
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { val in
                    isOn.wrappedValue = val
                    vm.preset = 3
                    vm.syncToIPC()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(MFTheme.activeDot)
            .labelsHidden()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(MFTheme.innerCardFill(colorScheme)))
        .fastTip(tip, space: "main", vm: vm)
    }

    // MARK: - Tab 2: Settings (A/B Test Mode + Startup & Hotkey + Player Integration)

    private func settingsTabView(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            abComparisonSection(t: t)
            startupAndHotkeySection(t: t)
            iinaSection(t: t)
        }
    }

    private func abComparisonSection(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(t.secAbTest)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                Spacer()
                if vm.abMode != 0 {
                    Text("\(Int(round(vm.abSplit * 100)))%")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            .fastTip(t.secAbTestTip, space: "main", vm: vm)

            HStack(spacing: 6) {
                abModeButton(id: 0, title: t.abOff)
                abModeButton(id: 1, title: t.abLR)
                abModeButton(id: 2, title: t.abRL)
                abModeButton(id: 3, title: t.abTB)
                abModeButton(id: 4, title: t.abBT)
            }

            if vm.abMode != 0 {
                HStack(spacing: 12) {
                    Text(t.abSplitPos)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()

                    Slider(
                        value: Binding(
                            get: { Double(vm.abSplit) },
                            set: { val in
                                vm.abSplit = Float(val)
                                vm.syncToIPC()
                            }
                        ),
                        in: 0.1...0.9
                    )
                    .tint(.primary)

                    Text("\(Int(round(vm.abSplit * 100)))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }

                abSchematicPreview(t: t)
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func abModeButton(id: Int32, title: String) -> some View {
        let selected = vm.abMode == id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.abMode = id
            }
            vm.syncToIPC()
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(selected ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                .foregroundColor(selected ? MFTheme.pillActiveText(colorScheme) : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func abSchematicPreview(t: L10n) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let split = CGFloat(min(max(vm.abSplit, 0.1), 0.9))
            let origFill = colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
            let interpFill = colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.11)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(origFill)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(MFTheme.surfaceBorder(colorScheme), lineWidth: 1)

                if vm.abMode == 1 || vm.abMode == 2 {
                    let sx = w * split
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(vm.abMode == 1 ? origFill : interpFill)
                            .frame(width: sx)
                        Rectangle()
                            .fill(vm.abMode == 1 ? interpFill : origFill)
                            .frame(width: max(0, w - sx))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: h)
                        .position(x: sx, y: h * 0.5)

                    HStack {
                        Text(vm.abMode == 1 ? t.abOrigTag : t.abInterpTag)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.leading, 10)
                        Spacer()
                        Text(vm.abMode == 1 ? t.abInterpTag : t.abOrigTag)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.trailing, 10)
                    }
                } else {
                    let sy = h * split
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(vm.abMode == 3 ? origFill : interpFill)
                            .frame(height: sy)
                        Rectangle()
                            .fill(vm.abMode == 3 ? interpFill : origFill)
                            .frame(height: max(0, h - sy))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: w, height: 2)
                        .position(x: w * 0.5, y: sy)

                    VStack {
                        Text(vm.abMode == 3 ? t.abOrigTag : t.abInterpTag)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(vm.abMode == 3 ? t.abInterpTag : t.abOrigTag)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(height: 44)
    }

    private func startupAndHotkeySection(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(t.secStartupHotkey)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()

            // Launch at Login row
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.launchAtLoginLabel)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(t.launchAtLoginSub)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { val in vm.setLaunchAtLogin(val) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(MFTheme.activeDot)
                .labelsHidden()
            }

            Divider().opacity(0.45)

            // Global Hotkey row
            HStack(spacing: 10) {
                Text(t.hotkeyLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()

                Spacer()

                Button {
                    vm.startHotkeyRecording()
                } label: {
                    Text(vm.isRecordingHotkey ? t.hotkeyRecording : vm.formattedHotkey)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(vm.isRecordingHotkey ? MFTheme.pillActiveFill(colorScheme) : MFTheme.pillIdleFill(colorScheme))
                        .foregroundColor(vm.isRecordingHotkey ? MFTheme.pillActiveText(colorScheme) : .primary)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(t.hotkeyReset) {
                    vm.resetHotkeyToDefault()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle("", isOn: Binding(
                    get: { vm.hotkeyEnabled },
                    set: { val in vm.setHotkeyEnabled(val) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(MFTheme.activeDot)
                .labelsHidden()
            }
            .fastTip(t.hotkeyTip, space: "main", vm: vm)
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }

    private func iinaSection(t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vm.isEngineInstalledInTarget ? MFTheme.activeDot : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(t.secIina)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                Text(
                    !vm.isTargetIinaPresent
                        ? t.iinaMissing
                        : (vm.isEngineInstalledInTarget ? t.iinaInjected : t.iinaNative)
                )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(vm.isEngineInstalledInTarget ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(MFTheme.pillIdleFill(colorScheme))
                .clipShape(Capsule())
                .fixedSize()

                Spacer()

                HStack(spacing: 7) {
                    Text(t.autoGuardToggle)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Toggle("", isOn: Binding(
                        get: { vm.autoInjectOnUpdate },
                        set: { val in vm.setAutoInjectOnUpdate(val) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(MFTheme.activeDot)
                    .labelsHidden()
                }
                .fastTip(t.autoGuardTip, space: "main", vm: vm)
            }

            Divider().opacity(0.45)

            HStack(spacing: 8) {
                Button {
                    vm.runInstaller(install: true)
                } label: {
                    Text(t.btnInject)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(MFTheme.pillActiveFill(colorScheme))
                        .foregroundColor(MFTheme.pillActiveText(colorScheme))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(vm.isRunningInstaller || !vm.isTargetIinaPresent)
                .opacity((vm.isRunningInstaller || !vm.isTargetIinaPresent) ? 0.45 : 1.0)
                .fastTip(t.btnInjectTip, space: "main", vm: vm)

                Button(t.btnRestore) {
                    vm.runInstaller(install: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.isRunningInstaller || !vm.isTargetIinaPresent)
                .fixedSize()
                .fastTip(t.btnRestoreTip, space: "main", vm: vm)

                if vm.isRunningInstaller {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(t.statusWorking)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }

                Spacer()

                Button {
                    vm.launchTargetIina()
                } label: {
                    Label(t.btnOpenIina, systemImage: "play.tv")
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!vm.isTargetIinaPresent)
                .fastTip(t.btnOpenIina, space: "main", vm: vm)
            }

            if !vm.statusLogMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: vm.statusLogIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(vm.statusLogIsError ? .orange : MFTheme.activeDot)
                    Text(vm.statusLogMessage)
                        .font(.system(size: 11))
                        .foregroundColor(vm.statusLogIsError ? .orange : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }
}

// MARK: - Snapshot Renderer for Dark & Light Multi-Language Verification

@MainActor
func findFastTipRect(in view: NSView, for text: String, rootView: NSView) -> CGRect? {
    if let tipView = view as? FastTipNSView, tipView.tipText == text {
        let r = tipView.convert(tipView.bounds, to: rootView)
        if rootView.isFlipped {
            return r
        } else {
            return CGRect(
                x: r.minX,
                y: rootView.bounds.height - r.maxY,
                width: r.width,
                height: r.height
            )
        }
    }
    for sub in view.subviews {
        if let found = findFastTipRect(in: sub, for: text, rootView: rootView) {
            return found
        }
    }
    return nil
}

@MainActor
func renderHostingViewToPNG<V: View>(_ view: V, dark: Bool, path: String) {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
func dumpUISnapshots(to dir: String) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let vm = MacFrameViewModel(startRuntime: false)
    vm.enabled = true
    vm.isPlaybackActive = true
    vm.videoWidth = 1920
    vm.videoHeight = 1080
    vm.sourceFps = 23.976
    vm.outputFps = 120.0
    vm.gpuTimeAvgMs = 1.48
    vm.gpuTimeP99Ms = 2.31
    vm.currentTier = 4
    vm.meanConfidence = 0.96
    vm.sceneCuts = 5
    vm.dedupDrops = 18
    vm.isHdr = 1
    vm.isEngineInstalledInTarget = true

    let testLangs: [AppLanguage] = [.zhHans, .zhHant, .en, .ja, .ko, .fr, .de, .es]
    for lang in testLangs {
        vm.selectedLanguage = lang
        vm.selectedTab = .live
        vm.isAdvancedExpanded = false

        for isDark in [true, false] {
            let suffix = isDark ? "dark" : "light"
            let cs: ColorScheme = isDark ? .dark : .light

            let mainView = ControlCenterView(vm: vm)
                .background(Color(NSColor.windowBackgroundColor))
                .environment(\.colorScheme, cs)
            renderHostingViewToPNG(mainView, dark: isDark, path: "\(dir)/main_\(lang.rawValue)_\(suffix).png")

            let dashView = MenuBarDashboardView(vm: vm)
                .background(Color(NSColor.windowBackgroundColor))
                .environment(\.colorScheme, cs)
            renderHostingViewToPNG(dashView, dark: isDark, path: "\(dir)/dash_\(lang.rawValue)_\(suffix).png")
        }
    }

    // Expanded Advanced Tuning + Settings Tab snapshots (Dark & Light)
    vm.selectedLanguage = .zhHans
    for isDark in [true, false] {
        let suffix = isDark ? "dark" : "light"
        let cs: ColorScheme = isDark ? .dark : .light

        vm.selectedTab = .live
        vm.isAdvancedExpanded = true
        let advView = ControlCenterView(vm: vm)
            .background(Color(NSColor.windowBackgroundColor))
            .environment(\.colorScheme, cs)
        renderHostingViewToPNG(advView, dark: isDark, path: "\(dir)/main_adv_\(suffix).png")

        vm.selectedTab = .settings
        vm.abMode = 1
        vm.abSplit = 0.45
        let setView = ControlCenterView(vm: vm)
            .background(Color(NSColor.windowBackgroundColor))
            .environment(\.colorScheme, cs)
        renderHostingViewToPNG(setView, dark: isDark, path: "\(dir)/main_settings_\(suffix).png")
    }

    // Tooltip preview
    vm.selectedTab = .live
    vm.isAdvancedExpanded = false
    vm.abMode = 0
    vm.activeTip = nil
    let probeHosting = NSHostingView(
        rootView: ControlCenterView(vm: vm)
            .background(Color(NSColor.windowBackgroundColor))
            .environment(\.colorScheme, .dark)
    )
    probeHosting.frame = NSRect(origin: .zero, size: probeHosting.fittingSize)
    probeHosting.layoutSubtreeIfNeeded()
    if let realRect = findFastTipRect(in: probeHosting, for: vm.t.presetAnimeTip, rootView: probeHosting) {
        vm.activeTip = HoverTip(text: vm.t.presetAnimeTip, rect: realRect, space: "main")
    }
    let tipPreview = ControlCenterView(vm: vm)
        .background(Color(NSColor.windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    renderHostingViewToPNG(tipPreview, dark: true, path: "\(dir)/main_tip_preview.png")
    vm.activeTip = nil
}

// MARK: - AppKit Delegate: Silent Menu Bar + Dynamic Dock Policy + Right-Click NSMenu

@MainActor
final class MacFrameAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var vm: MacFrameViewModel!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var hostingController: NSHostingController<ControlCenterView>?

    private static let reopenNotification = Notification.Name("io.github.pseudoomer.macframe.openMainWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure single instance: if already running, tell existing instance to open main window and exit
        if let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != myPID }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.reopenNotification,
                    object: bundleID,
                    userInfo: nil,
                    deliverImmediately: true
                )
                NSApp.terminate(nil)
                return
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalReopen),
            name: Self.reopenNotification,
            object: Bundle.main.bundleIdentifier
        )

        setupMainMenu()
        vm = MacFrameViewModel(startRuntime: true)
        vm.onOpenMainWindow = { [weak self] in
            self?.openMainWindow()
        }
        vm.onStatusBarUpdate = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        setupStatusItemAndPopover()
        updateStatusItemAppearance()

        if isSilentLoginLaunch() {
            NSApp.setActivationPolicy(.accessory)
        } else {
            openMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        vm?.hotkeyManager.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    @objc private func handleExternalReopen() {
        Task { @MainActor in
            self.openMainWindow()
        }
    }

    private func isSilentLoginLaunch() -> Bool {
        if CommandLine.arguments.contains("--silent") {
            return true
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           let prop = event.paramDescriptor(forKeyword: keyAEPropData),
           prop.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return false
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide MacFrame", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MacFrame", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItemAndPopover() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.imagePosition = .imageLeading
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let dashController = NSHostingController(rootView: MenuBarDashboardView(vm: vm))
        dashController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = dashController
    }

    private func updateStatusItemAppearance() {
        guard let btn = statusItem?.button, let vm = vm else { return }
        let symbolName = vm.enabled
            ? (vm.isPlaybackActive ? "bolt.horizontal.fill" : "sparkles.tv.fill")
            : "tv"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MacFrame") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            let styled = img.withSymbolConfiguration(cfg) ?? img
            styled.isTemplate = true
            btn.image = styled
        }
        if !vm.enabled {
            btn.title = " OFF"
        } else if vm.isPlaybackActive {
            btn.title = " \(Int(round(vm.outputFps)))"
        } else {
            btn.title = " \(Int(vm.maxFpsCap))"
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        let isRightClick = (ev?.type == .rightMouseUp) ||
            (ev?.type == .leftMouseUp && ev?.modifierFlags.contains(.control) == true)

        if isRightClick {
            if popover.isShown {
                popover.performClose(sender)
            }
            let menu = buildRightClickMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func buildRightClickMenu() -> NSMenu {
        let t = vm.t
        let menu = NSMenu()

        let openItem = NSMenuItem(title: t.btnOpenMainWindow, action: #selector(menuOpenMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let loginItem = NSMenuItem(title: t.launchAtLoginLabel, action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = vm.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: t.btnQuitApp, action: #selector(menuQuitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func menuOpenMainWindow() {
        openMainWindow()
    }

    @objc private func menuToggleLaunchAtLogin() {
        vm.setLaunchAtLogin(!vm.launchAtLogin)
    }

    @objc private func menuQuitApp() {
        NSApp.terminate(nil)
    }

    func openMainWindow() {
        if popover.isShown {
            popover.performClose(nil)
        }
        NSApp.setActivationPolicy(.regular)

        if mainWindow == nil {
            let hc = NSHostingController(rootView: ControlCenterView(vm: vm))
            hc.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: hc)
            win.title = "MacFrame"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            hostingController = hc
            mainWindow = win
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === mainWindow else { return }
        vm.stopHotkeyRecording()
        DispatchQueue.main.async {
            if self.mainWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Application Entry Point

@main
enum MacFrameEntry {
    static func main() {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 70])
        UserDefaults.standard.set(70, forKey: "NSInitialToolTipDelay")

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--dump-snapshots"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            MainActor.assumeIsolated {
                dumpUISnapshots(to: outDir)
            }
            return
        }

        let app = NSApplication.shared
        let delegate = MacFrameAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
