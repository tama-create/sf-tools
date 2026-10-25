# sf-logwatch.sh 設計書

> **ステータス: 未実装（設計のみ）。** `bin/sf-logwatch.sh` と `tests/test_sf-logwatch.sh` は、まだ存在しない（2026-10-25 に確認。`tests/run_tests.sh` の `TEST_FILES`・`doc/doc-stamps.txt`・`site/` にも、記載はない）。未実装として触れているのは、`README.md` の設計書の一覧と、`tests/docs-facts-allow.txt`（README に、実在しないコマンド名を書くための例外）だけ。
> 下のコード片は、設計の段階の下書き。実装するときは、9 章の規約に合わせて書き直す。

## 1. 概要

Salesforce 開発中に、ターゲットファイルのメタデータ種別を自動判定し、
対応する Apex デバッグログをほぼリアルタイムでローカルに取得するツール。

- ランチャーとは独立した単独起動ツール（`sf-launcher.sh` のメニュー（1〜7）には含めない）
- `force-*` プロジェクトディレクトリ内で実行する
- 自分のアカウントで実行したログのみ取得

---

## 2. 起動・停止

```bash
# force-* ディレクトリ内で実行
bash ~/sf-tools/bin/sf-logwatch.sh

# 停止: Ctrl+C（TraceFlag を自動削除してクリーンアップ）
```

> **Ctrl+C で止める前提の注意**: `sf-start.sh`・`sf-job.sh` は `trap '' INT` で Ctrl+C を無効にし、その無視は子の bash（`sf-launcher.sh` と、そこから実行するコマンド）に継承される（`sf-start.sh` の冒頭コメント【補足】）。Bash は、起動時に無視されていたシグナルを `trap` で戻せないため、それらの子として起動すると、Ctrl+C で止まらず、後始末の `trap` も INT では動かない。ランチャーとは別のターミナル（Ctrl+C が有効なシェル）から起動する。ランチャーのメニューに入れる場合は、Ctrl+C 以外の停止方法（`q` キーなど）が要る。

---

## 3. 処理フロー

```
起動
 ├─ 1. force-* ディレクトリチェック（lib/common.sh を source した時点で確認される。force- で始まらなければ exit 1）
 ├─ 2. sf の確認 (check_sf_cli --cache。sf-release.sh などと同じ)
 ├─ 3. 接続先組織の決定 (get_target_org。引数 > SF_TARGET_ORG > sf org display の alias。-t などのオプションは未決)
 ├─ 4. ブランチ名取得 (sf-tools/release/branch_name.txt)
 ├─ 5. ターゲットファイル解析 → ログレベル判定
 │       sf-tools/release/<branch>/deploy-target.txt の [files] セクションを解析
 ├─ 6. 現在ユーザーID取得 (sf org display --json)
 ├─ 7. DebugLevel レコード作成 (Tooling API)
 ├─ 8. TraceFlag レコード作成 (対象=自分, 有効期限=起動から2時間)
 ├─ 9. trap → TraceFlag / DebugLevel 削除してクリーンアップ（EXIT で登録する。6.5）
 └─ 10. 10秒ごとのポーリングループ
         ├─ sf apex list log で既知IDと比較し新しいログを検出
         ├─ sf apex get log --log-id <id> でダウンロード
         └─ logs/apex/YYYYMMDD_HHMMSS_<Operation>.log に保存
```

---

## 4. ターゲットファイルのパス解決

`sf-release.sh`（`sf-check.sh` の引数なしのときも同じ）の方式を踏襲する。

```bash
BRANCH_NAME_FILE="sf-tools/release/branch_name.txt"
BRANCH_NAME=$(tr -d '\r\n' < "$BRANCH_NAME_FILE")  # VAR=$(cmd) のため run 不使用
DEPLOY_LIST="sf-tools/release/${BRANCH_NAME}/deploy-target.txt"
```

- `branch_name.txt` は、`sf-install.sh` が書く、Git の管理外の手元のファイル。ブランチ名は、今の Git のブランチではなく、このファイルの内容（`sf-install.sh` は main では書き込みも削除もしないため、main では、前のブランチの値が残っていることがある。`sf-check.sh` の冒頭コメント）
- ファイルがないときの扱いは、既存で分かれている（`sf-release.sh` は `die`、`sf-check.sh` は WARNING を出して終了コード 0）。どちらに合わせるかは未決（10 章）

---

## 5. ログレベル判定ロジック

`deploy-target.txt` の `[files]` セクションを解析し、以下のルールで判定する。

| ターゲットに含む拡張子 | 設定するログレベル |
|---|---|
| `.cls` または `.trigger` | `ApexCode=FINEST` |
| `.flow-meta.xml` | `Workflow=FINEST` |
| 両方 | `ApexCode=FINEST` + `Workflow=FINEST` |
| 上記なし（その他のメタデータのみ） | `ApexCode=DEBUG`（デフォルト） |

その他のログレベル（Database / System / Validation 等）は当面 `NONE` または `ERROR`。
必要に応じて後から調整する。

- `deploy-target.txt` には、`[files]` のほかに `[members]` セクション（`種別名:メンバー名`）もある（`templates/sf-tools/release/__BRANCH__/deploy-target.txt`）。上の判定は `[files]` の拡張子だけを見る。`[members]` の `ApexClass:` / `ApexTrigger:` / `Flow:` を判定に含めるかは未決（10 章）
- LWC・Aura はフォルダで指定する（拡張子がない）ため、「その他」に入る

---

## 6. Salesforce API 操作

> JSON は、`grep` / `awk` で読まず、`json_get`（`lib/common.sh`。Node の標準機能のみ）で読む（CLAUDE.md 2.2）。`run` の出力には標準エラーも混ざる（sf の更新の案内など）が、`json_get` は、全体を JSON として読めなければ、最初の `{` から最後の `}` までを読む。
> 下のフラグ（`--use-tooling-api`・`--values`・`--record-id`・`--log-id`・`--output-dir`）は、sf 2.152.14 の `--help` で存在を確認した。応答の JSON のフィールド名（`result.userId`・`result.id`）は、未確認（10 章）。

### 6.1 ユーザーID 取得

```bash
DISP_JSON=$(run sf org display --target-org "$TARGET_ORG" --json) || die "組織の情報を取得できませんでした。"
USER_ID=$(json_get "$DISP_JSON" result.userId)  # VAR=$(cmd) のため run 不使用（値の抽出のみ。フィールド名は未確認）
```

### 6.2 DebugLevel 作成 (Tooling API)

```bash
DL_JSON=$(run sf data create record \
  --sobject DebugLevel \
  --values "DeveloperName=sf_logwatch MasterLabel=sf_logwatch \
            ApexCode=${APEX_LEVEL} Workflow=${FLOW_LEVEL} \
            Database=NONE System=NONE Validation=NONE \
            Callout=NONE Visualforce=NONE" \
  --use-tooling-api \
  --target-org "$TARGET_ORG" \
  --json) || die "DebugLevel を作成できませんでした。"
DEBUG_LEVEL_ID=$(json_get "$DL_JSON" result.id)  # VAR=$(cmd) のため run 不使用（値の抽出のみ）
```

### 6.3 TraceFlag 作成 (Tooling API)

有効期限（起動から 2 時間）の計算に、`date -d`（GNU）・`date -v`（BSD）は使わない（OS で構文が違い、CLAUDE.md 2.2 が避けるとしている）。以前の案（Linux/WSL 用の `date -u -d "+2 hours"` と、macOS 用の `date -u -v+2H` の書き分け）は、この規約に合わないため、置き換えた。候補は、Node の標準機能で求めること（`sf` が npm 版のため Node は前提。CLAUDE.md 2.2 の言語の方針に従い、境界は 1 か所にする）。Tooling API が受け付ける形式かは、実装時に確かめる（10 章）。

```bash
# 有効期限: 起動から2時間（Node で生成。候補）
EXPIRY=$(node -e 'process.stdout.write(new Date(Date.now() + 2 * 3600 * 1000).toISOString())')  # VAR=$(cmd) のため run 不使用

TF_JSON=$(run sf data create record \
  --sobject TraceFlag \
  --values "TracedEntityId=${USER_ID} LogType=USER_DEBUG \
            DebugLevelId=${DEBUG_LEVEL_ID} ExpirationDate=${EXPIRY}" \
  --use-tooling-api \
  --target-org "$TARGET_ORG" \
  --json) || die "TraceFlag を作成できませんでした。"
TRACE_FLAG_ID=$(json_get "$TF_JSON" result.id)  # VAR=$(cmd) のため run 不使用（値の抽出のみ）
```

### 6.4 ポーリング・ダウンロード

```bash
# 新しいログID一覧取得
LIST_JSON=$(run sf apex list log --target-org "$TARGET_ORG" --json)

# ログ本文ダウンロード
run sf apex get log --log-id "$LOG_ID" --target-org "$TARGET_ORG"
```

- `run` は、コマンドの出力をすべて `LOG_FILE` に `[日時] [OUT]` の行として記録し、命令置換やリダイレクトでは、標準エラーも混ぜて返す（`lib/common.sh` の `run` の説明）。ログ本文を `$(run sf apex get log ...)` やリダイレクトで保存すると、sf の警告が混ざり、本文が `sf-logwatch.log` にも丸ごと残る。10 秒ごとの `sf apex list log` の応答も、毎回 `sf-logwatch.log` に溜まる。`sf apex get log` の `--output-dir`（`-d`）で保存先を直接渡すか、などは未決（10 章）
- 既知のログ ID は、配列で持つ（`declare -A` は Bash 4 以降のため使わない。CLAUDE.md 2.2）

### 6.5 クリーンアップ (終了時)

後始末は `trap ... EXIT` で登録する（CLAUDE.md 2.2。Ctrl+C だけでなく、`die` による中断でも動く）。作成済みの ID だけを消す。

```bash
run sf data delete record --sobject TraceFlag --record-id "$TRACE_FLAG_ID" \
  --use-tooling-api --target-org "$TARGET_ORG"
run sf data delete record --sobject DebugLevel --record-id "$DEBUG_LEVEL_ID" \
  --use-tooling-api --target-org "$TARGET_ORG"
```

- 削除に失敗しても、TraceFlag は有効期限（2 時間）で切れる。DebugLevel は残るため、次回の `DeveloperName` の重複になる（10 章）

---

## 7. ログ保存

- **保存先**: `force-*/logs/apex/`
  - `templates/.gitignore` の `logs`（と `*.log`）により、Git の管理外になる
  - このツール自身のログ（`LOG_FILE`）は、他のコマンドと同じく `./sf-tools/logs/sf-logwatch.log`。`run` の失敗は、同じフォルダの `error.log` にも追記される（`lib/common.sh`）。Apex のログとは、置き場所が別
- **ファイル名**: `YYYYMMDD_HHMMSS_<Operation>.log`
  - `<Operation>` は `sf apex list log` のレスポンスにある `Operation` フィールドを使用
  - 例: `20260328_143022_Anonymous.log`
  - 日時をどの値から取るか（ログの開始時刻か、取得した時刻か）と、`Operation` にファイル名に使えない文字（`/` など）が入る場合の扱いは、未決（10 章）

---

## 8. ファイル構成

```
bin/sf-logwatch.sh              ← 新規作成（本体）
tests/test_sf-logwatch.sh       ← 新規作成（単体テスト）
```

`tests/run_tests.sh` の `TEST_FILES` に `test_sf-logwatch.sh` を追加すること（未登録のテストファイルがあると、`run_tests.sh` が WARNING を出す）。

実装と同じ変更で、次も直す:

- `doc/doc-stamps.txt`: 新しい `bin/sf-*.sh` は、どれかの文書の基になっていないと `tests/docs-stamp.sh --check` が失敗する（`doc/dev-reference.md` 5）。利用者向けの文書（`site/reference/` のコマンドのページなど）に書き、その文書の行を足して、`bash tests/docs-stamp.sh --update <文書> bin/sf-logwatch.sh` で印を付ける
- `README.md` の設計書の一覧の「（未実装）」と、`tests/docs-facts-allow.txt` の `command sf-logwatch.sh` の行（実在するようになれば、例外は要らない）
- 本書の冒頭のステータス

---

## 9. 実装時に守る規約

- **冒頭コメント（仕様の正本）**: 書式は `doc/doc-style.md` 3.2（【使い方】【オプション】【処理の流れ】【前提条件】【補足】）。`--help` / `-h` で、第 2 ブロックを表示する（`show_help`。CLAUDE.md 2.5）。`tests/test_cli_args.sh` が、全 `bin/sf-*.sh` の【オプション】を、自動で確かめる
- **ログ**: `lib/common.sh` を source する前に `LOG_FILE`（`./sf-tools/logs/sf-logwatch.log`）・`SCRIPT_NAME`・`LOG_MODE` を定義する。ログのレベルは `INFO` / `SUCCESS` / `WARNING` / `ERROR`（`FATAL` は `die` だけが使う）。`die` のメッセージに、復旧の案内を含めない
- **`run` ラッパー**: sf コマンドは `run` で実行する。例外（`VAR=$(cmd)`・`if cmd; then` など）には、その行に理由のコメントを付ける（CLAUDE.md 2.1）
- **Bash 3.2 / BSD 互換**: `declare -A`・`mapfile`・`timeout`（→ `run_with_timeout`）・`date -d`・`sed -i`（→ `sed_inplace`）などを使わない（CLAUDE.md 2.2）。CI の macOS（Bash 3.2・BSD の sed）で確かめる
- **入力**: 対話の入力を足すときは、`lib/input.sh` の関数（`read_key` / `ask_yn` など）を使う（CLAUDE.md 2.3）
- **安全ガード**: 開発者向けの想定（1 章）のため、CLAUDE.md 2.4 の管理者向けの警告ボックスの対象外。ただし、組織に DebugLevel / TraceFlag を作るため、接続先の保護をどうするかは未決（10 章）
- **テスト**: `tests/test_helper.sh` の `create_mock_sf` で sf をモックにし、stdin を与えてブロックを防ぐ（CLAUDE.md 3.2）

---

## 10. 未決事項・TODO

- [ ] 有効期限の生成方法の確定（6.3 の Node の候補が、TraceFlag の `ExpirationDate` として受け付けられるか。`date -d` / `date -v` は使わない）
- [ ] `sf apex list log` のレスポンス形式確認（フィールド名・JSON 構造。他のユーザーのログも返るなら、ユーザーで絞る必要があるか）
- [ ] `sf org display --json` のユーザー ID のフィールド名（6.1 の `result.userId`）と、`sf data create record --json` の ID のフィールド名（`result.id`）の確認
- [ ] DebugLevel の `DeveloperName` 重複時の処理（既存レコードの再利用 or 削除して再作成）
- [ ] TraceFlag の有効期限切れ前に自動延長するか（長時間作業向け）
- [ ] ログサイズが大きい場合の扱い（Salesforce は 1 ログ最大 2MB）
- [ ] ログ本文の保存方法（`run` の出力の扱い・`--output-dir` を使うか。6.4）と、`sf-logwatch.log` が、ポーリングの応答で大きくなる問題
- [ ] ファイル名の日時の取り方と、`Operation` の文字の扱い（7 章）
- [ ] `branch_name.txt` がないときの扱い（`sf-release.sh` に合わせて中断か、`sf-check.sh` に合わせて警告か。4 章）
- [ ] `[members]` セクションを、ログレベルの判定に含めるか（5 章）
- [ ] 接続先の保護: 共有環境の予約名（`prod` / `staging` / `develop` / `main`。`is_reserved_org_alias`）や、本番の組織（`org_local_release_check`）で、実行を止めるか（`sf-release.sh` は、ローカルからは止める）
- [ ] コマンドのオプション（接続先の指定 `-t`・`-v` など）
