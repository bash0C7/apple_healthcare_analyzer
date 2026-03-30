# apple-health-export

Apple Health の `export.xml`（数GB）から健康指標を抽出・分析する Ruby ツール。

Claude Code の `/apple-health-analyze` コマンドで、Body Battery・トレンド分析・マルチホライズンフォーキャスト（1週〜6ヶ月）を日本語で自動レポートします。

## 機能

- **SAX パース** — 3GB超のXMLをメモリ展開せず逐次処理
- **10種の指標を抽出** — 歩数・体重・心拍・安静時心拍・消費カロリー・VO2Max・体脂肪・睡眠・HRV・呼吸数
- **期間・粒度フィルタ** — 日付範囲 & full/daily/weekly/monthly 集計
- **疑似 Body Battery** — HRV（55点）+ 安静時心拍（30点）+ 睡眠時呼吸数（15点）の3成分スコア
- **Claude Code スキル** — `/health` コマンドでサブエージェントが自動分析・レポート生成

## 必要環境

- Ruby 4.0.1+（`.ruby-version` 参照）
- Bundler

## セットアップ

```bash
git clone https://github.com/yourname/apple-health-export
cd apple-health-export
bundle install
```

Apple Health アプリでデータをエクスポートし、`export.xml` をプロジェクトルートに置く（`.gitignore` により追跡されません）。

## 使い方

### 1. CSV 抽出

```bash
# 全期間・全レコード（フル粒度）
bundle exec ruby scripts/extract.rb export.xml

# 期間指定
bundle exec ruby scripts/extract.rb export.xml 20260101 20260329

# 日次集計で出力
bundle exec ruby scripts/extract.rb export.xml 20260101 20260329 daily
```

`output/` ディレクトリに10本のCSVが生成されます（`StepCount.csv`, `HRV.csv` など）。

**集計ルール**

| 指標 | 集計 |
|------|------|
| StepCount, ActiveEnergyBurned | 合計 (sum) |
| BodyMass, HeartRate, RestingHeartRate, VO2Max, BodyFatPercentage, HRV, RespiratoryRate | 平均 (mean) |
| SleepAnalysis | 睡眠種別ごとの合計時間 |

### 2. JSON 分析

```bash
# デフォルト（直近90日）
bundle exec ruby scripts/analyze.rb

# 直近N日
bundle exec ruby scripts/analyze.rb 30

# 日付範囲
bundle exec ruby scripts/analyze.rb 20260101 20260329
```

標準出力にJSON（日次サマリー + 統計 + Body Battery）を出力します。

### 3. Claude Code でレポート生成

Claude Code を使っている場合、`/apple-health-analyze` スラッシュコマンドでサブエージェントが自動的に：

1. `analyze.rb` を実行してデータ取得
2. 健康状態サマリー・Body Battery推移・マルチホライズンフォーキャスト（1週〜6ヶ月）・アドバイスを日本語でレポート

```
/apple-health-analyze                      # 直近90日
/apple-health-analyze 30                   # 直近30日
/apple-health-analyze 20260101 20260329    # 日付範囲指定
```

## Body Battery 計算式

Garmin の Body Battery に着想を得た疑似スコア（0〜100）。

| 成分 | 配点 | 計算 |
|------|------|------|
| HRV (SDNN) | 55点 | `clamp(hrv / baseline_hrv_mean * 55, 0, 55)` |
| 安静時心拍 | 30点 | `clamp(30 - (rhr - baseline_rhr_p10) * 1.875, 0, 30)` |
| 睡眠時呼吸数 | 15点 | `clamp(15 - \|resp - 14.0\| * 2.25, 0, 15)` |

- `baseline_hrv_mean` — データセット全体のHRV平均
- `baseline_rhr_p10` — データセット全体のRHR 10パーセンタイル
- 呼吸数の最適値 — 14回/分（睡眠中）

スコア解釈: 80-100 = 優秀 / 60-79 = 良好 / 40-59 = 普通 / 40未満 = 要注意

## ファイル構成

```
.
├── scripts/
│   ├── extract.rb       # SAXパース & CSV抽出
│   ├── analyze.rb       # 日次集計・統計・Body Battery → JSON
│   └── gen_sample.rb    # テスト用サンプルXML生成
├── .claude/
│   ├── commands/
│   │   └── health.md    # /health スラッシュコマンド定義
│   ├── skills/
│   │   └── apple-health-analyze/SKILL.md  # 分析スキル定義
│   └── settings.json    # Claude Code 許可コマンド設定
├── docs/
│   └── superpowers/     # 設計スペック・実装プラン
├── Gemfile
└── CLAUDE.md
```

**コミットされないファイル**（`.gitignore`）: `export.xml`, `data/`, `output/`, `electrocardiograms/`, `workout-routes/`

## プライバシー

個人の健康データは一切リポジトリに含まれません。`export.xml` と `output/*.csv` は `.gitignore` で除外されています。

## ライセンス

MIT
