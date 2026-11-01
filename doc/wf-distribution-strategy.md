# WF 配布・更新戦略

> **ステータス: 実装済み（`bin/sf-sync-wf.sh`。2026-10-06）**

---

## 1. 背景

`force-XXXX` 側に設置する WF（`wf-validate.yml` / `wf-release.yml` 等）は、**セルフコンテインド WF**（reusable workflow を呼ばず、
起動の条件・ジョブ・ステップを、各ファイルに直接書く形式。2026-03-28 の c632154 で、reusable の形式から移行）であり、
`sf-init` の Phase 3（`phases/init/03_repo_create.sh`）が、`sf-tools/templates/` からコピーして配布する（`force-template` リポジトリは廃止済み）。

ただし、リリース・検証・メタ同期の処理の中身（`sf-release.sh`・`sf-metasync.sh`）は、WF に書かず、sf-tools のスクリプトを実行時に取得して使う（2.1）。

`sf-init` は、新しいリポジトリを作るときに、雛形をコピーするだけである。実運用開始後に WF を変更・追加・削除する必要が生じた場合
（不具合の修正・安全対策など）、作成済みの全プロジェクトへ反映する手段として、専用コマンド `sf-sync-wf.sh` を用意した。

---

## 2. アーキテクチャ方針

```
sf-tools（テンプレートの正本）
└── templates/.github/workflows/
    ├── wf-validate.yml   ← セルフコンテインド（ジョブ・ステップを内包。処理の中身は sf-tools のスクリプト）
    ├── wf-release.yml    ← 同上
    ├── wf-metasync.yml   ← 同上
    ├── wf-propagate.yml  ← 同上
    └── wf-sequence.yml   ← 同上

force-XXXX（各プロジェクト）
└── .github/workflows/
    ├── wf-validate.yml  ← sf-init（Phase 3）時に templates/ からコピー。以後は sf-sync-wf.sh で更新
    ├── wf-release.yml   ← 同上
    └── ...
```

- WF の正本は `sf-tools/templates/.github/workflows/` に一元管理する
- `sf-init` は `sf-tools/templates/` からそのままコピーして配布する（WF にはプレースホルダーの置換はない。置換するのは `sfdx-project.json` の `__REPO_NAME__` だけ）
- WF のうち、sf-tools のスクリプトを使うもの（2.1）は、実行のたびに sf-tools を clone するため、スクリプトの修正は、sf-tools の `main` へのマージ（rr）で、全プロジェクトにすぐ届く
- そのため、問題になるのは **WF 自体の変更**（secrets の追加削除、job 構造変更、不具合の修正など）のみ。これは配布済みの `force-*` に自動では届かない（4 章の `sf-sync-wf.sh` で反映する）

### 2.1 各 WF と sf-tools の関係

| WF（Actions の画面での名前） | 役割 | ジョブ名 | sf-tools の clone | concurrency |
|---|---|---|---|---|
| `wf-validate.yml`（`[validate] デプロイ前検証`） | PR の作成・更新で、`sf-release.sh` を検証モードで実行し、結果を PR にコメント | `対象ファイル確認` / `デプロイ検証` | する | なし |
| `wf-sequence.yml`（`[sequence] マージ順序チェック`） | main / staging への PR で、マージの順序（`branches.txt` の並び）を確認 | `対象ファイル確認` / `順序チェック` | しない | なし |
| `wf-release.yml`（`[release] デプロイ`） | PR のマージで、マージ先の組織へ `sf-release.sh --release` でリリース | `リリース対象確認` / `リリース実行` | する | `release-<マージ先>`（`queue: max`） |
| `wf-propagate.yml`（`[propagate] ブランチ伝播`） | main への PR のマージで、main を staging / develop へ直接マージして push | `下流伝播` | しない | `propagate` |
| `wf-metasync.yml`（`[metasync] メタ同期`） | 定期・手動で、main の組織のメタデータを `sf-metasync.sh` で main に同期 | `メタデータ同期` | する | `metasync` |

- concurrency は、どれも `cancel-in-progress: false`（実行中のものは取り消さない）。詳細は各 WF の冒頭コメント
- sf-tools の clone: 公開リポジトリ `https://github.com/tama-create/sf-tools.git` を、Token なしで、Variable `SF_TOOLS_BRANCH` のブランチ（未設定なら `main`）で `~/sf-tools` に clone する。`SF_TOOLS_TOKEN` は 2026-10-05 に廃止（sf-tools の公開に伴う。以前のバージョンで作った `force-*` の WF は Token 付きで clone しているため、その Token を無効にしないこと）。`SF_TOOLS_BRANCH=development` は検証環境だけが登録する（詳細は `doc/dev-reference.md` の 9.1・9.2）
- Secret `PAT_TOKEN` は、`wf-metasync` と `wf-propagate` のチェックアウトと push に使う（main・staging の Ruleset のバイパスと、`.github/workflows/` の変更を含むマージの push のため）。sf-tools の clone には使わない
- 必須チェック: force-* の Ruleset（`protect-main` / `protect-staging`）に登録するのは、ジョブ名だけ（`対象ファイル確認`・`デプロイ検証`・`順序チェック`。正本は `lib/project.sh` の `required_status_check_names`）。`ワークフロー名 / ジョブ名` の形では、永久に満たされない。`wf-release.yml` のジョブ名を `リリース対象確認` にしているのは、必須チェックの `対象ファイル確認` と、わざと名前を分けるため（詳細は `doc/dev-reference.md` の 9.5）

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
  1. force-* のフォルダか、雛形のフォルダがあるか、環境ブランチ（branches.txt のブランチ。HEAD がブランチでない場合も）でないかを確認
  2. sf-tools（このスクリプトがある sf-tools。通常は ~/sf-tools）が最新か確認（必須）。遅れていれば、確認のうえ更新し、
     更新した sf-tools で、同じ引数で、再実行（1 回だけ）
     （origin に接続できない・更新を断った・未コミットの変更や未プッシュのコミットがある場合は中断。
       Git のクローンでないなど、確認できない場合は、警告して続行。--check は更新せず、遅れていれば中断）
  3. 冒頭に、警告ボックス + [Y/N/q] 確認（--check は、何も変更しないため、表示しない。GITHUB_ACTIONS=true でも省略しない）
  4. sf-tools の templates/.github/workflows/ と .github/workflows/ を比較（CRLF の違いは無視）
  5. 差分なし → "最新です" で終了
  6. 差分あり → diff を表示（新規ファイルも表示。雛形にないファイルは、情報として表示するだけ）
  7. 差分を見たうえで、もう一度 [Y/N/q] 確認
  8. Y → templates/ の内容をコピー（上書き）
  9. "git diff .github/workflows/ で確認してコミットしてください" で終了

--check 指定時:
  差分があるかだけを調べる（何も変更せず、警告・確認も出さない）。差分なし: 終了コード 0 / あり: 1
  （1 は、中断（sf-tools が遅れている・環境ブランチ など）と区別しない。--remove とは同時に指定できない）

--remove <filename> 指定時（上の 1〜3 のあと。比較・上書きは行わない）:
  1. ファイル名を検証（^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ に一致しない名前・パスの区切りを含む名前は拒否）
  2. .github/workflows/ にないファイル・雛形にあるファイルは拒否 → 対象ファイルを表示
  3. 削除は追加確認（冒頭の確認に続く、2 回目の確認）
  4. Y → 削除（コミットはしない）
```

> 詳細（終了コード・ログ）は、`bin/sf-sync-wf.sh` の冒頭コメント（`--help`）と、`doc/dev-reference.md` の 4.15。

### 4.3 実装上の注意

- `force-*` ディレクトリ以外では実行不可（`check_force_dir`）
- 環境ブランチ（`main` / `staging` / `develop` など）では実行不可（ワークフローの変更は、作業用ブランチで行い、PR で入れる）
- 雛形の正本は、ローカルの sf-tools（このスクリプトがある sf-tools。通常は `~/sf-tools`）の `templates/`（GitHub から直接は取らない）。そのため、**実行の前に、sf-tools が最新であることを必須とする**（共通関数 `ensure_sf_tools_latest`（`lib/project.sh`）。更新した場合は、実行中のスクリプトが書き換わるため、同じ引数で再実行する）
- 管理者向けコマンドとして、冒頭に警告ボックス + 確認を出す。`GITHUB_ACTIONS=true` でも省略しない（Actions 上で実行する想定がないため。CLAUDE.md 2.4 の例外）
- 自動コミット・プッシュは行わない（ユーザーに委ねる）
- 削除は `--remove` フラグ明示時のみ（誤操作防止）。雛形にあるファイルは削除できない
- ワークフローをプッシュするには、`workflow` スコープのある権限が必要（main へのマージのあと、`wf-propagate` が staging / develop へ push するときは、`PAT_TOKEN` の `workflow` の権限を使う）
- `sf-sync-wf.sh` が書き換えるのは `.github/workflows/` のファイルだけで、Ruleset は変更しない。雛形で必須チェックのジョブ名（2.1）を変えたときは、既存の `force-*` の Ruleset も直す必要がある（食い違いは `sf-init.sh --status` が検出する。詳細は `doc/dev-reference.md` の 9.5）

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
