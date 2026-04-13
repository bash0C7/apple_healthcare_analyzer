以下のタスクをサブエージェントに委譲してください。

引数: $ARGUMENTS

---

**サブエージェントへの指示:**

作業ディレクトリ: /Users/bash/dev/src/github.com/bash0C7/apple_healthcare_analyzer

**ステップ0: プロジェクトルートの特定**

このコマンドが置かれているプロジェクトのルートディレクトリを特定する:

```bash
# CLAUDE.mdがある場所 = プロジェクトルート
ls CLAUDE.md
```

以降の操作はすべてプロジェクトルートを基準に行う。

**ステップ1: XMLファイルの特定**

引数でファイルパスが渡された場合はそれを export.xml として使用する。

引数が省略された場合は **ユーザーに確認する**:

```
Apple Health のエクスポートデータフォルダを教えてください。

iPhoneの「ヘルスケア」アプリからエクスポートすると ZIP ファイルが生成されます。
それを展開したフォルダのパスを教えてください。
（例: /Users/yourname/Downloads/apple_health_export）

フォルダの中に export.xml というファイルがあるはずです。
```

ユーザーからフォルダパスを受け取ったら、以下で export.xml を探す:

```bash
ls "<ユーザー指定フォルダ>/export.xml"
```

ファイルが見つかった場合: そのパスを使用する。
見つからない場合: `find "<ユーザー指定フォルダ>" -name "export.xml"` で探し直す。
それでも見つからない場合: ユーザーに「export.xml が見当たりません。フォルダを確認してください」と伝えて終了する。

**ステップ2: 前提確認**

```bash
ruby -v
ls db/health.db
```

- `db/health.db` が既に存在する場合は「DBが既に存在します。再構築が必要な場合は `/apple-health-care-update-db` を実行してください。」と報告して終了する。

**ステップ3: XML → raw_records インポート**

```bash
bundle exec ruby scripts/import_xml.rb <export.xmlのパス>
```

3GBのXMLは時間がかかるため、進捗を随時ユーザーに伝えること。

**ステップ4: daily_summary 構築**

```bash
bundle exec ruby scripts/build_summary.rb
```

**ステップ5: 結果確認**

```bash
sqlite3 db/health.db "SELECT COUNT(*) FROM raw_records;"
sqlite3 db/health.db "SELECT COUNT(*) FROM daily_summary;"
sqlite3 db/health.db "SELECT MIN(date), MAX(date) FROM daily_summary;"
sqlite3 db/health.db "SELECT key, value FROM meta ORDER BY key;"
```

**ステップ6: 完了報告**

以下の形式で日本語で報告する:

```
## DB初期化完了

- raw_records: X 件（XML生データ）
- daily_summary: Y 日分（YYYY-MM-DD 〜 YYYY-MM-DD）
- ベースライン安静時心拍 p10: XX.X bpm
- ベースライン HRV 平均: XX.X ms

分析するには Claude Code で直接質問してください（chiebukuro_query_health ツールで自動クエリします）:
- 「直近90日の健康状態をまとめて」
- 「HRVと安静時心拍のトレンドは？」
```

エラーが発生した場合はエラーメッセージをそのまま報告し、どのステップで失敗したかを明示すること。
