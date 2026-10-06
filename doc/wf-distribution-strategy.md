# WF 配布・更新戦略

> **ステータス: 実装済み（`bin/sf-sync-wf.sh`。2026-10-06）**

---

## 1. 背景

`force-XXXX` 側に設置する WF（`wf-validate.yml` / `wf-release.yml` 等）は CI/CD ロジックを完全内包した**セルフコンテインド WF**であり、
`sf-init` 実行時に `sf-tools/templates/` からコピーして配布する（`force-template` リポジトリは廃止済み）。

`sf-init` は、新しいリポジトリを作るときに、雛形をコピーするだけである。実運用開始後に WF を変更・追加・削除する必要が生じた場合
（不具合の修正・安全対策など）、作成済みの全プロジェクトへ反映する手段として、専用コマンド `sf-sync-wf.sh` を用意した。

---

## 2. アーキテクチャ方針

```
sf-tools（テンプレートの正本）
└── templates/.github/workflows/
    ├── wf-validate.yml   ← セルフコンテインド（ロジック内包）
    ├── wf-release.yml    ← 同上
    ├── wf-metasync.yml   ← 同上
    ├── wf-propagate.yml  ← 同上
    └── wf-sequence.yml   ← 同上

force-XXXX（各プロジェクト）
└── .github/workflows/
    ├── wf-validate.yml  ← sf-init 時に templates/ からコピー
    ├── wf-release.yml   ← 同上
    └── ...
```

- WF の正本は `sf-tools/templates/.github/workflows/` に一元管理する
- `sf-init` は `sf-tools/templates/` からそのままコピーして配布する（プレースホルダーの置換はない）
- 問題になるのは **WF 自体の変更**（secrets の追加削除、job 構造変更、不具合の修正など）のみ

---

## 3. 方針（決定済み）

- `sf-install.sh` への WF 自動同期は **実装しない**
  - sf-start → sf-install のバックグラウンド自動実行チェーンに入れると、
    ユーザーの意思に関係なく `.github/workflows/` が書き換わるため不適切
- 専用 CLI `sf-sync-wf.sh` を、管理者が、必要なときに、手動で実行する
- ワークフローの更新は、通常の変更と同じく、ブランチ → PR → レビュー → マージの道を通す
  - 作業用ブランチは、`sf-job.sh` で、ジョブ名 `system-日付`（例: `system-20261006`）として作る
  - 固定の `system` ブランチは、**あらかじめ作らない**（`sf-job.sh` は同名のブランチを拒否する。長く残るブランチは `main` から遅れる）

---

## 4. `sf-sync-wf.sh` の仕様

### 4.1 責務

| 対応する | 対応しない |
|---|---|
| `sf-tools/templates/` との差分表示 | 自動コミット・プッシュ |
| ユーザー確認後にコピー | sf-install からの自動実行 |
| `--remove` フラグ付き削除（雛形から廃止されたファイルだけ） | バージョン管理 |
| `--check`（差分の有無だけを調べる） | 雛形にないファイルの自動削除 |

### 4.2 処理フロー

```
実行: sf-sync-wf.sh [--check] [--remove <filename>]

通常実行:
  1. force-* のフォルダか、環境ブランチ（branches.txt のブランチ）でないかを確認
  2. ~/sf-tools が最新か確認（必須）。遅れていれば、確認のうえ更新し、更新した sf-tools で、同じ引数で、再実行
     （origin に接続できない・更新を断った・未コミットの変更や未プッシュのコミットがある場合は中断。--check は更新せず、遅れていれば中断）
  3. 冒頭に、警告ボックス + [Y/N/q] 確認（--check は、何も変更しないため、表示しない）
  4. ~/sf-tools/templates/.github/workflows/ と .github/workflows/ を比較（CRLF の違いは無視）
  5. 差分なし → "最新です" で終了
  6. 差分あり → diff を表示（新規ファイルも表示。雛形にないファイルは、情報として表示するだけ）
  7. 差分を見たうえで、もう一度 [Y/N/q] 確認
  8. Y → templates/ の内容をコピー（上書き）
  9. "git diff .github/workflows/ で確認してコミットしてください" で終了

--check 指定時:
  差分があるかだけを調べる（何も変更せず、確認も出さない）。差分なし: 終了コード 0 / あり: 1

--remove <filename> 指定時:
  1. ファイル名を検証（パスの区切りを含む名前は拒否）。雛形にあるファイルは拒否
  2. 冒頭の警告ボックス + [Y/N/q] 確認 → 対象ファイルを表示
  3. 削除は追加確認（2 回目の確認）
  4. Y → 削除
```

### 4.3 実装上の注意

- `force-*` ディレクトリ以外では実行不可（`check_force_dir`）
- 環境ブランチ（`main` / `staging` / `develop` など）では実行不可（ワークフローの変更は、作業用ブランチで行い、PR で入れる）
- 雛形の正本は、ローカルの `~/sf-tools/templates/`（GitHub から直接は取らない）。そのため、**実行の前に、sf-tools が最新であることを必須とする**（共通関数 `ensure_sf_tools_latest`。更新した場合は、実行中のスクリプトが書き換わるため、同じ引数で再実行する）
- 自動コミット・プッシュは行わない（ユーザーに委ねる）
- 削除は `--remove` フラグ明示時のみ（誤操作防止）。雛形にあるファイルは削除できない
- ワークフローをプッシュするには、`workflow` スコープのある権限が必要

### 4.4 更新の手順（推奨）

1. `sf-job.sh` で、ジョブ名 `system-日付` の作業用ブランチを作る
2. そのフォルダで `sf-sync-wf.sh` を実行し、差分を確認して Y
3. `git diff .github/workflows/` で内容を確認する
4. `sf-push.sh` でコミット・プッシュする
5. PR を出してマージする。`develop` / `staging` がある構成では、通常の変更と同じ順序（`develop` → `staging` → `main`）で PR を出す（次の PR 先は `sf-next.sh` が案内する）

---

## 5. 対応状況

- 2026-10-06: `bin/sf-sync-wf.sh` を実装（`tests/test_sf-sync-wf.sh`）
- 雛形（`sf-tools/templates/.github/workflows/`）の内容を正しく保つことが、これまでどおり、前提である
