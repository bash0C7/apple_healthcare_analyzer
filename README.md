# apple-health-export

Apple Health の `export.xml`（数GB規模）から健康指標を抽出・分析する Ruby ツール。

Claude Code の `/apple-health-analyze` コマンドで、身体スコアリング・トレンド分析・マルチホライズンフォーキャスト（1週〜6ヶ月）を日本語で自動レポートします。

## 機能

- **SAX パース** — 大容量XMLをメモリ展開せず逐次処理
- **10種の指標を抽出** — 歩数・体重・心拍・安静時心拍・消費カロリー・VO2Max・体脂肪・睡眠・HRV・呼吸数
- **期間・粒度フィルタ** — 日付範囲 & full/daily/weekly/monthly 集計
- **身体スコアリング** — HRV（55点）+ 安静時心拍（30点）+ 睡眠時呼吸数（15点）の3成分スコア
- **Claude Code スキル** — `/apple-health-analyze` コマンドでサブエージェントが自動分析・レポート生成

## 必要環境

- Ruby 4.0.1+（`.ruby-version` 参照）
- Bundler

## セットアップ

```bash
git clone https://github.com/yourname/apple-health-export
cd apple-health-export
bundle install
```

### Apple Health データの配置

**1. iOS でエクスポート**

1. iPhone の「ヘルスケア」アプリを開く
2. 右上のプロフィールアイコン → 「すべてのヘルスケアデータを書き出す」
3. しばらく待つと ZIP ファイルが生成される（数GBになることがある）
4. 「書き出す」→ AirDrop や「ファイル」アプリ経由で Mac に転送

**2. Mac で展開**

ZIP ファイルをダブルクリックして展開すると、以下の構成のフォルダが生成される：

```
apple_health_export/
├── export.xml          ← これが対象
├── export_cda.xml
├── electrocardiograms/
└── workout-routes/
```

**3. プロジェクトルートに配置**

```bash
cp /path/to/apple_health_export/export.xml /path/to/this/repo/export.xml
```

または展開先フォルダがこのリポジトリと同じ場所にある場合：

```bash
cp ../apple_health_export/export.xml ./export.xml
```

`export.xml` はプロジェクトルート直下に置く（`.gitignore` により追跡されません）。

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

標準出力にJSON（日次サマリー + 統計 + 身体スコアリング）を出力します。

### 3. Claude Code でレポート生成

Claude Code を使っている場合、`/apple-health-analyze` スラッシュコマンドでサブエージェントが自動的に：

1. `analyze.rb` を実行してデータ取得
2. 健康状態サマリー・身体スコア推移・マルチホライズンフォーキャスト（1週〜6ヶ月）・アドバイスを日本語でレポート

```
/apple-health-analyze                      # 直近90日
/apple-health-analyze 30                   # 直近30日
/apple-health-analyze 20260101 20260329    # 日付範囲指定
```

## 身体スコアリング計算式

HRV・安静時心拍・睡眠時呼吸数から算出する0〜100の総合スコア。

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
│   ├── analyze.rb       # 日次集計・統計・身体スコアリング → JSON
│   └── gen_sample.rb    # テスト用サンプルXML生成
├── .claude/
│   ├── commands/
│   │   └── apple-health-analyze.md  # /apple-health-analyze コマンド定義
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
