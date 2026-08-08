#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate WhisperASR architecture diagrams (SVG)."""
import os

OUT = "/Users/hyj/Desktop/whisperASR_副本/docs/diagrams"
os.makedirs(OUT, exist_ok=True)

FONT = "PingFang SC, Hiragino Sans GB, Microsoft YaHei, Helvetica Neue, sans-serif"

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def header(w, h, title, subtitle):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">\n'
        '<defs>\n'
        '<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#5a5a5a"/></marker>\n'
        '</defs>\n'
        f'<rect x="0" y="0" width="{w}" height="{h}" fill="#ffffff"/>\n'
        f'<text x="{w/2}" y="34" text-anchor="middle" font-size="24" font-weight="bold" fill="#1a1a2e">{esc(title)}</text>\n'
        f'<text x="{w/2}" y="56" text-anchor="middle" font-size="13" fill="#666666">{esc(subtitle)}</text>\n'
    )

def band(x, y, w, h, label, fill, color):
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="{color}" stroke-width="1.2" stroke-dasharray="6 4"/>\n'
        f'<text x="{x+14}" y="{y+24}" font-size="15" font-weight="bold" fill="{color}">{esc(label)}</text>\n'
    )

def box(x, y, w, h, lines, fill="#ffffff", stroke="#3b6ea5", tcolor="#222222",
        font=13, title_bold=True, sw=1.5, r=9, title_fill=None):
    lh = font + 6
    total = lh * len(lines)
    ty = y + h / 2 - total / 2 + font * 0.38
    s = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>\n'
    for i, ln in enumerate(lines):
        size = font if i == 0 else font - 1
        fw = "bold" if (title_bold and i == 0) else "normal"
        tc = title_fill if (title_bold and i == 0 and title_fill) else tcolor
        s += (f'<text x="{x + w/2}" y="{ty + i*lh}" text-anchor="middle" font-size="{size}" '
              f'font-weight="{fw}" fill="{tc}">{esc(ln)}</text>\n')
    return s

def label(x, y, text, color="#5a5a5a", size=11, anchor="middle"):
    return (f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-size="{size}" fill="{color}" '
            f'paint-order="stroke" stroke="#ffffff" stroke-width="3">{esc(text)}</text>\n')

def arrow(x1, y1, x2, y2, text=None, color="#5a5a5a", double=False, dashed=False,
          tx=None, ty=None):
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    start = ' marker-start="url(#ah)"' if double else ""
    s = (f'<path d="M{x1},{y1} L{x2},{y2}" fill="none" stroke="{color}" stroke-width="1.6"'
         f'{dash} marker-end="url(#ah)"{start}/>\n')
    if text:
        tx = tx if tx is not None else (x1 + x2) / 2
        ty = ty if ty is not None else (y1 + y2) / 2 - 7
        s += label(tx, ty, text, color)
    return s

def curve(x1, y1, x2, y2, text=None, color="#5a5a5a", double=False, dashed=False,
          tx=None, ty=None, c1=None, c2=None):
    cx1, cy1 = c1 if c1 else (x1, (y1 + y2) / 2)
    cx2, cy2 = c2 if c2 else (x2, (y1 + y2) / 2)
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    start = ' marker-start="url(#ah)"' if double else ""
    s = (f'<path d="M{x1},{y1} C{cx1},{cy1} {cx2},{cy2} {x2},{y2}" fill="none" stroke="{color}" '
         f'stroke-width="1.6"{dash} marker-end="url(#ah)"{start}/>\n')
    if text:
        mx = (x1 + 3 * cx1 + 3 * cx2 + x2) / 8
        my = (y1 + 3 * cy1 + 3 * cy2 + y2) / 8
        tx = tx if tx is not None else mx
        ty = ty if ty is not None else my - 7
        s += label(tx, ty, text, color)
    return s

# =====================================================================
# 图一：分层架构图
# =====================================================================
W, H = 1500, 1140
svg = [header(W, H, "WhisperASR 软件架构原理图",
              "macOS 语音识别与字幕应用 · 五层结构（UI → 状态 → 服务 → 引擎 → 数据）")]

# ---- 层带 ----
svg.append(band(8, 70, 1484, 180, "UI 层 · SwiftUI 视图 + AppKit 窗口", "#eef5fc", "#3b6ea5"))
svg.append(band(8, 270, 1484, 215, "状态层 · @Observable 中央状态（UI 与服务桥梁）", "#fff7e6", "#c98a00"))
svg.append(band(8, 505, 1484, 280, "服务层 · 业务逻辑 / 编排", "#eefaf1", "#2e8b57"))
svg.append(band(8, 805, 1484, 125, "引擎层 · 推理后端（C 桥接 / 原生框架）", "#fdf0f9", "#a04a8a"))
svg.append(band(8, 950, 1484, 170, "数据层 · 持久化", "#f4f1fb", "#6b5ba8"))

# ---- UI 层 ----
svg.append(box(30, 115, 280, 75, ["WhisperASRApp  @main", "4 个 Scene · URL Scheme", "崩溃恢复 · 调试参数"]))
svg.append(box(330, 115, 280, 75, ["ContentView 主窗口", "Sidebar | Detail", "底部 PlayerView 播放条"]))
svg.append(box(630, 115, 230, 75, ["SettingsView", "7 分类设置中心", "(内嵌，非新窗口)"]))
svg.append(box(880, 115, 200, 75, ["MinutesWindowView", "会议纪要窗口"]))
svg.append(box(1100, 115, 370, 75, ["FloatingLetterViews 浮层视图", "容器 / 字幕层 / 工具栏", "/ 录制条"]))

# ---- 状态层 ----
svg.append(box(30, 330, 220, 75, ["SettingsManager", "设置数据中心", "5 组设置对象"]))
svg.append(box(270, 330, 250, 75, ["AudioRecorder", "SCStream 录制 · 写 m4a", "PCM 环形缓冲"]))
svg.append(box(540, 330, 200, 75, ["AudioPlayerManager", "AVPlayer 封装", "0.1s 周期观察"]))
svg.append(box(770, 310, 390, 150, ["AppState  全局状态中枢", "转写队列 · 实时转写主循环", "整句翻译队列(8并发/10s超时)", "健康检查 · 崩溃恢复 · Toast"],
               fill="#ffe9b8", stroke="#b26a00", font=14))
svg.append(box(1180, 310, 290, 75, ["FloatingLetterOverlayBinder", "桥接层:观察 AppState/录音", "150ms 节流 → ViewModel"]))
svg.append(box(1180, 405, 290, 75, ["FloatingLetterViewModel", "纯 UI 状态机(零业务依赖)", "断句 · 去重 · 闲置隐藏"]))

# ---- 服务层 ----
svg.append(box(30, 560, 330, 75, ["TranscriptionService 引擎门面", "文件转写 + 实时分块", "主/实时模型双上下文"]))
svg.append(box(390, 560, 330, 75, ["SubtitleEngine 字幕引擎", "生命周期 · 性能监控", "150ms UI 刷新调度"]))
svg.append(box(750, 560, 330, 75, ["TranslationService 翻译", "OpenAI 兼容 · 引擎工厂", "源语言检测 · 重试2次"]))
svg.append(box(1110, 560, 330, 75, ["MeetingMinutesService", "Map-Reduce 长文纪要", "MinutesPromptStore 模板"]))
svg.append(box(30, 660, 330, 75, ["APIServer 本地 HTTP 服务", "POST /v1/audio/transcriptions", "Bearer 鉴权 · Bonjour"]))
svg.append(box(390, 660, 330, 75, ["模型管理 ModelManager", "下载/断点续传 · 本地扫描", "LocalModelManager · GGUF 识别"]))
svg.append(box(750, 660, 330, 75, ["TranscriptionHistoryManager", "历史唯一出入口 · 500条", "TranscriptionStore JSON 落盘"]))
svg.append(box(1110, 660, 330, 75, ["Backup / LanguageDetector / AppLogger", "配置备份 · 字幕语言检测", "分类日志(1000条)+ErrorManager"]))

# ---- 引擎层 ----
svg.append(box(30, 850, 330, 75, ["CWhisper (whisper.cpp)", "C 桥接 · CPU/GPU 推理"]))
svg.append(box(390, 850, 330, 75, ["NemotronEngine", "FluidAudio · CoreML/ANE", "RNNT 时间戳 → 分段"]))
svg.append(box(750, 850, 330, 75, ["Qwen3ASRBackend", "CTranscribe · ggml+Metal", "无时间戳按句等分"]))
svg.append(box(1110, 850, 330, 75, ["GGUFInspector", "GGUF 头部解析", "引擎归属识别"]))

# ---- 数据层 ----
svg.append(box(30, 1005, 250, 75, ["UserDefaults", "设置/偏好 60+ 键"]))
svg.append(box(310, 1005, 260, 75, ["Transcriptions/<UUID>.json", "转录历史逐条落盘"]))
svg.append(box(600, 1005, 240, 75, ["Recordings/*.m4a", "录音 AAC 48kHz"]))
svg.append(box(870, 1005, 250, 75, ["Models/ 模型文件", ".bin/.gguf/目录包"]))
svg.append(box(1150, 1005, 320, 75, ["live_recovery.json", "实时转写崩溃恢复"]))

# ---- 箭头（全部走列间走廊，避免穿框）----
svg.append(arrow(310, 152, 330, 152))                                          # U1→U2
svg.append(curve(470, 190, 890, 310, "注入", c1=(470, 250), c2=(890, 250), tx=720, ty=240))
svg.append(curve(745, 190, 140, 330, "绑定", c1=(745, 255), c2=(140, 255), tx=442, ty=248))
svg.append(curve(980, 190, 1030, 310, c1=(980, 250), c2=(1030, 250)))          # U4→AppState
svg.append(curve(1285, 190, 1325, 310, "状态/动作", c1=(1285, 250), c2=(1325, 250), tx=1335, ty=240))
svg.append(arrow(1325, 405, 1325, 385, "双向", double=True, tx=1337, ty=398))   # ViewModel↔Binder
svg.append(arrow(1180, 347, 1160, 347, double=True))                           # Binder↔AppState
svg.append(curve(400, 330, 770, 322, "读取PCM/状态", double=True, c1=(400, 322), c2=(770, 322), tx=585, ty=312))
svg.append(curve(900, 460, 195, 565, "transcribe / transcribeChunk", c1=(900, 500), c2=(195, 500), tx=547, ty=495))
svg.append(curve(950, 460, 555, 565, "字幕生命周期", c1=(950, 500), c2=(555, 500), tx=790, ty=505))
svg.append(curve(1000, 460, 915, 565, "整句翻译请求", c1=(1000, 500), c2=(915, 500), tx=957, ty=495))
# AppState→HistoryManager：经 C 走廊(1080..1110)再折入 V7 顶部
svg.append(curve(1060, 460, 1095, 647, "保存/读取", c1=(1060, 530), c2=(1095, 530), tx=1077, ty=528))
svg.append(curve(1095, 647, 900, 662, c1=(1095, 653), c2=(900, 653)))
# AppState→live_recovery：走右边缘
svg.append(curve(1120, 460, 1478, 545, "崩溃恢复落盘(15s节流)", c1=(1120, 510), c2=(1478, 510), tx=1299, ty=500))
svg.append(arrow(1478, 545, 1478, 985))
svg.append(curve(1478, 985, 1310, 1007, c1=(1478, 995), c2=(1310, 995)))
# AudioRecorder→Recordings：经 B 走廊(720..750)
svg.append(curve(395, 405, 734, 430, "写 m4a", c1=(395, 415), c2=(734, 415), tx=750, ty=478))
svg.append(arrow(734, 430, 734, 990))
svg.append(curve(734, 990, 720, 1007, c1=(734, 998), c2=(720, 998)))
# 引擎扇出：主干经 A 走廊(360..390)，从 (375,830) 扇出到四引擎
svg.append(curve(362, 635, 375, 826, c1=(362, 730), c2=(375, 730)))            # 主干
svg.append(curve(375, 838, 195, 853, c1=(375, 846), c2=(195, 846)))            # →CWhisper
svg.append(curve(375, 834, 555, 853, c1=(375, 842), c2=(555, 842)))            # →Nemotron
svg.append(curve(375, 830, 755, 853, c1=(375, 838), c2=(755, 843)))            # →Qwen3
svg.append(curve(375, 826, 1275, 853, "GGUF 识别", c1=(375, 834), c2=(1275, 834), tx=825, ty=827))
# ModelManager→CWhisper
svg.append(curve(420, 735, 30, 744, c1=(420, 742), c2=(30, 742)))
svg.append(curve(30, 744, 30, 880, "模型路径/加载", c1=(30, 812), c2=(30, 884), tx=200, ty=756))
# HistoryManager→JSON：经 B 走廊
svg.append(curve(915, 735, 744, 770, c1=(915, 770), c2=(744, 770)))
svg.append(arrow(744, 770, 744, 988))
svg.append(curve(744, 988, 440, 1007, "<UUID>.json", c1=(744, 996), c2=(440, 996), tx=600, ty=988))
# SettingsManager→UserDefaults：走左边缘
svg.append(curve(30, 400, 10, 985, "读写设置", c1=(30, 700), c2=(10, 700), tx=45, ty=490))
svg.append(curve(10, 985, 155, 1007, c1=(10, 996), c2=(155, 996)))
# APIServer→TranscriptionService
svg.append(arrow(195, 660, 195, 635, "attach(service:)", tx=207, ty=650))
# SettingsManager→AppState：绕行 S2/S3 下方
svg.append(curve(140, 405, 770, 445, "attach(appState:)", c1=(140, 450), c2=(770, 450), tx=455, ty=465))

svg.append("</svg>\n")
with open(os.path.join(OUT, "architecture.svg"), "w") as f:
    f.write("".join(svg))

# =====================================================================
# 图二：核心数据流图
# =====================================================================
W2, H2 = 1500, 1060
svg = [header(W2, H2, "核心数据流 · 音频 → 转写 → 字幕 / 历史 / 外部接入",
              "① 采集 → ② 实时链路 → ③ 离线链路 → ④ 外部接入（虚线为间接/外部关联）")]

svg.append(band(8, 70, 1484, 225, "① 音频采集（录制链路）", "#eef5fc", "#3b6ea5"))
svg.append(band(8, 305, 1484, 260, "② 实时转写 → 字幕浮层（核心链路）", "#fff7e6", "#c98a00"))
svg.append(band(8, 575, 1484, 250, "③ 文件转录 → 历史（离线链路）", "#eefaf1", "#2e8b57"))
svg.append(band(8, 835, 1484, 200, "④ 外部接入 / 对外服务", "#f4f1fb", "#6b5ba8"))

# ① 采集（单行 + 底部旁路）
svg.append(box(30, 115, 260, 75, ["ScreenCaptureKit SCStream", "目标 App 音频", "(可选混入麦克风)"]))
svg.append(box(330, 115, 280, 75, ["AudioRecorder", "didOutputSampleBuffer", "48kHz CMSampleBuffer"]))
svg.append(box(650, 115, 260, 75, ["AVAssetWriter", "录制写盘 m4a", "(AAC 64kbps 48kHz)"]))
svg.append(box(950, 115, 230, 75, ["Recordings/*.m4a", "历史录音文件"]))
svg.append(box(1220, 115, 250, 75, ["PCM 环形缓冲", "16kHz 单声道 Float32", "getSamples(from:upTo:)"]))
svg.append(arrow(290, 152, 330, 152, "音频帧", ty=144))
svg.append(arrow(610, 152, 650, 152, "旁路录制", ty=144))
svg.append(arrow(910, 152, 950, 152))
svg.append(curve(470, 190, 1345, 192, "重采样 48k→16k", c1=(470, 195), c2=(1345, 195), tx=907, ty=212))
svg.append(curve(1345, 190, 150, 350, "PCM 分块", c1=(1345, 270), c2=(150, 270), tx=747, ty=262))

# ② 实时链路
svg.append(box(30, 350, 270, 90, ["AppState.startLiveTranscription", "实时主循环(Task)", "静音检测 · 尾部重转录", "1s overlap 去重 · sealed 封口"]))
svg.append(box(340, 350, 230, 90, ["TranscriptionService", "transcribeChunk(samples:)", "主/实时双上下文"]))
svg.append(box(610, 350, 330, 90, ["推理引擎路由", "whisper.cpp | Nemotron", "| Qwen3-ASR", "(GGUFInspector 判定)"]))
svg.append(box(980, 350, 260, 90, ["AppState.liveSegments", "环形 100 段", "15s 节流崩溃恢复落盘"]))
svg.append(box(30, 480, 290, 70, ["FloatingLetterOverlayBinder", "withObservationTracking 观察", "150ms 节流推送"]))
svg.append(box(360, 480, 290, 70, ["FloatingLetterViewModel", "断句 · 去重 · 渲染", "闲置 5s 自动隐藏"]))
svg.append(box(690, 480, 270, 70, ["NSPanel 置顶浮层", "字幕层显示(不抢焦点)", "拖动/缩放/鼠标穿透"]))
svg.append(box(1000, 480, 250, 70, ["TranslationService", "句尾整句翻译", "3s 超时回退原文"]))
svg.append(arrow(300, 395, 340, 395, "转写分块"))
svg.append(arrow(570, 395, 610, 395))
svg.append(arrow(940, 395, 980, 395, "分段结果", tx=950, ty=395))
svg.append(curve(1050, 440, 175, 480, c1=(1050, 460), c2=(175, 460)))
svg.append(arrow(320, 515, 360, 515))
svg.append(arrow(650, 515, 690, 515))
svg.append(arrow(1170, 440, 1125, 480))
svg.append(arrow(1000, 515, 960, 515, "回填", tx=996, ty=532))

# ③ 离线链路
svg.append(box(30, 620, 250, 85, ["拖放 / 文件选择器", "→ TranscriptionItem", "(status: .pending)"]))
svg.append(box(320, 620, 230, 85, ["AppState 转录队列", "逐个执行", "(Task.detached)"]))
svg.append(box(590, 620, 240, 85, ["AudioLoader", "AVFoundation → ffmpeg 兜底", "统一 16kHz Float32"]))
svg.append(box(870, 620, 250, 85, ["TranscriptionService", "transcribe(fileURL:)", "引擎路由(同上)"]))
svg.append(box(1160, 620, 280, 85, ["TranscriptionResult", "text · segments", "detectedLanguage"]))
svg.append(box(30, 745, 290, 70, ["TranscriptionHistoryManager", "保存 · 500条上限", "批量删除"]))
svg.append(box(360, 745, 270, 70, ["TranscriptionStore", "<UUID>.json 逐条", "录音路径自愈"]))
svg.append(box(670, 745, 280, 70, ["DetailView 展示", "播放联动高亮", "段内搜索"]))
svg.append(box(990, 745, 240, 70, ["导出 SRT/VTT/SUB/TXT", "字幕格式化"]))
svg.append(box(1270, 745, 200, 70, ["会议纪要入口", "MeetingMinutes"]))
svg.append(arrow(280, 662, 320, 662))
svg.append(curve(550, 705, 950, 703, "入队", c1=(550, 712), c2=(950, 712), tx=710, ty=726))
svg.append(arrow(830, 662, 870, 662, "解码"))
svg.append(arrow(1120, 662, 1160, 662, "结果"))
svg.append(curve(1220, 705, 175, 745, c1=(1220, 722), c2=(175, 722)))
svg.append(curve(1300, 705, 810, 745, c1=(1300, 730), c2=(810, 730)))
svg.append(curve(1350, 705, 1110, 745, c1=(1350, 736), c2=(1110, 736)))
svg.append(curve(1380, 705, 1370, 745, c1=(1380, 740), c2=(1370, 740)))
svg.append(arrow(290, 780, 360, 780))
svg.append(curve(1000, 620, 968, 340, "复用同一引擎路由", dashed=True, c1=(968, 480), c2=(968, 340), tx=925, ty=472))
svg.append(curve(968, 340, 790, 352, dashed=True, c1=(968, 341), c2=(790, 341)))

# ④ 外部
svg.append(box(30, 885, 310, 85, ["whisperasr://record?app=…", "URL Scheme → AppDelegate", "参数: live/mic/translate/pin"]))
svg.append(box(380, 885, 280, 85, ["FloatingLetterOverlayHost", "present / startRecordingFlow", "选择应用或直接录制"]))
svg.append(box(700, 885, 340, 85, ["APIServer (FlyingFox)", "POST /v1/audio/transcriptions", "Bearer 鉴权 · Bonjour · 多格式"]))
svg.append(box(1080, 885, 340, 85, ["OpenAI 兼容 API", "本地 LM Studio/Ollama 等", "或在线服务"]))
svg.append(arrow(340, 927, 380, 927))
# 启动录制：上→右边缘→折回 L1b
svg.append(curve(520, 885, 1490, 825, "启动录制", c1=(520, 845), c2=(1490, 845), tx=1462, ty=500))
svg.append(arrow(1490, 825, 1490, 210))
svg.append(curve(1490, 210, 470, 194, c1=(1490, 202), c2=(470, 197)))
# attach：上→左→绕行 corridor→折回 L2b
svg.append(curve(800, 885, 660, 820, c1=(800, 850), c2=(660, 820)))
svg.append(curve(660, 820, 660, 730, c1=(660, 775), c2=(660, 775)))
svg.append(curve(660, 730, 20, 730, c1=(660, 732), c2=(20, 732)))
svg.append(curve(20, 730, 20, 450, c1=(20, 600), c2=(20, 600)))
svg.append(curve(20, 450, 455, 442, "attach(service:) 复用", c1=(20, 446), c2=(455, 446), tx=237, ty=462))
# 翻译请求：右边缘
svg.append(curve(1250, 515, 1480, 545, "翻译请求", c1=(1250, 530), c2=(1480, 530), tx=1365, ty=516))
svg.append(arrow(1480, 545, 1480, 880))
svg.append(curve(1480, 880, 1250, 887, c1=(1480, 876), c2=(1250, 876)))
# 纪要请求：右边缘
svg.append(curve(1400, 815, 1462, 886, "纪要请求", c1=(1400, 850), c2=(1462, 850), tx=1448, ty=830))
svg.append(curve(1462, 886, 1420, 900, c1=(1462, 892), c2=(1420, 892)))

svg.append("</svg>\n")
with open(os.path.join(OUT, "dataflow.svg"), "w") as f:
    f.write("".join(svg))

print("done:", OUT)
