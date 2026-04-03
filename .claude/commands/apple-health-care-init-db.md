以下のタスクをサブエージェントに委譲してください。

引数: $ARGUMENTS

---

**サブエージェントへの指示:**

作業ディレクトリ: /Users/bash/Downloads/apple_health_export

Apple Health SQLite DB を初期化する。XMLファイルパスが引数で渡された場合はそれを使用し、省略時は `data/export.xml` を使う。

**ステップ1: 前提確認**

以下を確認する:
```bash
ruby -v
ls data/export.xml
ls db/health.db
```

- XMLファイルが存在しない場合は処理を中断し、ユーザーにパスを確認するよう伝える。
- `db/health.db` が既に存在する場合は「DBが既に存在します。再構築が必要な場合は `rm db/health.db` してから `/init-health-db` を再実行してください。」と報告して終了する。

**ステップ2: XML → raw_records インポート**

```bash
bundle exec ruby scripts/import_xml.rb data/export.xml
```

引数でパスが指定された場合はそのパスを使う。3GBのXMLは時間がかかるため、進捗を随時ユーザーに伝えること。

**ステップ3: daily_summary 構築**

```bash
bundle exec ruby scripts/build_summary.rb
```

**ステップ4: 結果確認**

```bash
sqlite3 db/health.db "SELECT COUNT(*) FROM raw_records;"
sqlite3 db/health.db "SELECT COUNT(*) FROM daily_summary;"
sqlite3 db/health.db "SELECT MIN(date), MAX(date) FROM daily_summary;"
sqlite3 db/health.db "SELECT key, value FROM meta ORDER BY key;"
```

**ステップ5: 完了報告**

以下の形式で日本語で報告する:

```
## DB初期化完了

- raw_records: X 件（XML生データ）
- daily_summary: Y 日分（YYYY-MM-DD 〜 YYYY-MM-DD）
- ベースライン安静時心拍 p10: XX.X bpm
- ベースライン HRV 平均: XX.X ms

次のステップ:
- 分析: /apple-health-analyze
- アドホッククエリ: Claude Code を再起動して MCP サーバー (health-db) 経由でクエリ可能
```

エラーが発生した場合はエラーメッセージをそのまま報告し、どのステップで失敗したかを明示すること。
