以下のタスクをサブエージェントに委譲してください。

引数: $ARGUMENTS（新しい export.xml のパス、または展開済みフォルダのパス。省略可）

---

**サブエージェントへの指示:**

作業ディレクトリ: /Users/bash/dev/src/github.com/bash0C7/apple_healthcare_analyzer


Apple Health の新しい export.xml で db/health.db を再構築する。

**ステップ0: プロジェクトルートの特定**

このコマンドが置かれているプロジェクトのルートディレクトリを特定する:

```bash
ls CLAUDE.md
```

以降の操作はすべてプロジェクトルートを基準に行う。

**ステップ1: XMLファイルの特定**

引数でファイルパスが直接渡された場合（`.xml` で終わる場合）はそれを使用する。

引数でフォルダパスが渡された場合は、そのフォルダ内の `export.xml` を使用する:

```bash
ls "<引数フォルダ>/export.xml"
```

引数が省略された場合は **ユーザーに確認する**:

```
新しい Apple Health エクスポートデータのフォルダを教えてください。

iPhoneの「ヘルスケア」アプリから再エクスポートし、
ZIPを展開したフォルダのパスを教えてください。
（例: /Users/yourname/Downloads/apple_health_export）

フォルダの中に export.xml があるはずです。
```

ユーザーからフォルダパスを受け取ったら:

```bash
ls "<ユーザー指定フォルダ>/export.xml"
```

見つからない場合は `find "<ユーザー指定フォルダ>" -name "export.xml"` で探し直す。
それでも見つからない場合はユーザーに確認して終了する。

**ステップ2: 前提確認**

```bash
ls db/health.db
```

- `db/health.db` が存在しない場合は「DBがまだ存在しません。`/apple-health-care-init-db` を実行してください。」と伝えて終了する。

**ステップ3: 現在のDBの状態を記録**

後で比較するために更新前の件数を控える:

```bash
sqlite3 db/health.db "SELECT COUNT(*) FROM raw_records;"
sqlite3 db/health.db "SELECT MIN(date), MAX(date) FROM daily_summary;"
```

**ステップ4: DB を削除して再構築**

```bash
rm db/health.db
bundle exec ruby scripts/import_xml.rb <export.xmlのパス>
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

以下の形式で日本語で報告する:

```
## DB 更新完了

| 項目 | 更新前 | 更新後 |
|---|---|---|
| raw_records | X 件 | Y 件（+Z 件） |
| daily_summary | YYYY-MM-DD 〜 YYYY-MM-DD | YYYY-MM-DD 〜 YYYY-MM-DD |

- ベースライン安静時心拍 p10: XX.X bpm
- ベースライン HRV 平均: XX.X ms

分析するには Claude Code で直接質問してください（chiebukuro_query_health ツールで自動クエリします）:
- 「直近90日の健康状態をまとめて」
```

エラーが発生した場合はエラーメッセージをそのまま報告し、どのステップで失敗したかを明示すること。
`rm db/health.db` 後に `import_xml.rb` が失敗した場合は、DBが失われた旨を伝え、再度 `/apple-health-care-update-db` を実行するよう案内すること。
