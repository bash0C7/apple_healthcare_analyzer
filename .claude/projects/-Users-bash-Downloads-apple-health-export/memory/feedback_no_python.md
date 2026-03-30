---
name: python絶対禁止
description: パイプ含むいかなる場面でもpython/python3を使わない
type: feedback
---

python / python3 はスクリプト内だけでなく、Bashコマンドのパイプ処理にも使わない。

**Why:** CLAUDE.mdに「python / python3 は絶対禁止。いかなる理由でも使用しないこと」と明記されている。パイプでのJSONパースなど一時的な用途でも同様。

**How to apply:** JSON処理はruby -e、データ確認はsqlite3コマンド、その他はRubyスクリプトで対応する。
