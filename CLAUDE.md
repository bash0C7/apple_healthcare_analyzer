# health-analysis

## このプロジェクトについて
Apple Health の export.xml（3GB）から必要な指標を抽出・分析する。

## 技術スタック
- Ruby 4系（`ruby -v` で確認）
- Shell script（前処理・自動化）
- gem: ox（SAXパース）, csv（標準）
- Python / Node は使わない

## ファイル配置
```
health-analysis/
├── CLAUDE.md
├── data/
│   └── export.xml  # シンボリックリンク or コピー
├── scripts/
│   ├── extract.rb      # メイン抽出スクリプト
│   └── analyze.rb      # 分析スクリプト
└── output/
    └── *.csv           # 抽出結果
```

## コードスタイル
- frozen_string_literal: true を必ず先頭に書く
- メソッド分割を優先、1メソッド20行以内
- 定数は SCREAMING_SNAKE_CASE
- コメントは日本語OK

## 実行コマンド
```bash
# 抽出
ruby scripts/extract.rb data/export.xml

# 結果確認
wc -l output/*.csv
head -5 output/BodyMass.csv
```

## 抽出対象の指標
- HKQuantityTypeIdentifierStepCount（歩数）
- HKQuantityTypeIdentifierBodyMass（体重）
- HKQuantityTypeIdentifierHeartRate（心拍数）
- HKQuantityTypeIdentifierRestingHeartRate（安静時心拍）
- HKQuantityTypeIdentifierActiveEnergyBurned（消費カロリー）
- HKQuantityTypeIdentifierVO2Max
- HKQuantityTypeIdentifierBodyFatPercentage（体脂肪率）
- HKCategoryTypeIdentifierSleepAnalysis（睡眠）

## 制約
- 3GBのXMLをメモリに全展開しない（SAXパース必須）
- `elem.clear` でメモリ解放を忘れない
- CSVはUTF-8、ヘッダ行あり
```

---

## ③ Claude Code への初回プロンプト（コピペ用）
```
以下の要件でApple Health分析ツールをRuby 4で構築してください。

## やること（順番に）
1. `gem install ox` が通るか確認。通らなければ代替SAXパーサを提案する
2. `scripts/extract.rb` を実装する
   - ox gem の SAXパーサで export.xml を逐次処理（メモリ展開しない）
   - CLAUDE.md記載の8種類の指標を output/*.csv に書き出す
   - 進捗を stderr に出力（何万件処理したか）
3. 動作確認用に `data/sample.xml`（50件程度）を生成するスクリプトも作る
4. sample.xml で extract.rb が通ることを確認してからフルデータに進む

## 完了条件
- `ruby scripts/extract.rb data/sample.xml` が正常終了する
- output/ に8ファイルのCSVが生成される
- 各CSVの先頭5行を表示して中身を確認する

まず現在のRubyバージョンとox gemの状態を確認してから始めてください。
