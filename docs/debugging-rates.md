# レート追従のデバッグ

## レートの調べ方

Music の `sample rate` は **再生中にしか埋まらない**(ライブラリ上は `missing value`)。
つまり曲ごとのレートは実際に鳴らして確かめるしかない。

```bash
osascript -e 'tell application "Music" to get {name of current track, sample rate of current track}'
```

これで 44.1k / 48k / 96k の曲を数曲ずつ控えておくと切り替えの検証が速い
(手元の表は `docs/rate-map.local.md` に置いてある — 個人の再生履歴なので追跡対象外)。

**同一アルバム内はレートが同じ**なので、アルバム内で曲送りしても切り替えは起きない。
アルバムをまたいで送ること。ハイレゾは Apple Music のカタログ側にあることが多く、
その曲はライブラリに無いためプレイリストには入れられない。

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

## プレイリストを作るのは諦めた

ライブラリの曲を1アルバム1曲ずつ実際に再生してレートを調べ、レートが隣り合わないよう
並べたプレイリストを自動生成する仕組みを一度作ったが、**ライブラリ側が 44.1 kHz に強く
偏っていて実用にならなかった**(24アルバム分を探索して 96 kHz は2枚だけだった)。
ハイレゾはカタログ側で聴いていることが多く、その曲は**ライブラリに無いのでプレイリスト
に入れられない**。上の実測表から手で選ぶほうが確実で早い。
