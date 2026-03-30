以下のタスクをサブエージェントに委譲してください。

引数: $ARGUMENTS（新しい export.xml のパス。省略時は data/export.xml が既に差し替え済みとみなす）

---

**サブエージェントへの指示:**

作業ディレクトリ: /Users/bash/Downloads/apple_health_export

Apple Health の新しい export.xml で db/health.db を再構築する。

**ステップ1: 前提確認**

```bash
ruby -v
ls db/health.db
```

- `db/health.db` が存在しない場合は「DBがまだ存在しません。`/init-health-db` を実行してください。」と伝えて終了する。

**ステップ2: export.xml の差し替え（引数が指定された場合のみ）**

引数でパスが渡された場合、そのファイルを `data/export.xml` にコピーする：

```bash
cp <引数のパス> data/export.xml
ls -lh data/export.xml
```

引数が省略された場合は `data/export.xml` が既に最新に差し替え済みとみなし、このステップをスキップする。

**ステップ3: 現在のDBの状態を記録**

後で比較するために更新前の件数を控える：

```bash
sqlite3 db/health.db "SELECT COUNT(*) FROM raw_records;"
sqlite3 db/health.db "SELECT MIN(date), MAX(date) FROM daily_summary;"
```

**ステップ4: DB を削除して再構築**

```bash
rm db/health.db
bundle exec ruby scripts/import_xml.rb data/export.xml
bundle exec ruby scripts/build_summary.rb
```

3GBのXMLは時間がかかるため、進捗メッセージを随時ユーザーに伝えること。

**ステップ5: 結果確認・比較レポート**

```bash
sqlite3 db/health.db "SELECT COUNT(*) FROM raw_records;"
sqlite3 db/health.db "SELECT COUNT(*) FROM daily_summary;"
sqlite3 db/health.db "SELECT MIN(date), MAX(date) FROM daily_summary;"
sqlite3 db/health.db "SELECT key, value FROM meta ORDER BY key;"
```

以下の形式で日本語で報告する：

```
## DB 更新完了

| 項目 | 更新前 | 更新後 |
|---|---|---|
| raw_records | X 件 | Y 件（+Z 件） |
| daily_summary | YYYY-MM-DD 〜 YYYY-MM-DD | YYYY-MM-DD 〜 YYYY-MM-DD |

- ベースライン安静時心拍 p10: XX.X bpm
- ベースライン HRV 平均: XX.X ms

次のステップ: /apple-health-analyze で最新データを分析
```

エラーが発生した場合はエラーメッセージをそのまま報告し、どのステップで失敗したかを明示すること。
`rm db/health.db` 後に `import_xml.rb` が失敗した場合は、DBが失われた旨を伝え、再度 `/update-health-db` を実行するよう案内すること。
