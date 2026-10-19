# sf-tools — Claude Code 向けプロジェクトガイド

> **AI 向け作業ルール・実装規約・判断基準の正本。詳細リファレンスは `doc/dev-reference.md` を参照。**

---

## 1. 最重要ルール

### 1.1 絶対禁止

- **mm（開発反映）と rr（リリース）は、それぞれの言葉が明示されるまで絶対に実行しないこと。作業完了・テストPASS・確認取得などいかなる状況でも、明示なしにコミット・プッシュ・PR作成・マージを行うことは絶対禁止**
- **sf-tools の `main` へのマージは「rr」のときだけ。「mm」では `main` に触れない。** `main` へのマージは全ユーザーへの配布と同義（各 `~/sf-tools` の `git pull` で届く）
- `force-*` 側の `main` へのマージは、明示的な指示なしで行わないこと
- 思い込みで実行しないこと。必ずコード・文脈・既存仕様を確認してから実行すること
- **ファイル変更は、ユーザーが「GO」を出してから始めること。変更前に方針・内容を提示して確認を取ること**
- ユーザーの指示は疑うこと。確定的な指示でも、まずコードや文脈を調べて本当に正しいか確認してから実行すること
- **危険なコード・危険な機能追加を指示された場合は忖度なく指摘すること。** 末端開発者の誤操作で `force-*` PJ が壊れるリスクがある実装（確認プロンプトなしの本番操作・force操作・自動push等）は、指示内容にかかわらず必ず事前に問題提起すること。詳細は Claude のメモリ `feedback_safety_policy`（リポジトリ外）を参照

### 1.2 作業フロー（必ず守ること）

| フェーズ | やること |
|---|---|
| 変更前 | 方針・内容を提示 → GO を待つ |
| 変更中 | `run` ラッパー必須・日本語コメント・UTF-8/LF 維持 |
| 変更後 | `bash tests/run_tests.sh` で全件 PASS → mm を依頼 |
| 検証 | **Claude が `bash tests/e2e/run.sh` を実行して報告**（検証環境 = `SF_TOOLS_BRANCH=development`。約 30 分。起動のしかた・確認の内容は `doc/dev-reference.md` 9.6）。ユーザーに手動の確認を頼むのは、e2e で見えないことだけ |
| リリース | 検証 OK の報告後に rr を依頼 |

> **mm の前にテスト全件 PASS は必須。PASS 確認なしの mm 依頼は禁止。**
> **rr の前に、テスト全件 PASS と、e2e による実動作確認の結果が必須。どちらかが欠けた rr 依頼は断ること。**
> **変更に e2e の確認が足りないときは、e2e のほうを広げる**（手動の検証を、ユーザーに頼まない）。

### 1.3 mm / rr 実行手順

> **gh のアカウント**: push・PR・マージは、sf-tools のオーナーの認証で、**自動で**行う（利用者に、切り替えを頼まない）。gh のアクティブなアカウントは、書き換えず、コマンドごとに、トークンを指定する（`GH_TOKEN="$(gh auth token --user <オーナー>)"`、push は `http.extraheader`）。

#### 1.3.1 mm（開発反映）

「mm」と明示された場合のみ、以下の手順を一括実行すること。**`main` には触れない。**

```bash
git checkout development                 # development ブランチに移動
git add <対象ファイル>
git commit -m "..."
git push origin development
```

#### 1.3.2 rr（リリース）

「rr」と明示された場合のみ、以下の手順を一括実行すること。前提: `development` が mm 済み（未コミットの変更なし）で、1.2 の rr 前提が満たされていること。

```bash
git checkout development
git fetch origin                         # origin/development・origin/main が手元より進んでいないか確認
gh pr create --base main
gh pr merge <PR番号> --merge             # --delete-branch は付けない
git checkout development                 # マージ後も development に戻る
git pull origin main                     # main の最新を取り込む
```

### 1.4 メモリ・ドキュメント管理

- 「記憶して」と言われた場合は、`memory/` と `CLAUDE.md` の両方に保存すること
- 「ドキュメントを最新化して」と言われた場合は、リポジトリ内のすべての `*.md` をアップデートすること
- `*.md` ファイルには必ず項目番号を付けること（大項目 `1`、中項目 `1.1`、小項目 `1.1.1`）
- 対話・解説・要約はすべて日本語で行うこと
- **`CLAUDE.md` を更新したときは、その都度ブラッシュアップすること。** 増築（追記）を繰り返すと重複・番号ズレが生じるため、更新のたびに構成・重複・番号を見直すこと

### 1.5 Git worktree を使うとき

- worktree で作業したブランチが `rr` で `main` にマージされたあとは、そのworktreeは役目を終えている。**古いworktreeのファイルを本体の作業ディレクトリへコピー・参照しない**（別のworktree/別マシンでの後続の変更を上書きして消す事故になる）
- 複数のworktreeやマシンで並行して作業している可能性があるときは、書き込み前に `git fetch` して `origin/development` や `origin/main` が自分の手元より進んでいないか確認する
- （KonaYufuPJで、古いworktreeの内容を本体へコピーして公開ページの最新更新27コミット分を消しかけた事故が実際に発生している。同じ轍を踏まない）

### 1.6 ドキュメントの役割分担

| ファイル | 役割 | 方針 |
|---|---|---|
| `CLAUDE.md` | AI（Claude）向けのルール・指示 | **極力軽くすること**。重要事項のみ記載し、詳細は dev-reference に逃がす |
| `doc/dev-reference.md` | AI（Claude）向けの詳細実装リファレンス | 処理フロー・関数仕様・判定ロジックなど実装詳細を書く |
| `README.md` | 人間向けのプロジェクトドキュメント | **わかりやすく詳しく書く**。使い方・挙動・設計意図をユーザーが理解できるよう記述する |

> CLAUDE.md が重くなると Claude のパフォーマンスと回答精度が低下する。ルールや判断基準は簡潔に、詳細は必ず dev-reference に書くこと。

---

## 2. コーディング規約

### 2.1 run ラッパー

コマンド実行には必ず `run` ラッパーを使うこと。

**例外（直接実行してよいケース）:**

| パターン | 理由 |
|---|---|
| `command -v cmd` | 存在確認 |
| `if cmd; then` | 条件チェック |
| `VAR=$(cmd)` | 変数代入 |
| `cmd &` | バックグラウンド起動 |
| `cmd \|\| true` | 意図的エラー無視 |

> 例外を使う場合はその行にコメントで理由を記載すること。新規スクリプト作成・変更時は `run` 漏れがないか必ずレビューすること。

### 2.2 基本規約

- すべてのテキストファイルは UTF-8 / LF で統一すること
  - **新規ファイル作成後は必ず LF 変換すること**（Write ツールは CRLF を生成するため）
  - 変換コマンド: `wsl bash -c "sed -i 's/\r//' <file>"`
- `jq` など追加依存は原則追加しないこと（`awk` / `sed` / `grep` など標準コマンドを使う）。**JSON の読み取り**: GitHub の情報は `gh --jq`、sf CLI の出力などは `json_get`（`lib/common.sh`。Node の標準機能のみ）。シェルの `grep` / `sed` で JSON を読まない
- **クロスプラットフォーム（Windows の Git Bash・macOS・Linux で、同じように動くこと。絶対条件）**: GNU 固有の書き方を使わない。`sed -i` は使わず `sed_inplace`（`lib/platform.sh`）、`base64 -w 0` は使わず `base64_oneline`、sed の `\x1b` / `\t` は使わず `$'\033'` / `$'\t'` で展開してから渡す（`_strip_ansi`・`_strip_term_codes`）、`date -d` / `readlink -f` / `grep -P` / `stat -c`（`_get_mtime` を使う）・`touch -d`・`timeout` などは避ける。`wc -l` の結果を文字列として使うときは `tr -d ' '` を付ける（BSD は先頭に空白が付く）。CI（`test-macos` / `test-windows`）で、macOS 標準の Bash 3.2・BSD の sed のまま確認する
- **言語の方針**: 新機能は、基本的にシェルで書く。JSON / XML の処理や、状態・分岐が多い処理など、シェルだけでは重いと判断した場合に限り、
  Node（標準ライブラリのみ・追加パッケージなし。`sf` が npm 版のため、Node は前提）を、**境界を 1 か所にして**使ってよい。
  呼び出す側からは、シェルの関数・コマンドとして見えるようにする（テストも、既存の `tests/run_tests.sh` から回す）
- 致命的エラー時は `die` で即終了すること
- 一時ファイルは `trap ... EXIT` で確実にクリーンアップすること
- ログレベルは `INFO` / `SUCCESS` / `WARNING` / `ERROR` / `FATAL` を使い分けること
  - `FATAL` は `die` が内部で使用する。直接呼び出し不可
  - **`die` のメッセージに復旧案内を含めないこと**（事実のみ記載。2次災害防止）
- **Bash 3.2 で動くこと（macOS 標準の `/bin/bash`。追加のインストールなしで動かすため）**。Bash 4 以降の機能は使わない: `local -n`（→ `set_var`）・`declare -A`（→ 配列）・`mapfile`（→ `while read`）・`${x^}` / `${x,,}`（→ `tr`）・`wait -n`・`|&`・`$( )` の中の `case`。`timeout` は使わず `run_with_timeout`（`lib/platform.sh`）。`tests/test_common.sh` の `test_bash32_compat` が検査する。詳細は `doc/dev-reference.md` セクション1 参照

### 2.3 インタラクティブ入力

全インタラクティブ入力は `lib/common.sh` 定義の関数を使うこと。スクリプト内での独自実装・重複定義は禁止。

| 関数 | 用途 |
|---|---|
| `read_key VAR [PROMPT] [VALID]` | 1文字即時選択（Y/N/q・番号など） |
| `read_input VAR [PROMPT]` | テキスト自由入力（readline 対応） |
| `press_enter [MSG]` | Enter 待ち（q で中断） |
| `read_or_quit VAR PROMPT` | テキスト入力（空 Enter 無視・q で中断） |
| `ask_yn "質問"` | Y/N/q 確認（q は `die`） |

> `sf-launcher.sh` は `common.sh` を source しない standalone 設計のため例外。`read -rsn1` 直書き時は `|| { printf "\n"; exit 0; }` で EOF 対応を必ず付けること。

### 2.4 安全ガード（管理者向け警告）

**管理者向けコマンドには必ず冒頭に赤い警告ボックス + `ask_yn || die` を入れること。新規スクリプト追加・既存スクリプト変更時も同様。**

| ルール | 内容 |
|---|---|
| 警告ボックス表示 | `CLR_ERR` (赤) + box-drawing chars で目立つ警告を表示 |
| `ask_yn \|\| die` | N/q で必ず中断すること（`|| die` 必須）。`lib/wizard.sh` の `wizard_confirm`（Enter / Y で進み、N / q は die）も、同等として扱う（sf-init の開始画面）|
| `check_gh_owner "$OWNER"` | gh 認証ユーザーがリポジトリオーナーと一致するか確認（不一致は `die`。ただしオーナーが組織で、ユーザーがその有効な admin なら通過）|
| GITHUB_ACTIONS スキップ | `GITHUB_ACTIONS=true` の場合は警告・確認をスキップして自動実行 |
| 二重確認の防止 | `SF_DEPLOY_CONFIRMED=1` を export して呼び出し先の確認をスキップ |

**管理者向けコマンド一覧（警告必須）:**

| スクリプト | 状態 |
|---|---|
| `sf-init.sh` | ✅ 実装済み |
| `sf-metasync.sh` | ✅ 実装済み |
| `sf-update-secret.sh` | ✅ 実装済み |
| `sf-sync-wf.sh` | ✅ 実装済み |
| `sf-init.sh --verify`（`phases/init/verify.sh`） | ✅ 実装済み（警告ボックス + 実行内容の表示 + `wizard_confirm`（Enter。入力を最小に）。本番を含むときは、文面で明示） |
| `sf-release.sh`（`--release` 時） | ✅ 実装済み |
| `sf-typecheck.sh` | ✅ 実装済み（警告ボックス + `ask_yn \|\| die`（`-y` で省略可）。GitHub Actions 上・予約名のエイリアス・本番は拒否。作成・削除は `SfToolsE2eMin` を含むものだけ。**この安全ガードを緩めないこと**） |

> **警告ボックスは、`print_admin_warning`（`lib/common.sh`）を使うこと。`echo` で直書きしない。** 使い方は `doc/dev-reference.md` セクション 3.4 参照
> **警告は、必ず、確認（`ask_yn || die` / `wizard_confirm`）とセットにする。** 警告を出しただけで、先へ進まない（表示だけで流れると、意味がない）。読み取りのみのモード（`--list` など）も、同じ（`-y` で省略できるようにする）
> `sf-hook.sh` / `sf-unhook.sh`（手元のフックの入れ替え）・`sf-release.sh`（単独では、まず打たない。確認のみ）・`sf-deploy.sh`（開発者向けのラッパー）は、管理者向けではないため、警告ボックスは不要

### 2.5 冒頭コメント（仕様の正本）

**各シェルスクリプト冒頭のコメントは仕様の正本。スクリプトを変更した場合は冒頭コメントも必ず連動して更新すること。**

全 `sf-*.sh` スクリプトは `--help` / `-h` オプションに対応している。冒頭コメントの第2ブロック（2つ目の `===` 行〜3つ目の `===` 行）がヘルプとして表示される。

```bash
# ==============================================================================
# sf-xxx.sh - スクリプトの一行説明
# ==============================================================================
# 概要説明
#   1. 処理ステップ1
#   2. 処理ステップ2
#
# 【オプション】
#   -x, --xxx  : 説明
# ==============================================================================
```

---

## 3. テスト規約

### 3.1 実行方法

```bash
bash tests/run_tests.sh                        # 全テスト実行（mm 前に必ず実行）
bash tests/run_tests.sh test_sf-metasync.sh   # 単体実行
bash tests/run_tests.sh --changed             # 変更ファイルに対応するテストのみ実行
bash tests/run_tests.sh --jobs 4 / --serial   # 同時に動かすファイル数（既定: CPU の数。--serial は 1 つずつ）
bash tests/test_integration.sh                # 結合テスト L1（実 git ＋ fake。run_tests.sh の全件にも含まれる。手元の Windows は約 10 分、CI は 2 分ほど）
bash tests/e2e/doctor.sh                       # e2e を動かせる環境かの確認（読み取りのみ。新しい環境で、run.sh の前に実行）
bash tests/e2e/run.sh                          # 実環境の通し検証（検証のとき Claude が実行。通常のテストには含まれない）
```

> **開発中は `--changed`、mm 前は全件** が基本ワークフロー。PR（main・development 向け）と development への push では、GitHub Actions（`.github/workflows/test.yml`）も、全件テストと shellcheck を実行する。
> `tests/e2e/` は実際の GitHub / Salesforce にテスト用のものを作って削除する。**削除の安全ガード（名前の形式・オーナーの一致）を緩めないこと**。詳細は `doc/dev-reference.md` 9.6。

### 3.2 デグレ防止チェックリスト

- **新規 `sf-*.sh` を追加した場合**：対応する `test_sf-*.sh` を作成し、`tests/run_tests.sh` の `TEST_FILES` に追加すること
- **インタラクティブ入力を含むスクリプトのテスト**：`echo "n" |` または `run_script_with_no()` で stdin を供給すること（ブロック防止）
- **既存ロジックを変更する場合**：変更前後の動作差分をコメントまたはコミットメッセージに明記すること
- **git 操作を含む新規スクリプトを作成する場合**：`CLAUDE.md` の「スクリプト別の処理概要」に実行フローを先に記載してから実装すること
- **ブラウザ・GUI系コマンドを呼ぶスクリプトを追加した場合**：`test_helper.sh` の `create_mock_browser` にモックを追加すること

> テスト対象一覧・`test_helper.sh` の関数詳細は `doc/dev-reference.md` セクション2 参照

---

## 4. プロジェクト概要

Salesforce 開発の環境構築と日々の作業を自動化するシェルスクリプト集。
`~/sf-tools/` に設置し、各 Salesforce プロジェクト (`force-*` ディレクトリ) から呼び出して使う。

### 4.1 このリポジトリ固有の前提

- `~/sf-tools/` に設置して使う
- 実行場所は各 Salesforce プロジェクト (`force-*`) 側
- `sf-hook.sh` は `hooks/pre-push` をコピーする設計
- husky が設定されている場合は `core.hooksPath` を削除する設計
- **動作環境（Windows の Git Bash・macOS・Linux・WSL）の「検証済み」は、実際に動かした環境だけを書く**（README の表と `doc/dev-reference.md` 9.7 の記録を、実際の確認と一致させる。未検証は「未検証」と書く。目標は、すべての OS で動くこと）。新しい環境は、`bash tests/e2e/doctor.sh` で確認してから `bash tests/e2e/run.sh`
- Salesforce CLI（`sf`）は **npm 版が前提**（`check_sf_cli`）。Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため非対応（`run` は終了コードのみで判定する。詳細は `doc/dev-reference.md` 3.3）

### 4.2 ディレクトリ構成

> スクリプト一覧は `README.md` セクション 4、ディレクトリ構成は `README.md` セクション 7 を参照。

| パス | 役割 |
|---|---|
| `bin/sf-*.sh` | 各種自動化スクリプト本体 |
| `lib/common.sh` | 全スクリプト共通ライブラリ。`log` / `run` / `die` / 入力関数群を提供 |
| `phases/init/` | sf-init.sh のサブスクリプト（Phase 02〜10 + `add_tier.sh`） |
| `config/changeset-types.txt` | 変更セットで扱える種類の一覧（公式の Metadata Coverage Report。「全種類を対象にする」目標の一覧。`sf-typecheck.sh --coverage` で、確認の進み具合を見る） |
| `config/metadata-capability.txt` | メタデータの種類ごとの「リリース・削除」の可否の表（`sf-typecheck.sh` が実機で確認した結果。`sf-check.sh` が読む） |
| `hooks/pre-push` | git push フックの実体 |
| `templates/` | force-* へ配布する雛形。**参照は sf-init 専用**（`phase_setup_release_dir` のみ日常運用でも参照可） |
| `tests/` | モックベースの単体テスト一式 |
| `tests/e2e/` | 実環境での `sf-init` の通し検証（自動実行・自動削除）。通常のテストには含めない |
| `doc/` | 設計思想・戦略・開発リファレンス |

**サブスクリプトのフォルダ構成ルール:** メインスクリプトからフェーズ単位で呼ばれるサブスクリプトは **`phases/<script名>/`** に配置すること（`lib/` はライブラリ専用）。

### 4.3 ブランチ運用（sf-tools リポジトリ）

| ブランチ | 用途 |
|---|---|
| `development` | 開発ブランチ（通常の作業はここで行う） |
| `main` | リリースブランチ（`development` → PR → merge でリリース＝全ユーザーへ配布） |

- 作業は `development` ブランチで行い、`main` へは PR 経由でマージする
- mm = commit → push（`development` まで。`main` には入らない）
- rr = PR 作成 → `main` へマージ（配布）。実施前に検証環境の force-* で確認すること
- 検証環境 = Variable `SF_TOOLS_BRANCH=development` の force-*（Actions が sf-tools の `development` を使う）。詳細は `doc/dev-reference.md` セクション 9
- `main` のブランチ保護は、`sf-tools` が公開リポジトリのため設定済み（Ruleset `protect-main`: 削除禁止・強制プッシュ禁止・PR 必須）。直接 push は拒否される。上記の運用ルールを守る

---

## 5. 詳細リファレンス

詳細な仕様・関数リスト・コマンド集は **`doc/dev-reference.md`** を参照すること。

| セクション | 内容 |
|---|---|
| 1. クロスプラットフォーム詳細 | OS検出ルール・Bash バージョン要件 |
| 2. テスト詳細 | テスト対象一覧・test_helper.sh 関数 |
| 3. common.sh 詳細 | 全関数・戻り値・ログレベル・安全ガードパターン |
| 4. スクリプト別処理概要 | 各スクリプトの詳細フロー |
| 5. ドキュメント連動ルール | 変更時の確認先 |
| 6. スクリプト依存関係マップ | 呼び出し関係 |
| 7. デバッグコマンド集 | Salesforce CLI / Git コマンド |
| 8. force-* ローカル環境 | ディレクトリ構成 |
| 9. 開発・リリース手順 | 検証環境・検証チェックリスト・rr の前提・e2e（9.6） |
