# sf-logwatch.sh 設計書

> **ステータス: 未実装（設計のみ）。** `bin/sf-logwatch.sh` と `tests/test_sf-logwatch.sh` は、まだ存在しない。

## 1. 概要

Salesforce 開発中に、ターゲットファイルのメタデータ種別を自動判定し、
対応する Apex デバッグログをほぼリアルタイムでローカルに取得するツール。

- ランチャーとは独立した単独起動ツール
- `force-*` プロジェクトディレクトリ内で実行する
- 自分のアカウントで実行したログのみ取得

---

## 2. 起動・停止

```bash
# force-* ディレクトリ内で実行
bash ~/sf-tools/bin/sf-logwatch.sh

# 停止: Ctrl+C（TraceFlag を自動削除してクリーンアップ）
```

---

## 3. 処理フロー

```
起動
 ├─ 1. force-* ディレクトリチェック
 ├─ 2. ブランチ名取得 (sf-tools/release/branch_name.txt)
 ├─ 3. ターゲットファイル解析 → ログレベル判定
 │       sf-tools/release/<branch>/deploy-target.txt の [files] セクションを解析
 ├─ 4. 現在ユーザーID取得 (sf org display --json)
 ├─ 5. DebugLevel レコード作成 (Tooling API)
 ├─ 6. TraceFlag レコード作成 (対象=自分, 有効期限=起動から2時間)
 ├─ 7. trap Ctrl+C → TraceFlag / DebugLevel 削除してクリーンアップ
 └─ 8. 10秒ごとのポーリングループ
         ├─ sf apex list log で既知IDと比較し新しいログを検出
         ├─ sf apex get log --log-id <id> でダウンロード
         └─ logs/apex/YYYYMMDD_HHMMSS_<Operation>.log に保存
```

---

## 4. ターゲットファイルのパス解決

`sf-release.sh` と同じ方式を踏襲する。

```bash
BRANCH_NAME_FILE="sf-tools/release/branch_name.txt"
BRANCH_NAME=$(tr -d '\r\n' < "$BRANCH_NAME_FILE")
DEPLOY_LIST="sf-tools/release/${BRANCH_NAME}/deploy-target.txt"
```

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

---

## 6. Salesforce API 操作

### 6.1 ユーザーID 取得

```bash
sf org display --target-org "$TARGET_ORG" --json \
  | grep '"userId"' | awk -F'"' '{print $4}'
```

### 6.2 DebugLevel 作成 (Tooling API)

```bash
sf data create record \
  --sobject DebugLevel \
  --values "DeveloperName=sf_logwatch MasterLabel=sf_logwatch \
            ApexCode=${APEX_LEVEL} Workflow=${FLOW_LEVEL} \
            Database=NONE System=NONE Validation=NONE \
            Callout=NONE Visualforce=NONE" \
  --use-tooling-api \
  --target-org "$TARGET_ORG" \
  --json | grep '"id"' | awk -F'"' '{print $4}'
```

### 6.3 TraceFlag 作成 (Tooling API)

```bash
# 有効期限: 起動から2時間（date コマンドで生成）
EXPIRY=$(date -u -d "+2 hours" '+%Y-%m-%dT%H:%M:%S.000+0000')  # Linux/WSL
# EXPIRY=$(date -u -v+2H '+%Y-%m-%dT%H:%M:%S.000+0000')        # macOS

sf data create record \
  --sobject TraceFlag \
  --values "TracedEntityId=${USER_ID} LogType=USER_DEBUG \
            DebugLevelId=${DEBUG_LEVEL_ID} ExpirationDate=${EXPIRY}" \
  --use-tooling-api \
  --target-org "$TARGET_ORG" \
  --json | grep '"id"' | awk -F'"' '{print $4}'
```

### 6.4 ポーリング・ダウンロード

```bash
# 新しいログID一覧取得
sf apex list log --target-org "$TARGET_ORG" --json

# ログ本文ダウンロード
sf apex get log --log-id "$LOG_ID" --target-org "$TARGET_ORG"
```

### 6.5 クリーンアップ (Ctrl+C 時)

```bash
sf data delete record --sobject TraceFlag --record-id "$TRACE_FLAG_ID" \
  --use-tooling-api --target-org "$TARGET_ORG"
sf data delete record --sobject DebugLevel --record-id "$DEBUG_LEVEL_ID" \
  --use-tooling-api --target-org "$TARGET_ORG"
```

---

## 7. ログ保存

- **保存先**: `force-*/logs/apex/`
- **ファイル名**: `YYYYMMDD_HHMMSS_<Operation>.log`
  - `<Operation>` は `sf apex list log` のレスポンスにある `Operation` フィールドを使用
  - 例: `20260328_143022_Anonymous.log`

---

## 8. ファイル構成

```
bin/sf-logwatch.sh              ← 新規作成（本体）
tests/test_sf-logwatch.sh       ← 新規作成（単体テスト）
```

`tests/run_tests.sh` の `TEST_FILES` に `test_sf-logwatch.sh` を追加すること。

---

## 9. 未決事項・TODO

- [ ] `date` コマンドのクロスプラットフォーム対応（Linux/WSL vs macOS で構文が異なる）
- [ ] `sf apex list log` のレスポンス形式確認（フィールド名・JSON 構造）
- [ ] DebugLevel の `DeveloperName` 重複時の処理（既存レコードの再利用 or 削除して再作成）
- [ ] TraceFlag の有効期限切れ前に自動延長するか（長時間作業向け）
- [ ] ログサイズが大きい場合の扱い（Salesforce は 1 ログ最大 2MB）
