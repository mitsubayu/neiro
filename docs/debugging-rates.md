# レート追従のデバッグ

## 実測レート表

Music の `sample rate` は **再生中にしか埋まらない**(ライブラリ上は `missing value`)。
下表は実際に再生して neiro のログと DAC の実レートで確認した値。

| レート | 曲(すべて Apple Music ストリーミング) |
| --- | --- |
| 96 kHz | ヌエドリ / 恋夢 / 不安定な神様 / ユメカウツツカ / 天かける星 / 星降る空仰ぎ見て / I'm a beast / Fly away -大空へ- / 君の前では少年のまま (いずれも 2024 リマスターバージョン)、アンドロメダ、初恋・熱 (aiko) |
| 48 kHz | アイドル (アカペラアレンジver. / No Lead Vocal) / TREASURE / SINGING (アカペラアレンジver) / MY WAY / ガーネット (アカペラアレンジver.) / POPPIN' TIME / 愛くださいませ |
| 44.1 kHz | キミガタメ Re:boot / 残響散歌 / 好きすぎて滅! / AKB48 の各曲 |

**同一アルバム内はレートが同じ**なので、アルバム内で曲送りしても切り替えは起きない。
アルバムをまたいで送ること。

## 使い方

```bash
scripts/watch-rates.sh SMSL     # Music のデコーダ / neiro の判断 / DAC 実レートを並べて表示
```

切り替えが正しいときのログ:

```
muting head immediately (track start known) pending switch to 96000
evaluate: track=96000 engine=44100 → switchRestartingTrack
switching engine 44100 -> 96000 (restart=true)
```

このあと曲が**頭から**鳴れば正常。`head was muted but no switch followed` が出るのは
「頭をミュートしたのに切り替えが起きなかった」ケースで、頭出しを自動で復元している。

## テスト用プレイリスト

```bash
scripts/build-rate-test-playlist.sh 60
```

ライブラリの曲を1アルバム1曲ずつ実際に再生してレートを調べ(1曲あたり数秒、再生を
奪うので試聴中は不可)、レートが隣り合わないよう並べた `neiro rate test` を作る。
結果は `docs/rate-map.tsv`。

ライブラリ側は 44.1 kHz に強く偏っている(24アルバム探索で 96 kHz は aiko の2枚のみ)。
ハイレゾはカタログ側で聴いていることが多く、その曲は**ライブラリに無いのでプレイリスト
に入れられない**。手早く確認したいときは上の実測表の曲を手で並べるほうが早い。
