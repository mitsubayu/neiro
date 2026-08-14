# 開発ナレッジ集 — neiro で踏んだ地雷と学び

次のプロジェクト(または将来の自分)のための記録。
「症状 → 真因 → 対策」の形で、実際にハマった順ではなくドメイン別に整理。

---

## 1. Core Audio / Process Tap

### 1.1 【アンチパターン】デバイス変化リスナーからエンジンを無条件再構築する
- **症状**: 音が周期的に途切れて「ぶるぶる」震える。UI のデバイス一覧に自分の集約デバイスが点滅する
- **真因**: エンジン構築で集約デバイスを作る → `kAudioHardwarePropertyDevices` リスナーが発火 →
  再構築 → また発火 → **50ms 周期の無限再起動ループ**
- **対策**: 「解決した出力先が現在使用中の UID と異なる時だけ」再構築する。
  自前の集約デバイスは固定 UID にしてデバイス列挙から除外する
  (`kAudioAggregateDeviceIsPrivateKey: true` でも**作成したプロセス自身からは見える**)

### 1.2 タップが受け取るのは「曲のレート」ではなく「Music の出力デバイスのレート」
- Music.app は自分の出力デバイスのレートでレンダリングする。96kHz の曲でも DAC が 48k なら
  タップには 48k で届く。曲の native レート再生には **DAC のレートを先に変えて Music に
  AudioQueue を作り直させる**必要がある(Music はデバイスレート変更で自動的に再初期化する)
- `CATapDescription` の Swift API は `[AudioObjectID]` を直接受け取る(ObjC の
  `[NSNumber]` と違う。NS_REFINED_FOR_SWIFT)
- 集約デバイスのタップエントリのドリフト補正キーは `kAudioSubTapDriftCompensationKey`
  (サブデバイス用の `kAudioSubDeviceDriftCompensationKey` とは別物)

### 1.3 【重要】Debug ビルドのリアルタイム DSP は CPU を数十%食う
- **症状**: アプリが定常的に CPU 35〜40%。UI のバグに見える(実際 UI を疑って遠回りした)
- **真因**: `-Onone` の Swift per-sample ループ(biquad×10バンド)が HAL の RT スレッドで動く
- **対策**: **日常利用・性能測定は必ず Release ビルド**(→ 0%)。
  `sample` でプロファイルする時は top-of-stack でなく call graph を見る。
  **PID を確認してからサンプルする**(再起動後に古いプロセスを測って誤診した)

### 1.4 IOProc の基本
- `AudioDeviceCreateIOProcIDWithBlock` の queue に **nil** を渡すと HAL のリアルタイム
  スレッド直行(playthrough はこれ)。ブロック内ではアロケーション・ロック・ObjC・os_log 禁止
- 係数の受け渡しはダブルバンク+アトミックなインデックス切替(ロックフリー)

## 2. Music.app 連携

### 2.1 曲のソースフォーマットは unified log から取る(唯一の情報源)
```
process == "Music" AND eventMessage CONTAINS "Creating AudioQueue with format"
→ format:'qlac', sampleRate:96000        (コーデック fourcc + レート)
Output format:  2 ch,  96000 Hz, lpcm ... 24-bit ... signed integer   (ビット深度)
Output format:  2 ch,  44100 Hz, Int16, interleaved                   (CD品質は別書式!)
AAC は float 出力 → ビット深度の概念なし
```
- `/usr/bin/log stream --style ndjson` を子プロセスで起動して購読
- **書式は複数ある**。1パターンだけ対応すると CD 品質の曲で欠落する

### 2.2 Music は曲境界で複数レートのキューを先読み生成する
- **症状**: 切替が発振する/追従しそこねる(44100→96000→44100 が3秒内に混在)
- **対策**: 検出を**デバウンス**(1.2s 静定した最後の値を採用)。
  再生位置 >5s での異レート検出は「次曲の先読み」なので**曲境界まで保留**

### 2.3 【アンチパターン】AppleScript を無条件に送る
- **症状①**: Music を終了させたのに勝手に再起動する
  - **真因**: `tell application "Music"` は**相手が起動していなければ自動起動させる**。
    終了通知を受けた後の「再生情報更新」が Music を蘇らせていた
  - **対策**: 全 AppleScript 呼び出しの共通入口で `NSRunningApplication` チェック
- **症状②**: 機能が全部無言で止まる(切替が二度と走らない)
  - **真因**: Automation の TCC ダイアログが未回答だと **osascript は無期限ブロック**。
    await している Task が永久に完了せず、「実行中」フラグが立ちっぱなしになる
  - **対策**: osascript に**ハードタイムアウト(3s)**。nil は「Music 不達」として
    transport 操作なしの degrade パスへ。さらに実行中フラグには**ウォッチドッグ(10s)**
- **教訓**: ガード付き早期 return が多い状態機械は「なぜ動かないか」がログに出ない。
  **判断の入力値と棄却理由をログに出す**(`evaluate: track=X engine=Y switching=Z`)

### 2.4 その他
- 曲名/アーティストは `com.apple.Music.playerInfo` 分散通知が最軽量
- アートワークは AppleScript で `raw data of artwork 1 of current track` をファイルに書かせる
  (ストリーミング曲でも取れる)
- Music.app 自体が Apple Events 不応答(-1712)でハングすることがある(テストで乱暴に
  kill した後など)。`pkill -9 Music` で復旧

## 3. メニューバー UI(最大の地雷原)

macOS のメニューバー(NSStatusItem / MenuBarExtra)は普通の view と別世界。
**この構成で実測した不可能リスト**:

| やりたいこと | ダメだった手段 | 何が起きたか |
|---|---|---|
| ラベルをアニメーション | MenuBarExtra + TimelineView(30fps) | 毎フレーム status item 再レイアウト → **メインスレッド飽和(CPU136%)、パネルも死ぬ** |
| ラベルに動的カスタムビュー | MenuBarExtra + NSViewRepresentable | **初回スナップショットで凍結**(updateNSView しても幅・内容が反映されない) |
| パネル表示 | NSPopover.show(from status item) | **無言で失敗**(クリック到達・show 呼出まで確認できても isShown=false のまま。macOS 26 + LSUIElement + SwiftUI ライフサイクル) |

**動いた構成**: 純 AppKit — NSStatusItem + カスタム view + CAKeyframeAnimation(GPU合成で CPU 0)
+ 自前の borderless NSPanel(`canBecomeKey` override + グローバルクリックモニタで transient 動作)。

### 3.1 【アンチパターン】status ボタンとサイズ連動の Auto Layout 制約を張る
- **症状**: メニューバーアイコンをクリックしても無反応(何日も悩む系)
- **真因**: `subview.heightAnchor == button.heightAnchor` の制約が**ボタン自身を高さ2ptに
  押し潰していた**。クリック可能領域が 2px しかなく人間には当たらない
- **対策**: サブビューは**固定サイズ制約のみ**。位置(leading/centerY)は良いがサイズ連動は禁止
- **検出法**: アクセシビリティでアイテムの実 frame を読む
  (`System Events → position/size of menu bar item`)— 目視で見えない退化ジオメトリが分かる

### 3.2 【重要な罠】アクセシビリティのクリックはヒットテストを迂回する
- `System Events` の `click menu bar item`(AXPress)は**通る**のに、実マウスクリックは
  view に吸われて**通らない**ことがある(hitTest override 漏れ)
- **対策**: 検証は `click at {x, y}`(座標クリック=実イベント経路)で行う。
  オーバーレイ view には `hitTest → nil` を忘れない

### 3.3 テキスト描画
- **NSTextField を手動レイアウトするなら autoresizingMask = []**。デフォルトの autoresizing が
  親(クリップ)のリサイズ時にラベル幅を巻き添えにし、マーキー用の連結文字列が切り詰められた
  (「最初に見えていた分しか描かれない」— レイアウト後に frame を読み直すのも罠。
  計測値は自前のプロパティに保持する)
- **CATextLayer は 2 つの罠**: ① `contentsScale` デフォルト1(Retinaでぼやける。
  `viewDidMoveToWindow`/`viewDidChangeBackingProperties` で backingScaleFactor を追従)
  ② スケールを直しても**素の描画品質が AppKit より甘い** → 文字は AppKit で NSImage に
  描画してレイヤー contents としてスクロールするのが正解
- 座標は整数ピクセルに丸める(0.5pt ずれで滲む)。並ぶテキストは**同じレンダラ・同じ高さの
  箱**で描くとベースラインが揃う
- マーキーのシームレスループ: 「本体+隙間+本体」の連結を `-loopWidth` までスクロールすると
  ラップ位置のピクセルが一致して切れ目が見えない。keyTimes で先頭/末尾の静止を作る

## 4. 権限・署名・環境

- **ad-hoc 署名は TCC 許可がリビルド毎にリセット**される(コードハッシュがキー)。
  無料の Apple Development 証明書(Personal Team)+ automatic signing にすれば持続する
- **バンドル ID を変えると** TCC(録音・Automation)と UserDefaults が全部リセット。
  設定は `defaults export/import` で移行できる
- App Sandbox は Process Tap と両立しない(公開 entitlement なし)→ 無効必須
- ユーザーの zsh に `log` 関数があり `/usr/bin/log` を隠していた → **診断系コマンドは
  フルパスで叩く**。また `Logger` の .info レベルは後から `log show` で読めないことがある
  → 必ず読み返したい診断は .error/.default で出す
- `screencapture` は Screen Recording 権限がないと "could not create image" で失敗する

## 5. 目視できない環境での UI 検証テク

1. **描画結果をファイルに出して自分で見る**: NSImage(drawingHandler) → bitmap context に
   描いて PNG 化はオフスクリーンでも動く(アイコン・文字画像の検証に使えた)
2. ただし **NSView/CALayer ツリーのオフスクリーンレンダリングは大抵白紙**になる
   (ウィンドウ表示・レンダーサーバー接続が要る)。cacheDisplay も layer.render(in:) も
   サブレイヤーの contents までは拾えないことが多い — 深追いしない
3. **ジオメトリはアクセシビリティで数値検証**(要 accessibility 権限):
   アイテムの存在・位置・サイズ、座標クリック、ウィンドウ数のカウント
4. アニメーション類は**数値仕様をユニットテストに固定**(幅ルール、キーフレーム値)して、
   見た目の最終確認だけ人間に頼む
5. **「修正した」と言う前に自分の目か数値で確かめる**。見えないまま出荷して手戻りしたのが
   このプロジェクト最大の時間損失

## 6. Azure DevOps 小ネタ

- git の SSH ホストは `ssh.dev.azure.com`。`~/.ssh/config` の `Host dev.azure.com` エントリ
  とは**別エントリが必要**(ここが一致せず既存鍵が使われていなかった)
- org 設定によっては **ssh-rsa 鍵しか受け付けない**(ed25519 が「Invalid key」で弾かれる)
- MSA(個人アカウント)所有の org は `az devops` の AAD トークンが通らないことがある
  → PAT か Web UI。新規 org はホストランナーの**無料並列枠を申請制**で有効化する必要あり
  (https://aka.ms/azpipelines-parallelism-request)
- 「空のリポジトリ」でも README 初期コミットが入っていることがある → rebase してから push

## 7. プロセス面の教訓

- **見た目に関わる変更はモックを先に見せて合意してから適用する**(アイコンで学んだ)
- ユーザーの違和感報告(「幅が親に引きずられてるんじゃ?」)は**大抵正しい**。
  仮説として最優先で検証する
- 大きな UI フレームワーク切替(SwiftUI⇄AppKit)を焦って往復しない。
  「その構成で何が不可能か」のリスト(上表)を先に作れば1往復で済んだ
- 検証手段(アクセシビリティ権限・座標クリック・PNG 書き出し)は**先に**整備すると
  トータルで速い
