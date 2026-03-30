# Apple Health Extract — Design Spec
Date: 2026-03-30

## 概要

Apple Health の `export.xml`（3GB）から8種類の指標を抽出・集約し、CSVに書き出すRubyツール。
ox gem の SAX パーサで逐次処理することでメモリを一定に保つ。
期間フィルタとサンプリング粒度を引数で指定でき、長期間は月単位、短期間はフル分析など柔軟な使い方が可能。

---

## ディレクトリ構成

```
apple_health_export/
├── CLAUDE.md
├── Gemfile                        # ox gem
├── Gemfile.lock
├── data/
│   └── sample.xml                 # export.xml から各型10件ずつ抽出したテスト用
├── scripts/
│   ├── extract.rb                 # メイン抽出スクリプト
│   ├── gen_sample.rb              # sample.xml 生成スクリプト
│   └── analyze.rb                 # 分析スクリプト（スタブ）
├── output/
│   ├── StepCount.csv
│   ├── BodyMass.csv
│   ├── HeartRate.csv
│   ├── RestingHeartRate.csv
│   ├── ActiveEnergyBurned.csv
│   ├── VO2Max.csv
│   ├── BodyFatPercentage.csv
│   └── SleepAnalysis.csv
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-30-apple-health-extract-design.md
```

---

## 実行インターフェース

```bash
# 引数: xml_path [from_yyyymmdd to_yyyymmdd [grain]]
# grain: full | daily | weekly | monthly  (デフォルト: full)

ruby scripts/extract.rb export.xml
ruby scripts/extract.rb export.xml 20240101 20241231
ruby scripts/extract.rb export.xml 20240101 20241231 monthly
```

- `from` / `to` は両方指定するか両方省略（片方だけは不可）
- 期間省略時は全件対象
- 粒度省略時は `full`（集約なし、全レコードをそのまま出力）

---

## CSVフォーマット

全指標共通のヘッダ:

```
creationDate,startDate,endDate,value,unit,sourceName
```

- `full` 粒度: 1レコード1行、属性値そのまま
- `daily/weekly/monthly` 粒度: 集約後の代表日時 + 集約値

集約時の `creationDate` / `endDate` は期間の最終レコードの値を使用。
`sourceName` は集約時は `aggregated` とする。

---

## 抽出対象指標と集約ルール

| CSVファイル | HK識別子 | 集約方法 |
|------------|---------|---------|
| StepCount.csv | HKQuantityTypeIdentifierStepCount | sum |
| BodyMass.csv | HKQuantityTypeIdentifierBodyMass | mean |
| HeartRate.csv | HKQuantityTypeIdentifierHeartRate | mean |
| RestingHeartRate.csv | HKQuantityTypeIdentifierRestingHeartRate | mean |
| ActiveEnergyBurned.csv | HKQuantityTypeIdentifierActiveEnergyBurned | sum |
| VO2Max.csv | HKQuantityTypeIdentifierVO2Max | mean |
| BodyFatPercentage.csv | HKQuantityTypeIdentifierBodyFatPercentage | mean |
| SleepAnalysis.csv | HKCategoryTypeIdentifierSleepAnalysis | 合計時間（分）|

SleepAnalysis の `value` フィールドは文字列（`HKCategoryValueSleepAnalysisInBed` 等）をそのまま保持。
`full` 粒度では全レコード出力。集約時は `endDate - startDate` の合計分数を `value` に格納し `unit` は `min`。

---

## `extract.rb` 内部設計

```
main
├── parse_args(argv)       → xml_path, from_date, to_date, grain
├── build_writers(output/) → 指標名 => CSV::IO の Hash（8本）
├── SaxHandler             Ox::Sax サブクラス
│   ├── start_element      "Record" タグ検知 → 属性収集開始
│   ├── attr               属性を一時バッファに蓄積
│   └── end_element        レコード確定 → in_range? → aggregate or write
├── in_range?(date)        → startDate が from〜to の範囲内か
├── aggregate(record)      → grain に応じたキー（日/週/月）でバッファに積む
├── flush_writers(buffers) → 全バッファをCSVに書き出し
└── progress(count)        → 10万件ごとに stderr 出力
```

各メソッドは20行以内。クラスは `SaxHandler` のみ。

---

## `gen_sample.rb` 設計

- 引数: `ruby scripts/gen_sample.rb export.xml` → `data/sample.xml` を出力
- 対象8型を各10件ずつ収集（SAXで先頭から走査）
- 80件程度の最小XMLを生成（DOCTYPE宣言・HealthData ルート要素含む）

---

## Gemfile

```ruby
# frozen_string_literal: true
source "https://rubygems.org"
gem "ox"
```

---

## エラーハンドリング

- 引数不正 → usage メッセージを stderr 出力して exit 1
- ファイル不存在 → `File.exist?` チェック後に abort
- `output/` ディレクトリがなければ自動作成

---

## テスト手順

1. `bundle install`
2. `ruby scripts/gen_sample.rb export.xml` → `data/sample.xml` 生成確認
3. `ruby scripts/extract.rb data/sample.xml` → `output/` に8CSVが生成されることを確認
4. `head -5 output/*.csv` で中身確認
5. `ruby scripts/extract.rb export.xml 20240101 20241231 monthly` でフルデータ・月次集約を確認
