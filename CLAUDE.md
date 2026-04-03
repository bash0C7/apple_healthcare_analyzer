# health-analysis

## このプロジェクトについて
Apple Health の export.xml（3GB）から必要な指標を抽出・分析する。

## 技術スタック
- Ruby 4系（`ruby -v` で確認）
- Shell script（前処理・自動化）
- gem: ox（SAXパース）, csv（標準）, sqlite3
- Python / Node は使わない（**python / python3 は絶対禁止。いかなる理由でも使用しないこと**）

## ファイル配置
```
health-analysis/
├── CLAUDE.md
├── data/
│   └── export.xml        # シンボリックリンク or コピー
├── scripts/
│   ├── import_xml.rb     # XML全件 → db/health.db の raw_records（初回のみ）
│   ├── build_summary.rb  # raw_records → daily_summary / records / meta（再実行可）
│   ├── analyze.rb        # db/health.db → JSON stdout（CLIデバッグ用）
│   ├── extract.rb        # SAXパース → output/*.csv（CSVが必要な場合）
│   ├── load_db.rb        # output/*.csv → db/health.db（CSVからの取り込み用）
│   └── gen_sample.rb     # テスト用サンプルXML生成
├── output/
│   └── *.csv             # 任意の中間生成物
└── db/
    └── health.db         # SQLite DB（gitignore、スクリプトで生成）
```

## コードスタイル
- frozen_string_literal: true を必ず先頭に書く
- メソッド分割を優先、1メソッド20行以内
- 定数は SCREAMING_SNAKE_CASE
- コメントは日本語OK

## 実行コマンド（標準フロー）

```bash
# === 初回セットアップ ===
# /apple-health-care-init-db コマンドを使うか、以下を手動で実行

# 1. XMLから全件インポート（初回のみ・時間がかかる）
bundle exec ruby scripts/import_xml.rb data/export.xml

# 2. daily_summary を構築（raw_records から集計）
bundle exec ruby scripts/build_summary.rb

# === 分析 ===
# 分析は Claude Code / Claude Desktop の MCP 経由で行う
# query_health / get_db_info ツールを使って自然言語で質問する
# analyze.rb はCLIデバッグ用（直近90日のJSON出力）
bundle exec ruby scripts/analyze.rb

# === 再構築 ===
# summary だけ再構築（XMLインポートは不要）
bundle exec ruby scripts/build_summary.rb

# DBを完全に作り直す場合
rm db/health.db
bundle exec ruby scripts/import_xml.rb data/export.xml
bundle exec ruby scripts/build_summary.rb
```

## SQLiteスキーマ
- **raw_records**: `(id, metric, start_date, end_date, creation_date, value TEXT, unit, source)` — XML生データ全件
- **records**: `(id, date TEXT, metric TEXT, value REAL, unit TEXT)` — 日次集計、UNIQUE(metric, date)
- **daily_summary**: `(date PK, step_count, active_energy, body_mass, body_fat, heart_rate, resting_hr, hrv, respiratory_rate, vo2max, sleep_hours, asleep_hours, body_battery, updated_at)`
- **meta**: `(key PK, value)` — ベースライン・構築日時など

## DB 読み取りアクセス（chiebukuro-mcp 経由）

health.db の読み取りは **chiebukuro-mcp** 経由で行う（自前 MCP は廃止）。

利用可能ツール（chiebukuro-mcp に登録済み）:
- `chiebukuro_query_health` — SELECT クエリ実行（読み取り専用）

このプロジェクトのメンテナンス用スクリプト（import_xml.rb, build_summary.rb 等）は
chiebukuro-mcp に依存せず独立して動作する。

**分析は自然言語で行う。Claude に直接質問するだけでよい：**
- 「直近90日の健康状態をまとめて」
- 「HRVと安静時心拍のトレンドは？」
- 「体重のこのペースだと3ヶ月後はどうなる？」
- 「睡眠と身体スコアの相関を調べて」

```sql
-- 直接SQLを実行したい場合のアドホッククエリ例
SELECT date, step_count, body_battery FROM daily_summary
WHERE date >= '2026-01-01' ORDER BY date;

-- 生データへのドリルダウン
SELECT substr(start_date,1,10) as date, AVG(CAST(value AS REAL)) as avg_hr
FROM raw_records WHERE metric = 'HeartRate'
GROUP BY date ORDER BY date DESC LIMIT 30;
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
- HKQuantityTypeIdentifierHeartRateVariabilitySDNN（HRV）
- HKQuantityTypeIdentifierRespiratoryRate（呼吸数）

## 制約
- 3GBのXMLをメモリに全展開しない（SAXパース必須）
- CSVはUTF-8、ヘッダ行あり
- db/health.db はgitignore（個人データ）
- build_summary.rb は何度でも再実行可能（派生テーブルを再構築）
- import_xml.rb は初回のみ。再実行時はDB存在チェックでスキップ
