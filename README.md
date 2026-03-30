# apple_healthcare_analyzer

Apple Health の `export.xml`（数GB規模）から健康指標を抽出・分析する Ruby ツール。

SQLite DB に蓄積し、MCP サーバー経由で Claude Code / Claude Desktop から自然言語で健康分析できます。

## 機能

- **SAX パース** — 大容量XMLをメモリ展開せず逐次処理
- **10種の指標を抽出** — 歩数・体重・心拍・安静時心拍・消費カロリー・VO2Max・体脂肪・睡眠・HRV・呼吸数
- **SQLite DB** — XML全件を `raw_records` に格納、日次集計を `daily_summary` に保持
- **睡眠カテゴリ分割** — InBed / Asleep を正確に分離（生データから集計）
- **身体スコアリング** — HRV（55点）+ 安静時心拍（30点）+ 睡眠時呼吸数（15点）の3成分スコア
- **MCP サーバー** — Claude Code / Claude Desktop からアドホックSQLクエリ・自然言語分析が可能

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

**2. Mac で展開・配置**

ZIP を展開して `export.xml` を `data/` に置く：

```bash
cp /path/to/apple_health_export/export.xml data/export.xml
```

`data/export.xml` は `.gitignore` により追跡されません。

## 使い方

### 1. DB 初期化（初回のみ）

Claude Code から `/init-health-db` コマンドを実行するとサブエージェントが自動で実行します。
手動で実行する場合：

```bash
# XML全件をSQLiteにインポート（3GBのXMLは時間がかかります）
bundle exec ruby scripts/import_xml.rb data/export.xml

# 日次サマリーを構築
bundle exec ruby scripts/build_summary.rb
```

これで `db/health.db` が生成されます（`.gitignore` により追跡されません）。

### 2. DB 更新（新しいエクスポートを取り込む）

iPhone から新たにエクスポートした `export.xml` で DB を最新化する手順です。

**① iPhone で再エクスポート**

1. 「ヘルスケア」→ プロフィールアイコン →「すべてのヘルスケアデータを書き出す」
2. ZIP を Mac に転送・展開

**② export.xml を差し替える**

```bash
cp /path/to/新しい/apple_health_export/export.xml data/export.xml
```

**③ DB を再構築する**

新しい `export.xml` には過去分も含めた全データが入っているため、DB を作り直します：

```bash
rm db/health.db
bundle exec ruby scripts/import_xml.rb data/export.xml
bundle exec ruby scripts/build_summary.rb
```

Claude Code を使っている場合は `/update-health-db` コマンドが上記を自動で実行します：

```
/update-health-db                                    # data/export.xml が差し替え済みの場合
/update-health-db /path/to/新しい/export.xml         # パスを直接渡す場合
```

> **なぜ差分ではなく全件再構築か？**
> Apple Health のエクスポートは常に「全期間の全レコード」を含む完全なスナップショットです。
> 差分インポートではなく上書き再構築が最も確実です。

**集計ロジックだけを変えたい場合（XMLの再インポート不要）：**

```bash
# raw_records はそのまま、daily_summary だけ再計算
bundle exec ruby scripts/build_summary.rb
```

### 3. Claude / MCP で分析

DB 構築後は、Claude Code または Claude Desktop から自然言語で分析できます。

**分析プロンプト例：**

```
# 総合レポート
直近90日の健康状態を分析して。歩数・体重・HRV・睡眠・身体スコアのサマリーと、
このまま続けるとどうなるかの予測も教えて。

# 特定期間の深掘り
2026年1月〜3月のHRVと安静時心拍の推移を見せて。疲労の傾向はある？

# 体重・体組成
体重と体脂肪率のトレンドを教えて。このペースだと3ヶ月後はどうなる？

# 睡眠分析
直近30日の睡眠時間と身体スコアの相関を調べて。睡眠が短い日の翌日はスコアが下がってる？

# 季節・年間比較
去年と今年で歩数や消費カロリーに違いはある？

# VO2Max・有酸素能力
VO2Maxの推移と安静時心拍の相関を見せて。体力は上がってる？下がってる？

# 週次パターン
曜日別の歩数と消費カロリーの平均を出して。休日と平日でどう違う？

# アドホッククエリ（SQL直接）
query_health ツールで以下のSQLを実行して：
SELECT date, body_battery, hrv, resting_hr FROM daily_summary
WHERE date >= '2026-01-01' ORDER BY date;
```

### 4. MCP サーバーでアドホッククエリ

`db/health.db` に対して任意のSQLクエリを Claude から直接実行できます。

**Claude Code（自動設定済み）**

`.claude/settings.json` に設定済みのため、Claude Code を再起動するだけで有効になります。

**Claude Desktop への追加**

`~/Library/Application Support/Claude/claude_desktop_config.json` に以下を追記します：

```json
{
  "mcpServers": {
    "health-db": {
      "command": "/path/to/apple-health-export/scripts/start_mcp.sh"
    }
  }
}
```

`start_mcp.sh` はプロジェクトディレクトリへの `cd` と `bundle exec ruby scripts/mcp_server.rb` の起動をまとめたスクリプトです。実行権限が必要です：

```bash
chmod +x scripts/start_mcp.sh
```

Claude Desktop を再起動後、`query_health` / `get_db_info` ツールが使えるようになります。

**クエリ例：**

```sql
-- 直近30日の身体スコア推移
SELECT date, body_battery, hrv, resting_hr FROM daily_summary
WHERE date >= date('now', '-30 days') ORDER BY date;

-- 生データへのドリルダウン（日別平均心拍）
SELECT substr(start_date,1,10) AS date, AVG(CAST(value AS REAL)) AS avg_hr
FROM raw_records WHERE metric = 'HeartRate'
GROUP BY date ORDER BY date DESC LIMIT 30;

-- 季節別集計
SELECT substr(date,1,4) AS year,
  CASE CAST(substr(date,6,2) AS INTEGER)
    WHEN 3 THEN '春' WHEN 4 THEN '春' WHEN 5 THEN '春'
    WHEN 6 THEN '夏' WHEN 7 THEN '夏' WHEN 8 THEN '夏'
    WHEN 9 THEN '秋' WHEN 10 THEN '秋' WHEN 11 THEN '秋'
    ELSE '冬' END AS season,
  ROUND(AVG(hrv),1) AS avg_hrv, ROUND(AVG(body_battery),0) AS avg_score
FROM daily_summary GROUP BY year, season ORDER BY year, season;
```

## SQLite スキーマ

| テーブル | 内容 |
|---|---|
| `raw_records` | XML生データ全件 `(metric, start_date, end_date, creation_date, value, unit, source)` |
| `records` | 日次集計 `(date, metric, value, unit)` — UNIQUE(metric, date) |
| `daily_summary` | 横断的日次サマリー `(date PK, step_count, active_energy, body_mass, body_fat, heart_rate, resting_hr, hrv, respiratory_rate, vo2max, sleep_hours, asleep_hours, body_battery, updated_at)` |
| `meta` | ベースライン・構築日時 `(key PK, value)` |

## 身体スコアリング計算式

> **注意** このスコアは科学的・医学的な裏付けのある指標ではありません。作者本人が日々の体調変化をざっくり把握するために独自に設計した簡易的なものです。傾向の参考としてご利用ください。

HRV・安静時心拍・睡眠時呼吸数から算出する 0〜100 の総合スコア。

| 成分 | 配点 | 計算 |
|------|------|------|
| HRV (SDNN) | 55点 | `clamp(hrv / baseline_hrv_mean * 55, 0, 55)` |
| 安静時心拍 | 30点 | `clamp(30 - (rhr - baseline_rhr_p10) * 1.875, 0, 30)` |
| 睡眠時呼吸数 | 15点 | `clamp(15 - \|resp - 14.0\| * 2.25, 0, 15)` |

- `baseline_hrv_mean` — `raw_records` 全体のHRV平均
- `baseline_rhr_p10` — `raw_records` 全体のRHR 10パーセンタイル
- 呼吸数の最適値 — 14回/分（睡眠中）

スコア解釈: 80-100 = 優秀 / 60-79 = 良好 / 40-59 = 普通 / 40未満 = 要注意

## ファイル構成

```
.
├── scripts/
│   ├── import_xml.rb    # XML全件 → raw_records（初回のみ）
│   ├── build_summary.rb # raw_records → daily_summary / records / meta
│   ├── analyze.rb       # daily_summary → JSON stdout
│   ├── mcp_server.rb    # MCP stdioサーバー
│   ├── extract.rb       # SAXパース → output/*.csv（任意）
│   ├── load_db.rb       # output/*.csv → SQLite（任意）
│   └── gen_sample.rb    # テスト用サンプルXML生成
├── .claude/
│   ├── commands/
│   │   ├── init-health-db.md        # /init-health-db コマンド定義
│   │   └── update-health-db.md      # /update-health-db コマンド定義
│   └── settings.json    # Claude Code 許可コマンド・MCPサーバー設定
├── db/
│   └── .gitkeep         # db/ ディレクトリを追跡（health.db は gitignore）
├── Gemfile
└── CLAUDE.md
```

**コミットされないファイル**（`.gitignore`）: `data/`, `output/`, `db/*.db`, `electrocardiograms/`, `workout-routes/`

## プライバシー

個人の健康データは一切リポジトリに含まれません。`export.xml`、`output/*.csv`、`db/health.db` はすべて `.gitignore` で除外されています。

## ライセンス

MIT
