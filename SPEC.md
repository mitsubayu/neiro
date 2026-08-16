# neiro — 要件・開発仕様書

Apple Music (Music.app) の音声をフルレート(ビット・パーフェクト志向)で再生しつつ、
パラメトリック EQ をかける macOS メニューバー常駐アプリ。

- リポジトリ: `~/repos/neiro` / リモート: https://dev.azure.com/c-mitsuba/neiro
- バンドル ID: `com.mitsuba.neiro` / ログ subsystem: `com.mitsuba.neiro`
- 対象 OS: macOS 15.0+(Core Audio Process Tap API のため実質 14.2+ が下限。開発機は macOS 26)

---

## 1. 要件

### 1.1 機能要件

| # | 要件 | 実現方法 |
|---|------|----------|
| F1 | Music.app の音声に EQ をかけて任意の出力デバイスへ再生する | Core Audio Process Tap + 集約デバイス |
| F2 | 再生中も Music 本体からの二重再生が起きない | タップの `mutedWhenTapped` |
| F3 | 曲の native サンプルレート(44.1k/48k/96k…)に DAC を自動追従(レートフォロー) | Music のログ監視でソースレートを検出し、DAC レート変更+エンジン再構築 |
| F4 | レート切り替えで曲の頭が欠けたり二重に聞こえたりしない | 曲頭ミュート → 一時停止 → 切替 → 0:00 へ巻き戻し → 再開 |
| F5 | 曲の途中では絶対に音を中断しない | 再生位置 >5s の検出(次曲の先読み)は曲境界まで保留 |
| F6 | パラメトリック EQ(バンドごとに周波数/ゲイン/Q/種別) | RBJ biquad 自前実装、既定10バンド・最大16 |
| F7 | EQ プリセット(内蔵+ユーザー保存/上書き/削除、適用中プリセット名の表示) | UserDefaults 永続化。現在設定と完全一致する間は名前を太字表示 |
| F8 | 応答カーブの直接編集 | ドラッグ=ゲイン、⌥ドラッグ=周波数、Q はスライダー |
| F9 | メニューバーに曲名(長い場合はマーキー)+コーデック+レート/ビット深度表示 | AppKit NSStatusItem + Core Animation |
| F10 | パネルに再生中の曲情報(大きなジャケ写・曲名・アーティスト) | playerInfo 通知 + AppleScript でアートワーク取得 |
| F11 | 出力デバイス選択(既定=システムデフォルト追従)・抜去時フォールバック | デバイス列挙+ホットプラグ監視 |
| F12 | ログイン時自動起動(トグルで無効化可) | `SMAppService.mainApp` |
| F13 | ライト/ダークモード追従 | セマンティックカラー+外観変化時の再描画 |
| F14 | 設定の永続化 | UserDefaults に JSON(後方互換デコード) |
| F15 | 再生中に起動/有効化しても、その曲のレートに追従する | 起動時に `log show` で直近のフォーマットを復元(ストリームは過去を見ないため) |
| F16 | レート切替中であることが分かる | メニューバー `→ 44.1kHz` / パネル `Switching to 44.1kHz…`(橙) |
| F17 | EQ の即時バイパス(A/B 比較) | 処理だけを素通し。タップは保ったままなので瞬時 |
| F18 | 出力デバイスごとにプリセットを自動適用 | デバイス UID → プリセット名を保存し、出力切替時に適用 |
| F19 | 想定外のタップ形式で雑音を出さない | float32 インターリーブド以外は起動を拒否(Music は素の音で鳴る) |
| F20 | 検出が止まったら自己修復 | 曲開始から8秒検出なし → 検出プロセスを再起動(60秒に1回まで) |

### 1.2 非機能要件

- **CPU**: 定常時ほぼ 0%(Release ビルド)。リアルタイムスレッドではアロケーション・ロック・ObjC 呼び出し禁止
- **堅牢性**: Music 未起動/終了/再起動、デバイス抜去、レート変更、権限未付与のいずれでもクラッシュ・ハング・固着しない(タイムアウトとウォッチドッグで自己回復)
- **副作用の禁止**: Music を終了させたら neiro が勝手に再起動させない。neiro 終了時は必ずタップを破棄し Music のミュートを解除する

### 1.3 スコープ外(現状の既知の限界)

- EQ バンドが有効な間は厳密なビット・パーフェクトではない(レートはフル維持、信号は 32bit float 処理)
- ソースが AAC(ロッシー)の場合、ビット深度は表示しない(float デコードのため)
- レート切り替え時、曲頭に約 2.5 秒の無音がある(検出ラグ+デバウンス+再構築)
- 対象は Music.app のみ(他アプリの音声は対象外)

---

## 2. アーキテクチャ

```
Music.app ──(Process Tap: mutedWhenTapped)──▶ 集約デバイス ──▶ IOProc(HAL RTスレッド)
                                                │                  │ プリゲイン → biquad×N
   ログ(log stream)──▶ TrackRateDetector        │                  ▼
   playerInfo 通知 ──▶ Now Playing              └──────────▶ 出力デバイス(SMSL 等)
   AppleScript(osascript, 3s timeout)──▶ 一時停止/再開/位置/アートワーク
```

### 2.1 音声パイプライン(ProcessTapEngine)

1. `NSRunningApplication` で Music の pid → `kAudioHardwarePropertyTranslatePIDToProcessObject`
2. `CATapDescription(stereoMixdownOfProcesses:)` + `muteBehavior = .mutedWhenTapped` + `isPrivate` → `AudioHardwareCreateProcessTap`
3. 集約デバイス作成: タップ(`kAudioSubTapDriftCompensationKey: true`)+出力デバイス(クロックマスター)。UID は固定 `com.mitsuba.neiro.aggregate`(デバイス列挙から除外するため)
4. `AudioDeviceCreateIOProcIDWithBlock`(queue=nil = HAL リアルタイムスレッド直行)
5. IOProc: タップ入力 → `EQProcessor.process`(in-place)→ 出力バッファへコピー
6. teardown は生成の厳密な逆順・冪等

**教訓(再発防止)**: エンジン再構築をデバイス一覧リスナーから無条件に行うと、
自分の集約デバイス作成がリスナーを発火させて無限再起動ループになる(「ぶるぶる」音)。
解決したい出力先が現在と異なる時だけ再構築する。

### 2.2 EQ DSP

- `BiquadKernel`: RBJ cookbook(peak / lowShelf / highShelf)、TDF-II、Nyquist クランプ、応答計算(UI 共用)
- `EQProcessor`: ダブルバンク係数+アトミックなバンク切替でロックフリー公開。プリゲイン、
  レート切替時の曲頭ミュート用フラグ(atomic)。書き込み側は NSLock で直列化
- 既定バンド: 31.5(LS), 63〜8k(peak), 16k(HS)
- バイパス: `bypassFlag`(atomic)を見て**1サンプルも触らず**即 return。タップは保つので
  切り替えは瞬時(有効トグルはタップごと破棄するため1〜2秒かかる)
- タップ形式の検証: linear PCM / float / インターリーブド / 32bit 以外は起動を拒否。
  IO ブロックは float32 インターリーブド決め打ちのため、想定外の形式は雑音になる

### 2.3 レートフォロー(TrackRateDetector + AppState)

- 検出: `/usr/bin/log stream` を子プロセスで起動し Music のログを監視
  - `Creating AudioQueue with format:'qlac', … sampleRate:96000` → ソースレート+コーデック fourcc
  - デコーダ `Output format: … 24-bit …integer` / `… Int16` / float → ビット深度(float は nil)
  - コーデック表示名: `*lac`→ALAC, `*aac*`→AAC, ほか fourcc 大文字
- 復元: `log stream` は**起動後の行しか見えない**ため、起動/有効化時に一度だけ
  `log show --last 120s` で直近のレート・コーデック・ビット深度を復元する
- 健全性: 曲が始まった(playerInfo)のに8秒たっても検出が来なければストリームが死んでいると判断し、
  検出プロセスを再起動(復元も走るので現在の曲のレートも即座に戻る)。連発防止に60秒のクールダウン
- 判断: 検出は 1.2s デバウンス(Music は曲境界で複数レートのキューを作るため)。
  判断そのものは純粋関数 `RateSwitchPolicy`(下表)に切り出してテストで固定。
  実行中フラグには 20s ウォッチドッグ(完了時にキャンセル)

| 状況 | 判断 | 動作 |
|---|---|---|
| レート一致 / 無効 / エンジン停止 | `idle` | ミュート解除のみ |
| 切替実行中 | `waitForInFlightSwitch` | 完了後に再評価 |
| レート未知のまま組んだエンジン(起動直後) | `switchKeepingPosition` | 再構築のみ。**曲は止めない** |
| 曲頭が確定(playerInfo) | `switchRestartingTrack` | 一時停止 → 再構築 → 0:00 → 再開 |
| 判断材料不足 | `queryPlayer` | Music に状態/位置を問い合わせて再判断 |
| 再生位置 >5s(次曲の先読み) | `deferToTrackBoundary` | 2s 後に再評価。現在の曲は無傷 |

- 曲頭の判定: `playerInfo` 通知(タイトル変化 or 停止→Playing 遷移)の時刻を記録し、
  6秒以内なら「曲頭で再生中」と**AppleScript なしで**確定できる(`isAtKnownTrackHead`)
- 切替シーケンス(F4/F5):
  1. 別レート検出 → **同期的に即ミュート**(曲頭が確定している場合)。
     確定できない場合のみ従来どおり再生位置を問い合わせてから判断
  2. 1.2s デバウンス後、Music を一時停止(曲頭確定なら状態・位置の問い合わせを省略)
  3. エンジン再構築(`preferredRate` で DAC レートを明示設定)
  4. 0:00 へシーク → 再生再開 → **再開できたか確認し、失敗なら最大3回再試行** → ミュート解除
  - 再生中でない場合は transport 操作なしの「静かな切替」に降格
  - 位置 >5s は次曲の先読みとみなし保留(2s 後に再評価)
  - 実測: 検出 → ミュート 0秒、検出 → 新レートで再生開始まで約2.4秒

**教訓**: AppleScript は相手アプリを自動起動する(Music 終了後の呼び出しで復活してしまう)
→ Music 起動チェックを共通入口に。未応答の Automation 許可ダイアログで osascript が永久ブロック
→ 全呼び出しに 3s ハードタイムアウト、nil は「Music 不達」として degrade。

### 2.4 メニューバー UI(StatusItemController)

**プラットフォーム制約(この構成で実測)**:

| やりたいこと | 使えない手段 | 理由 |
|---|---|---|
| ラベルのアニメーション | MenuBarExtra + TimelineView | 毎フレーム status item 再レイアウト → メインスレッド飽和(CPU 136%) |
| ラベルに動的カスタムビュー | MenuBarExtra + NSViewRepresentable | 初回スナップショットで固定(幅・アニメが更新されない) |
| パネル表示 | NSPopover | macOS 26 + LSUIElement + SwiftUI ライフサイクルで `show` が黙って失敗 |

**採用構成**: 純 AppKit
- `NSStatusItem` + ボタン subview の `StatusMarqueeView`(クリックは `hitTest → nil` で透過。
  ⚠ button とサイズ連動の制約を張るとボタンが高さ 2px に潰れクリック不能になる — 固定サイズ制約のみ使う)
- マーキー: 文字列を AppKit で NSImage に描画(CATextLayer の素の描画はぼやける)→ CALayer contents を
  `CAKeyframeAnimation` でスクロール(GPU 合成・CPU 0)
  - サイクル: 先頭 2s 静止 → 30pt/s でスクロール → 末尾 1s 静止 → 逆戻りせず前進ループ
    (タイトル2枚+24pt 隙間の連結でラップが継ぎ目なし)
  - タイトル欄: マーキーが必要な長さなら固定 110pt、短ければ文字幅ぴったり
  - Retina: `contentsScale` を window の backingScaleFactor に追従。座標は整数ピクセルに丸め
  - コーデック表示も同じレンダラ・同じ高さの箱で描き、ベースラインを一致させる
- パネル: 自前の `KeyablePanel`(borderless, nonactivating, `canBecomeKey = true`)を
  ステータスアイテム直下に配置。グローバルクリックモニタで外側クリック時に閉じる
- 状態同期: `withObservationTracking` を再帰的に張り直す(AppKit 版の @Observable 購読)

### 2.5 パネル UI(SwiftUI / MenuBarRootView)

上から: 有効トグル+ステータス(`Running · ALAC 44.1kHz/16bit`)/ ジャケ写(352pt 固定・
非圧縮、下部グラデに曲名・アーティスト重ね)/ 出力ピッカー / レートフォロートグル /
プリセットメニュー(適用中は名前を太字表示、デバイスへの自動適用の紐づけ)+ Bypass ボタン /
応答カーブ(高さ150、ハンドルドラッグ編集、周波数・dB 目盛り、バイパス時は減光+"BYPASSED")/
プリゲイン / バンド一覧(行全体クリックで開閉する DisclosureGroup、既定閉)/
Reset EQ・Launch at login・Quit

⚠ ポップオーバー内容が最大高さを超えると可変サイズのビュー(ジャケ写)が圧縮される —
固定 frame + 折りたたみで回避。

### 2.6 Now Playing

- 曲名/アーティスト: `com.apple.Music.playerInfo` 分散通知(+ AppleScript フォールバック)。400ms デバウンス
- アートワーク: AppleScript で `raw data of artwork 1` を一時ファイルへ書き出し → NSImage
- Music 終了時は表示・コーデック・ビット深度をすべてクリア

---

## 3. モジュール構成

```
project.yml                     XcodeGen 定義(Info.plist キー・署名・sandbox無効)
neiro/
  App/NeiroApp.swift            @main(Settings 空シーン)+ AppDelegate(AppState/StatusItemController 生成、終了時 teardown)
  App/AppState.swift            @MainActor @Observable 中枢: 設定・エンジン制御・レートフォロー判断・Now Playing・プリセット・ログイン項目
  Audio/CoreAudioUtils.swift    AudioObject プロパティ/リスナーのラッパ、集約デバイス UID 定数
  Audio/MusicProcessLocator.swift  Music の audio process object 解決
  Audio/OutputDeviceMonitor.swift  出力デバイス列挙・ホットプラグ監視(自前集約は除外)
  Audio/ProcessTapEngine.swift  タップ+集約+IOProc のライフサイクル、レートマッチング、診断ログ
  Audio/TrackRateDetector.swift log stream 子プロセス、レート/コーデック/ビット深度のパース
  Audio/MusicRemote.swift       osascript ラッパ(3s timeout、Music 起動ガード)
  Audio/RateSwitchPolicy.swift  切替判断の純粋関数(状況 → 動作)。UI/IO を持たずテスト可能
  DSP/EQModel.swift             EQBand / EQSettings(Codable、後方互換デコード)
  DSP/BiquadKernel.swift        RBJ 係数+TDF-II 状態+応答計算
  DSP/EQProcessor.swift         RT安全なカスケード適用、ロックフリー係数公開、ミュート
  DSP/EQPreset.swift            プリセットモデル・内蔵6種・PresetStore
  Persistence/SettingsStore.swift  UserDefaults JSON (eqSettings.v1)
  UI/StatusItemController.swift ステータスアイテム+マーキー+自前パネル
  UI/MenuBarRootView.swift      パネル本体
  UI/OutputDevicePicker.swift / EQBandRow.swift / ResponseCurveView.swift
  AppIcon.icns / IconGlyph.svg  アイコン(ユーザー作の筆記体 n SVG を白ティント+グラデ squircle)
neiroTests/BiquadTests.swift    21件: biquad 精度/安定性、パース(レート・コーデック・Output format)、設定互換、マーキー幅ルール、プリセット、切替ポリシー、タップ形式検証、バイパス
```

---

## 4. ビルド・開発

```bash
xcodegen generate                                  # ソース追加時は必ず再実行
xcodebuild -project neiro.xcodeproj -scheme neiro -configuration Release -derivedDataPath build build
open build/Build/Products/Release/neiro.app
xcodebuild -project neiro.xcodeproj -scheme neiro -configuration Debug -derivedDataPath build test
```

- **日常利用は必ず Release**。Debug は最適化なしの DSP がリアルタイムスレッドで CPU ~37% 食う
- 署名: Apple Development(Personal Team 7N7LUCUW5K)自動署名 — TCC 許可がリビルド後も持続
- App Sandbox は無効必須(Process Tap に公開 entitlement がない)。Hardened Runtime も無効
- 必要な TCC(初回にダイアログ): システムオーディオ録音(`NSAudioCaptureUsageDescription`)、
  Music の制御(`NSAppleEventsUsageDescription`)
- ログ確認: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.mitsuba.neiro"'`
  (`log` はフルパス必須 — ユーザーの zsh に同名関数がある)

## 5. 検証手順(主要シナリオ)

1. 再生開始 → ステータス `Running · <codec> <rate>/<bit>`、二重再生なし
2. 44.1k ⇄ 96k の曲を跨ぐ → 曲頭で短い無音の後、頭から正しいレートで1回だけ再生。
   DAC のレート実測(Audio MIDI 設定)も追従
3. 同レートの曲の連続 → 無音・途切れなし
4. EQ ハンドルをドラッグ → 音が即応、ノイズなし。プリセット適用/保存/上書き
5. Music を終了 → neiro は待機表示・表示クリア・Music は再起動しない。再度開くと自動復帰
6. デバイス抜去 → デフォルト出力へフォールバック
7. neiro 終了 → Music のミュートが解除されている
8. `xcodebuild test` 12件グリーン

## 6. 今後の候補

- AutoEQ プロファイルのインポート(ユーザー判断で見送り中)
- レート切替の無音短縮(検出の前倒し・デバウンス適応化)
- 曲頭以外で有効化した場合の即時レート合わせ
- Music 以外のソース(任意アプリ)対応
