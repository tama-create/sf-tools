# sf-tools 開発リファレンス

> **本書の位置づけ:** CLAUDE.md のルール・判断基準を補完する詳細リファレンス。
> コーディング中に「どう書くか」を調べるときに参照すること。

---

## 1. クロスプラットフォーム詳細

### 1.1 Bash バージョン要件

- **Bash 3.2 以上で動くこと**。macOS 標準の `/bin/bash` は 3.2 で、今後も更新されない。スクリプトの先頭行は `#!/bin/bash` のため、Homebrew で新しい Bash を入れても、使われない。**追加のインストールなしで、macOS の標準のターミナル（zsh）から動かす**ために、3.2 を下限にする（Windows の Git Bash・Linux は 5 系で、同じコードが動く）
- `lib/common.sh` 冒頭で `BASH_VERSINFO` をチェックし、3.2 未満は起動不可とする
- **Bash 4 以降の機能は、使わない**。代わりの書き方:

| 使わない（Bash 4 以降） | 代わり |
|---|---|
| `local -n`（nameref） | `set_var VARNAME VALUE`（`lib/platform.sh`。`printf -v`。変数名を検査する。`eval` は使わない）。配列を返すときは、決まった名前の配列に入れて、呼び出し元でコピーする（`sf-release.sh` の `_pl_out`） |
| `declare -A`（連想配列） | 通常の配列（キーと値を、同じ添字の 2 つの配列で持つ。`phases/init/status.sh`）、または、名前の配列（`phases/init/verify.sh` の `LEFT`） |
| `mapfile` / `readarray` | `while IFS= read -r line; do arr+=("$line"); done <<< "$text"` |
| `${x^}` / `${x^^}` / `${x,,}` | `tr '[:lower:]' '[:upper:]'` |
| `wait -n` | バージョンで分岐し、3.2 では `sleep 0.2` で数え直す（`tests/run_tests.sh`） |
| `$( case ... esac )` | `$( )` の外で `case` を書き、変数に入れる（3.2 は、`case` の `)` を、`$( )` の終わりと取り違え、**構文チェック（`bash -n`）は通るのに、実行時に、コードの一部が文字として出力される**） |
| `\|&`・`&>>`・`${x@Q}`・`[[ -v x ]]`・`printf '%(...)T'`・負の添字 `${a[-1]}` | 使わない |

- 関数の中で `set_var "$1" ...` を使うときは、その関数の `local` 変数に、接頭辞（`_xx_`）を付ける（呼び出し元の変数名と同じ名前の `local` があると、そちらに代入されるため）
- `tests/test_common.sh` の `test_bash32_compat` が、上の機能を使っていないことを、検索で確認する。CI の `test-macos` は、`/bin/bash`（3.2）で全件を実行する

### 1.2 OS 検出の統一ルール

| 目的 | 使う方法 | 理由 |
|---|---|---|
| GitBash 検出 | `is_gitbash`（`lib/common.sh`。`$OSTYPE` が `msys*` / `mingw*` / `cygwin*`） | Bash 組み込み・サブプロセス不要。Git Bash でも、環境により `$OSTYPE` が `cygwin` になるため、`msys` / `mingw` だけを見ない |
| macOS 検出 | `[[ "$OSTYPE" == "darwin"* ]]` | 同上 |
| WSL 検出 | `grep -qi microsoft /proc/version 2>/dev/null` | `/proc` 非存在環境は `2>/dev/null` で抑制 |
| macOS/Linux 分岐が必要な場合のみ | `uname -s` | `stat` 書式差異など限定的に使用 |

> `uname -s` はサブプロセスを起動するため遅い。OS 検出は原則 `$OSTYPE` に統一すること。

### 1.3 新規スクリプト追加・大きな変更後のチェック

**検証済み動作環境（必ず動くこと）:**

- **ローカル: Windows + Git Bash**
- **サーバー: Linux（GitHub Actions / Ubuntu ランナー）**

**意識する動作環境（クロスプラットフォーム方針・検証はしない）:**

- **macOS / WSL**

- プラットフォーム固有コマンド（`powershell.exe` / `open` / `xdg-open` 等）は `command -v` で存在確認してから使うこと
- `/proc/version` / `/proc/` 配下のファイルは macOS / GitBash に存在しないため `2>/dev/null` を付けること

---

## 2. テスト詳細

### 2.1 主要テスト対象

| ファイル | 対象スクリプト |
|---|---|
| `test_common.sh` | lib/common.sh（`json_get`: 基本・先頭のドット・配列・日本語や引用符・警告つき・不正な JSON・`node` がない・`set -e` を含む。`node -e` だけは、モックではなく本物の node に渡す: `test_helper.sh`） |
| `test_init-common.sh` | phases/init/init-common.sh（`ensure_sf_tools_branch`。実際の Git と一時 bare リポジトリを使用） |
| `test_org.sh` | lib/org.sh（ログイン先の 3 択・環境変数の指定・組織の種類の判定・本番は main のみのガード・保存） |
| `test_verify.sh` | phases/init/verify.sh と lib/verify-common.sh（実行できない場所・--plan・診断の不足・確認（N / q / EOF・本番の明示）・1 層・3 層（develop → staging → main の順）・失敗（マージしない・案内）・取り違えの検出・--cleanup・部品） |
| `test_diag.sh` | lib/diag.sh（セットアップの診断: すべてそろっている・不足と直し方・一覧を取得できない（？。不足に数えない）・段階の数に応じた確認・組織の種類の記録がない（！）・直近の実行・読み取りのみ） |
| `test_wizard.sh` | lib/wizard.sh（ウィザード形式の画面の部品: 現在地・チェックリスト・確認・失敗・完了） |
| `test_sf-unhook.sh` | sf-unhook.sh |
| `test_sf-hook.sh` | sf-hook.sh |
| `test_sf-init.sh` | sf-init.sh |
| `test_sf-upgrade.sh` | sf-upgrade.sh |
| `test_sf-install.sh` | sf-install.sh |
| `test_sf-start.sh` | sf-start.sh |
| `test_sf-restart.sh` | sf-restart.sh |
| `test_sf-metasync.sh` | sf-metasync.sh |
| `test_sf-release.sh` | sf-release.sh |
| `test_sf-deploy.sh` | sf-deploy.sh |
| `test_sf-dryrun.sh` | sf-dryrun.sh |
| `test_sf-job.sh` | sf-job.sh（任意の作業フォルダ・`--owner` / `--project`・クローンの git remote・同名ジョブの重複判定を含む） |
| `test_project-identity.sh` | lib/project.sh のオーナー・XXXX の決め方（`parse_github_remote` / `normalize_project_name` / `discover_clones` / `gh_owner_candidates` / `resolve_init_identity` / `resolve_job_identity`） |
| `test_sf-next.sh` | sf-next.sh |
| `test_sf-check.sh` | sf-check.sh（種類の可否の判定・同梱の表 `config/metadata-capability.txt` の形式を含む） |
| `test_sf-typecheck.sh` | sf-typecheck.sh / lib/typecheck.js（node が無い環境では、スキップ。sf はモック） |
| `test_sf-prepush.sh` | hooks/pre-push |
| `test_sf-push.sh` | sf-push.sh |
| `test_sf-update-secret.sh` | sf-update-secret.sh |
| `test_sf-sync-wf.sh` | sf-sync-wf.sh |
| `test_wf-sequence.sh` | templates/.github/workflows/wf-sequence.yml（YAML の判定スクリプトを取り出して、実際の git リポジトリで、順序どおり・順序外・最下位・環境ブランチからの PR を確認） |

### 2.1.1 テストの実行方式と CI

- **並列実行**: `run_tests.sh` は、複数ファイルを、同時に（既定は CPU の数まで）動かす。時間のかかるファイル（`HEAVY_FIRST`: `test_sf-init.sh` など）を先に起動し、標準入力は閉じる（入力待ちで止まらないため）。出力は、ファイルごとに溜めて、`TEST_FILES` の順に表示・集計する。実測（8 コア・WSL）: 直列 約 400 秒 → 並列 約 170〜230 秒。並列数を 4〜100 で変えても、大きな差は、出なかった。
- **WSL**: Git Bash から実行すると、自動で WSL に移り、ext4 にコピーして実行する（`/mnt/c` の 9P は、遅いため）。WSL には `node` がなく `node.exe` だけがある場合があり、`test_helper.sh` の node のモックは、`node -e` を、本物（`node` または `node.exe`）に渡す（`json_get` のテストのため）。
- **クロスプラットフォームの CI**: 同じワークフローに、`test-macos`（`macos-latest`。macOS 標準の `/bin/bash`（3.2）と、BSD の `sed` などを、そのまま使う。何も追加で入れない）と `test-windows`（`windows-latest` の Git Bash。`SF_TEST_NO_WSL=1`・`core.autocrlf=false`）がある。**2026-10-14 から、失敗扱い**（`continue-on-error` なし。以前は、導入の初期として、結果の表示のみだった）。Windows は、並列で実行する（約 15 分）。再び異常終了するときは、`--serial` に戻す。**BSD / GNU の差**として、`sed -i`（BSD は、`-i` の直後に拡張子が必要 → `sed_inplace`）・sed の `\x` / `\t`（BSD は解釈しない → Bash の `$'..'` で展開）・`date -d`・`touch -d`・`stat -c`・`nproc`・`timeout`（macOS にない → `run_with_timeout`）・`wc -l`（BSD は、数字の前に空白が付く → 文字列として使うときは `tr -d ' '`）に注意する。`openssl req -subj`（先頭の `//` は Git Bash 専用。macOS・Linux に渡すと、発行先が空の証明書ができ、Salesforce が「証明書ではありません」と拒否する → `_jwt_cert_subject_arg` が OS で切り替え、`generate_jwt_cert` が生成後に空でないことを確認する。既存の空の証明書は、`ensure_jwt_cert_subject` が、秘密鍵そのままで作り直す）。macOS の `tar` は、日本語のファイル名を NFD に変えて展開するため、テストで、HOME を差し替えて git を使うときは、`core.precomposeunicode` をリポジトリに設定する。
- **CI**: `.github/workflows/test.yml`（Ubuntu のランナー）。PR（main・development 向け）と development への push で、全件テスト（`bash tests/run_tests.sh`）と shellcheck（`-S warning`。バージョン固定 `shellcheck-py==0.11.0.1`）を実行し、どちらも失敗扱いになる。Secrets は使わない。shellcheck の設定は、リポジトリ直下の `.shellcheckrc`（`SC1090` / `SC1091`・`SC2034`・`SC2155` を、理由つきで無効化）。個別の誤検知は、該当行の直前に `# shellcheck disable=SCxxxx  # 理由` で除外する。手元での実行: `shellcheck -S warning $(git ls-files 'bin/*.sh' 'lib/*.sh' 'phases/*.sh' 'hooks/*' 'templates/*.sh')`（`pip install shellcheck-py` など）。

### 2.2 `test_helper.sh` の前提

セットアップ関数:

| 関数 | 用途 |
|---|---|
| `setup_force_dir` | `force-*` の一時ディレクトリを作成 |
| `setup_regular_dir` | 通常ディレクトリを作成 |
| `setup_mock_bin` | モックコマンド用ディレクトリを作成（**呼び出し後に必ず `export MOCK_CALL_LOG="$mb/calls.log"` を実行すること**） |
| `setup_release_dir TD [BRANCH]` | `release/<branch>/` を作成 |
| `setup_mock_home` | `~/sf-tools` をコピーした一時 HOME を作成 |
| `teardown ARG...` | 指定ディレクトリを削除 |

モック生成関数（`create_all_mocks` で一括生成）:

| 関数 | モック対象 |
|---|---|
| `create_mock_git` | git |
| `create_mock_sf` | sf（Salesforce CLI） |
| `create_mock_npm` | npm |
| `create_mock_code` | code（VS Code） |
| `create_mock_gh` | gh（GitHub CLI） |
| `create_mock_node` | node |
| `create_mock_browser` | powershell.exe / xdg-open / open / wslview / start |

> `create_mock_browser` は WSL 環境でブラウザが実際に起動することを防ぐために必須。新規スクリプトがブラウザ・GUI 系コマンドを追加した場合はこのモックに追記すること。

---

## 3. 共通ライブラリ (`lib/common.sh`) 詳細

> **構成**: `lib/common.sh` が窓口で、ログ（`log`）・実行（`run`）・終了（`die`）・`json_get` と定数を持つ。残りの関数は、責務ごとのファイルに分けてあり、`common.sh` が `source` する（呼び出し側は、これまでどおり、`common.sh` だけを `source` すればよい）。
> `lib/input.sh`（対話入力: `read_input` / `read_key` / `press_enter` / `read_or_quit` / `read_secret` / `ask_yn`）・`lib/platform.sh`（OS・外部コマンド: `is_gitbash` / `run_isolated_home` / `check_sf_cli` / `open_browser`）・`lib/project.sh`（プロジェクト: `get_target_org` / `check_force_dir` / `resolve_init_identity` / `resolve_job_identity` / `check_gh_owner` / `get_branch_list` / `is_reserved_org_alias` / `is_protected_branch` / `ensure_sf_tools_latest` / `merge_package_xml`）。テストは、すべて `tests/test_common.sh`。

全スクリプトは `source "$SCRIPT_DIR/lib/common.sh"` の前に以下を `readonly` で定義すること。

| 変数 | 役割 |
|---|---|
| `SCRIPT_NAME` | スクリプト名（拡張子なし） |
| `LOG_FILE` | ログファイルのパス |
| `LOG_MODE` | `NEW` = 上書き / `APPEND` = 追記 |
| `SILENT_EXEC` | `--verbose` / `-v` 指定時のみ 0、それ以外は 1（source 後に自動設定） |

### 3.1 主な関数

| 関数 | シグネチャ | 用途 |
|---|---|---|
| `log` | `log LEVEL MESSAGE [DEST]` | 画面・ログファイルに出力 |
| `run` | `run CMD [ARGS...]` | コマンド実行、ログ出力、戻り値判定 |
| `die` | `die MESSAGE [EXIT_CODE]` | エラーログを出力して終了 |
| `sed_inplace` | `sed_inplace SCRIPT FILE`（`lib/platform.sh`） | ファイルを、その場で置換する（GNU / BSD の sed 共通。`sed -i.bak` ＋ バックアップの削除）。`sed -i` の代わりに使う |
| `set_var` | `set_var VARNAME VALUE`（`lib/platform.sh`） | 指定した名前の変数に、値を代入する（nameref の代わり。Bash 3.2 で動く）。変数名が、英数字と `_` でなければ `die`。値は、評価しない |
| `run_with_timeout` | `run_with_timeout 秒 CMD [ARGS...]`（`lib/platform.sh`） | 時間の上限つきで実行する。`timeout` があれば使い、なければ（macOS）、背景で実行して監視する。時間切れは 124。標準入力は、そのまま渡す |
| `json_get` | `VALS=$(json_get "$JSON" パス...) \|\| ...`（複数のパスは `mapfile -t V <<< "$VALS"`） | JSON から値を取り出す（sf CLI の出力など。GitHub の情報は `gh --jq`）。Node の標準機能のみ。パスは `.` 区切り（`result.records.0.Id`。先頭の `.` は許容）。パス 1 つにつき 1 行（値なし・null は空行。値の中の改行は空白 1 つ）。まず全体を厳密に読み、失敗したときだけ最初の `{` から最後の `}` までを読む（`run` は標準エラーも標準出力に混ぜるため、sf の警告が前後に付く）。読み取れない・node がないときは終了コード 1 |
| `get_target_org` | `get_target_org [ALIAS]` | 対象組織エイリアスを解決して出力 |
| `check_force_dir` | `check_force_dir` | `force-*` ディレクトリか検証 |
| `resolve_init_identity` | `resolve_init_identity` | sf-init 用: オーナーと XXXX を、引数（`SF_INIT_OWNER` / `SF_INIT_PROJECT`）→ 対話で決め、`GITHUB_OWNER` / `COMPANY_NAME` をセット。決めた値は `SF_INIT_OWNER` / `SF_INIT_PROJECT` に export する |
| `resolve_job_identity` | `resolve_job_identity OWNER XXXX` | sf-job 用: 引数 → カレントの下のクローンの git remote（`discover_clones`）→ 対話 |
| `parse_github_remote` | `parse_github_remote URL` | GitHub の URL（HTTPS / SSH）から `owner repo` を取り出す |
| `normalize_project_name` | `normalize_project_name X` | 入力から XXXX を取り出す（先頭の `force-` を除く。使える文字: 英数字・`-`・`_`・`.`） |
| `discover_clones` | `discover_clones DIR` | `DIR/*/force-*/` のクローンの `git remote` から `owner repo` を出す（GitHub の `force-*` だけ） |
| `gh_owner_candidates` | `gh_owner_candidates admin\|member` | `gh` のログインから、オーナー候補を出す（組織 → 自分のアカウント） |
| `check_gh_owner` | `check_gh_owner OWNER` | gh 認証ユーザーがリポジトリオーナーと一致するか確認（不一致は die。オーナーが組織で、ユーザーがその有効な admin なら通過。gh が空を返す場合はスキップ） |
| （`lib/org.sh`） | `org_choose_login_url VAR LABEL TIER [SUFFIX]` / `org_read_info ALIAS` / `org_parse_info JSON` / `org_kind` / `org_guard TIER LABEL` / `org_jwt_test ALIAS KEY KEYFILE USER URL` / `org_save SUFFIX` | Salesforce 組織の接続情報の共通部品（`doc/wizard-ux-design.md` 4.7）。ログイン先は URL の 3 択（Enter = Sandbox。環境変数 `SF_INIT_LOGIN_URL_<PROD\|STG\|DEV\|START>` で、質問なしで指定できる）。ログイン後に `Organization`（`Id`・`Name`・`IsSandbox`・`OrganizationType`・`TrialExpirationDate`）を読み取り、種類（production / sandbox / developer / trial / unknown）を判定する（読み取れない・矛盾するときは unknown。推測しない）。`org_guard`: **Salesforce の本番組織は main のみ**（staging・develop に本番は、戻り値 2。**判定不能（unknown）も、main 以外は戻り値 2**。確認では通さない。main は、unknown でも続行）。`org_jwt_test`: 従来の接続アプリ用。JWT 接続テストと組織情報の読み取りを、同じ一時的なホームの中で行う（Secrets を登録する前にガードできるように）。`org_save`: 組織の ID・名前・種類・確認日時を GitHub Variables（`SF_ORG_*_<接尾辞>`）に保存 |
| （`lib/diag.sh`） | `diag_run REPO 段階...`（結果の不足の数は `DIAG_NG`） | セットアップの診断（`sf-init.sh --status` が使う）。リポジトリ・ブランチ・ワークフロー・Secrets・Variables・直近の実行を、GitHub から読み取って、✓ / ✗（直し方つき）/ ！ / ？ で表示する。読み取りのみ。一覧を取得できないものは「？」とし、不足に数えない |
| （`lib/verify-common.sh`） | `verify_pr_create` / `verify_pr_merge` / `verify_latest_run_id` / `verify_wait_pr_run`（基準の ID より新しい実行だけを対象にする）/ `verify_run_conclusion` / `verify_step_conclusion` / `verify_rerun_and_wait` / `verify_dispatch_workflow` / `verify_wait_run` / `verify_run_log_has` / `verify_branch_create` / `verify_file_put` / `verify_file_delete` / `verify_hello_*` | 実際のリポジトリの検証（`phases/init/verify.sh`）と、e2e が共有する部品。GitHub の API（ブランチ・ファイルの追加・削除）と PR・ワークフローの実行の待ち、Hello World の本文。リポジトリは引数で受け取り、操作してよいリポジトリの安全ガードは、呼び出し側が行う（e2e: `_e2e_check_repo`）。環境変数 `VERIFY_*`（`E2E_*` も使える） |
| `ensure_sf_tools_latest` | `ensure_sf_tools_latest [--no-update] DIR` | sf-tools（DIR）が origin の最新か確認し、遅れていれば確認のうえ `git pull --ff-only` で更新する。戻り値: 0=最新（または判定できない）／2=更新した（呼び出し側は、更新した sf-tools で、再実行すること）。die: fetch 失敗・遅れていて未コミットの変更または未プッシュのコミットがある・更新を断った・pull 失敗・`--no-update` で遅れている |
| `is_gitbash` | `if is_gitbash; then ...` | Windows の Git Bash か判定（`$OSTYPE` が `msys*` / `mingw*` / `cygwin*`） |
| `check_sf_cli` | `check_sf_cli [--warn-only] [--cache]` | `sf --version` の終了コードが 0 か確認する（sf は npm 版が前提）。0 以外なら、sf の場所と対処を ERROR で表示して `die`（`--warn-only` は表示のみで戻り値 1）。`--cache`（日常のコマンド用）は、成功を `~/.sf-tools-sf-check`（`SF_TOOLS_SF_CHECK_STAMP` で変更可）に sf の場所つきで記録し、24 時間は確認を省略する（失敗は記録せず、毎回確認する）。sf 未インストール・GitHub Actions 上（`GITHUB_ACTIONS=true`）では何もしない |
| `run_isolated_home` | `out=$(run_isolated_home CMD [ARGS])` | 一時的なホームフォルダ（`HOME` と `USERPROFILE` を `mktemp -d` のフォルダに）の中でコマンドを実行し、出力と終了コードを返す。終了後に一時フォルダを削除する。sf の認証・エイリアスを隔離するために使う（JWT 接続テスト） **Windows（Git Bash）以外では、`SF_USE_GENERIC_UNIX_KEYCHAIN=true` も設定する**（mac は、sf の暗号鍵を OS のキーチェーン（サービス `sfdx`・アカウント `local`）に保存する。一時ホームには `Library/Keychains` がなく、「キーチェーンが見つかりません」のダイアログが出るため。設定すると、鍵は一時ホームの `.sfdx/key.json` に保存され、一時フォルダごと消える。本物のキーチェーンには触れない） |
| `open_browser` | `open_browser URL` | OS 判定してブラウザを開く（GitBash/WSL/macOS/Linux 対応。GitBash の判定を先に行う） |
| `read_input` | `read_input VAR [PROMPT]` | readline 対応テキスト入力（矢印キー・BS 有効） |
| `read_key` | `read_key VAR [PROMPT] [VALID]` | 1文字即時入力（Enter 不要・空 Enter 無視・EOF 対応） |
| `press_enter` | `press_enter [MSG]` | Enter 待ち（q で中断） |
| `read_or_quit` | `read_or_quit VAR PROMPT` | テキスト入力（空 Enter 無視・q で中断・EOF 対応） |
| `read_secret` | `read_secret VAR PROMPT` | 秘密情報の入力（1 文字ごとに `*` を表示・BackSpace 対応・制御文字は無視・Enter のあと「N 文字を受け取りました（先頭: ghp_…）」を表示・空 Enter は再入力（端末のときは貼り付け方を案内）・q で中断・末尾の CR を除去・改行なしの EOF は確定）。Token の入力に使う（値は画面・ログに出さない） |
| `_mask_secrets` | `_mask_secrets TEXT` | `ghp_` / `gho_` / `github_pat_` / `xoxb-` などの Token らしい文字列を伏せ字にする。`run` のコマンドログに自動適用される（保険。Token はそもそも引数に含めず、環境変数・標準入力・`GIT_ASKPASS` で渡すこと） |
| `ask_yn` | `ask_yn "質問"` | Y/N/q 確認（1文字即時入力・q は `die`） |

### 3.2 `log` のレベル

`HEADER` / `INFO` / `SUCCESS` / `WARNING` / `ERROR` / `CMD`

### 3.3 `run` の戻り値

| 定数 | 値 | 意味 |
|---|---|---|
| `RET_OK` | 0 | 成功 |
| `RET_NG` | 1 | 失敗（`logs/error.log` にも記録） |
| `RET_NO_CHANGE` | 2 | `NothingToDeploy` など変更なし |

**成功判定のルール:** `run()` は、**終了コードのみ**で成否を判定する（出力の文字列では判定しない）。ただし、出力に `NothingToDeploy` / `No local changes to deploy` が含まれる場合は `RET_NO_CHANGE`（終了コードより優先）。以前（〜2026-03-23）は、出力の成功キーワード（`Success` / `Succeeded` / `Deployed` / `status": 0` など）でも `RET_OK` にしていたが、失敗を成功と誤判定する恐れがあるため、2026-03-24 に削除した。

**Salesforce CLI の前提:** Windows の Git Bash で、Salesforce CLI の公式インストーラー版（自動更新後）を使うと、`sf` が成功しても終了コード 1 を返す（`sf --version` や `sf alias unset` も 1。同じバージョンの npm 版は正しく返す）。このため sf-tools は **npm 版を前提**とし、`sf-init.sh` / `sf-start.sh` / `sf-release.sh`（`sf-deploy` / `sf-dryrun` / pre-push の検証を含む）/ `sf-metasync.sh` / `sf-update-secret.sh` の起動時に、`check_sf_cli`（`sf --version` の終了コードが 0 か）で確認し、NG なら案内を表示して**中断する**（日常のコマンドは `--cache`: 成功は 24 時間省略）。`sf` の成否は、すべて終了コードで判定する（`run` と同じ。出力の文言や、終了コードの無視による判定はしない）。`sf-install.sh` だけは `check_sf_cli --warn-only`（警告のみ）で、中断しない。中断すると、sf-tools 自身の最新化（`git pull`）まで止まるため。

**JWT 接続テストの隔離:** `sf` の認証はユーザー名単位なので、JWT 接続テスト（`sf org login jwt`）をそのまま実行すると、エイリアス（`prod` / `staging` / `develop`）が増え、同じユーザーの既存の認証が JWT の認証に置き換わる（その鍵・アプリを後で消すと、そのユーザーの `sf` が使えなくなる）。そのため、JWT 接続テスト（`init-common.sh` の `register_jwt_secret` / `register_jwt_secret_eca`、`sf-update-secret.sh`）は `run_isolated_home`（一時的なホームフォルダ）の中で実行する。ほかの場所では、この JWT 用のエイリアスは使われない（`sf-start.sh` は、ユーザーが指定したエイリアスで `sf org login web` をする）。JWT 接続テストの成否は、`run_isolated_home` の戻り値（`sf org login jwt` の終了コード）で判定する。

### 3.4 安全ガードパターン

管理者向けコマンドには2種類の安全ガードを組み合わせて使う。

#### 3.4.1 警告ボックス + `ask_yn || die`（管理者向けコマンドの冒頭）

意図しない実行を防ぐための視覚的警告と確認プロンプト。`GITHUB_ACTIONS=true` の場合はスキップして自動続行する。

```bash
# 管理者向けコマンドの冒頭パターン（sf-init / sf-metasync / sf-update-secret 等）
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    print_admin_warning --standard "GitHub Secrets を更新します。" "誤った値を設定すると CI/CD が停止します。"
    ask_yn "続行しますか？" || die "中断しました。"
fi
```

> **警告ボックスは、`print_admin_warning`（`lib/common.sh`）を使う。`echo` でボックスを直書きしない**（書き写しによる、幅のずれ・書き漏れを防ぐため）。
> - `--standard`: 先頭に「このコマンドは管理者専用です / 管理者以外は絶対に実行しないでください」を付ける（続く行があれば、空行を 1 つ挟む）
> - 行は 1 引数 = 1 行（空文字は空行）。左に空白 2 つの余白が付く。見出しは `"!!  …"`、続きの行は空白 4 つで、そろえる
> - 幅は、表示の幅（全角 2・半角 1）で、54 にそろう（`_display_width`）。確認（`ask_yn` / `wizard_confirm`）は、含まない
> - 赤色（`CLR_ERR`）で、標準エラーに出る
> - `sf-typecheck.sh` は、起動したら最初に（`--list`・`--coverage` でも）、この警告を出し、続けて確認（Y/N。`-y` で省略）をして、はじめて実行する。**警告は、必ず、確認とセットにする（表示だけで流れると、意味がないため）**

#### 3.4.2 二重確認の防止パターン

ラッパースクリプト（`sf-deploy.sh`）から被呼び出しスクリプト（`sf-release.sh`）を呼ぶ場合、警告・確認が二重に表示されるのを防ぐ。

```bash
# ラッパー側（sf-deploy.sh）
export SF_DEPLOY_CONFIRMED=1
exec bash "$SCRIPT_DIR/sf-release.sh" --release --force "$@"

# 被呼び出し側（sf-release.sh）
if [[ "${GITHUB_ACTIONS:-false}" != "true" \
    && "$IS_VALIDATE_MODE" -eq 0 \
    && "${SF_DEPLOY_CONFIRMED:-0}" != "1" ]]; then
    # 警告ボックス + ask_yn
fi
```

**スキップ条件まとめ:**

| 条件 | 意味 |
|---|---|
| `GITHUB_ACTIONS=true` | GitHub Actions WF 実行中 → 全スキップ |
| `SF_DEPLOY_CONFIRMED=1` | ラッパー経由の呼び出し → 被呼び出し側スキップ |

#### 3.4.3 `check_gh_owner`（gh 認証ユーザー確認）

`gh` コマンドを使うすべての管理者向けスクリプトは、リポジトリオーナーが確定した直後に `check_gh_owner` を呼び出す。認証ユーザーがオーナーと一致しない場合は `die` で即終了する（`die` のメッセージは事実のみで、復旧案内は含めない）。ただし、オーナーが組織で、認証ユーザーがその組織の有効な管理者（`role=admin` かつ `state=active`）である場合は通過する。

```bash
resolve_init_identity        # GITHUB_OWNER / COMPANY_NAME をセット（引数 → 対話）
check_gh_owner "$GITHUB_OWNER"   # 認証ユーザーの一致確認
```

- 組織の管理者判定は `gh api user/memberships/orgs/<オーナー>` の `role` と `state` で行う。API が失敗した場合は通過させず `die` する（安全側）
- gh が空を返す場合（ネットワーク障害・未認証）はチェックをスキップして続行する
- `sf-init.sh` / `sf-job.sh` のフェーズサブスクリプトは、メインスクリプトで確認済みのため個別呼び出し不要

---

## 4. スクリプト別処理概要

### 4.1 sf-start.sh

- 接続先組織を確認し、必要なら `sf org login web`（WSL では wslview シムを一時生成してブラウザ起動）
- `.sf/config.json` / `.sfdx/sfdx-config.json` を更新
- `code .` で VS Code を起動
- バックグラウンドで `sf-install.sh` を実行（フック・リリースDir準備・ツール更新はすべて sf-install.sh が担当）
- 完了後に `sf-launcher.sh` を起動（`SF_LAUNCHER_ACTIVE=1` で二重起動を防止）

`FORCE_RELOGIN=1` を付けると再ログインを強制できる。

### 4.2 sf-release.sh

- ターゲットファイルをもとに `package.xml`（と、削除用の `destructiveChanges.xml`）を生成
- `sf project deploy start` で検証または本番実行

**マニフェストの生成（`generate_manifest`）:** `[files]`（`--source-dir`）と `[members]`（`--metadata`）は、**別々に** `sf project generate manifest` で生成し、`merge_package_xml`（`lib/project.sh`）で 1 つに統合する。
理由: `sf project generate manifest` は、`--source-dir` と `--metadata` を同時に渡すと、両方の**共通部分だけ**を返す（重なりがなければ `<types>` のない空のマニフェストになり、しかも成功として終わる）。
空のマニフェストでは、`sf project deploy start` が `NothingToDeploy` を返し、sf-release.sh は「変更がないため処理をスキップしました」と成功扱いにしていたため、
`[files]` と `[members]` を混在させたリストは、検証もリリースもされないまま、緑になっていた（`sf-init.sh --verify --components` で発見）。
統合後に `<members>` が 1 つもなければ、エラーで中断する（`NothingToDeploy` の成功扱いにしない）。
**`remove-target.txt` の指示行 `# @ignore-missing`**（コメント行の形）: あるときだけ、`sf project deploy start --ignore-warnings` を付け、組織に存在しない削除対象を、エラーにしない。後始末（`sf-init.sh --verify --cleanup`）用。通常のリリース・削除には、付けない。
`merge_package_xml` は、awk と sort だけ（GNU / BSD 共通）。種類は名前の順・メンバーは重複なし・version は最初のもの。
テスト: `tests/test_sf-release.sh`（混在・`[members]` のみ・`[files]` のみ・空のマニフェスト）、`tests/test_common.sh` の `test_merge_package_xml`。`tests/test_helper.sh` の sf のモックは、実際の sf と同じく、両方を同時に渡すと空になる。

主なオプション: `--release` / `--no-open` / `--force` / `--target`

**共有環境の保護（5.1）:** 接続先のエイリアスが予約名（`prod` / `staging` / `develop` / `main`。`is_reserved_org_alias`）なら、ローカル（`GITHUB_ACTIONS` が `true` 以外）からは `die` する（dry-run を含む）。共有環境へのリリースは、GitHub Actions だけ。

**安全ガード（セクション 3.4）:**
ローカル実行 + `--release` + `SF_DEPLOY_CONFIRMED!=1` の条件をすべて満たす場合のみ、確認（`ask_yn`。赤い警告ボックスは、なし）を実行する。`GITHUB_ACTIONS=true` / validate モード / `SF_DEPLOY_CONFIRMED=1`（sf-deploy.sh 経由）の場合はスキップ。

`@isTest` 自動検出フロー:
1. `phase_generate_manifest` 内で `deploy_args` を走査し、`--source-dir` に続く `.cls` ファイルを `grep -qi "@isTest"` で検査
2. 検出されたクラス名をスクリプトレベル変数 `RUN_TESTS=()` に追加
3. `phase_release` で `${#RUN_TESTS[@]} -gt 0` の場合、`--test-level RunSpecifiedTests` と、クラスごとの `--tests <クラス名>`（繰り返し。`--run-tests` は存在しないフラグ）を `deploy_cmd` に追加して実行
4. テストクラスが 0 件の場合は従来通り（`--test-level` 未指定）の動作を維持

### 4.3 sf-metasync.sh

- 本番組織でのみ実行可（Sandbox に接続中の場合はエラー終了）
- main ブランチを最新化して差分を抽出
- `sf sgd source delta` で変更差分を算出
- 差分対象メタデータを retrieve
- 変更があれば commit / push / PR 作成まで進める

**安全ガード（セクション 3.4）:**
- メインフロー先頭で赤い警告ボックス + `ask_yn || die`（`GITHUB_ACTIONS=true` 時はスキップ）
- `phase_git_sync` のコミット直前: `GITHUB_ACTIONS=true` でなければ `git status --short` を表示し `ask_yn` で確認

### 4.4 sf-install.sh

処理順（順序変更禁止）:
0. `check_sf_cli --warn-only`（`sf --version` の終了コードを確認し、0 以外なら警告のみ。中断しない。`sf-tools` 自身の最新化を止めないため）
1. `~/sf-tools` を `git pull` で更新
2. `config/*.txt` を不足時のみ補充
3. `sf-hook.sh` で Git Hook をインストール
4. `release/<branch>/` と `branch_name.txt` を準備
5. `package.json` がある場合は `npm install`（`sf-init.sh` から実行中（`SF_INIT_RUNNING` あり）は、初期セットアップ用の一時フォルダなのでスキップする。約 90 秒の短縮）
6. 24 時間以上経過していれば `sf-upgrade.sh` をバックグラウンド起動

### 4.5 sf-next.sh

現在の feature ブランチが各ターゲットブランチにどの状態かを判定し、次に PR を出すべきブランチを案内する。

表示ステータス一覧:

| 記号 | ステータス | 説明 |
|---|---|---|
| `✓` | マージ済み | 直接 PR をマージ済み（デプロイ WF 実行済み） |
| `✓` | マージ済み（ブランチ同期） | 直接 PR はないが上位ブランチ経由でコード伝播済み。**デプロイ WF は未実行** |
| `⚠` | マージ済み（順序外） | 前のブランチの直接 PR が完了する前にマージ済み。**前のブランチのデプロイは未実行** |
| `→` | PR発行中 | PR を発行済み（マージ待ち） |
| `▶` | 次のPR先 | 次に PR を出すべきブランチ |
| `✗` | 未着手 | まだ PR を出していない |

判定ロジック（優先順）:
1. `gh pr list --state merged` で直接 PR のマージ済みを確認 → `merged`
2. `git merge-base --is-ancestor` で間接伝播（上位ブランチ経由）を確認 → `synced`
3. `gh pr list --state open` で PR 発行中を確認 → `pr_open`
4. いずれも該当なし → `none`（NEXT_TARGET に設定）

ステータスと表示:
- `merged` → `✓ マージ済み`
- `synced` → `✓ マージ済み（ブランチ同期）`（デプロイ WF 未実行）
- `out_of_order` → `⚠ マージ済み（順序外）`（前に synced/pr_open/none があった merged）
- `pr_open` → `→ PR発行中`
- `none` かつ NEXT_TARGET → `▶ 次のPR先`
- `none` → `✗`

順序外マージの制約:
`develop → staging → main` の順番を守らずにマージした場合、スキップしたブランチへのデプロイは**永久にできない**。
- 上位ブランチ（例: main）にマージすると、コードが下位ブランチ（例: staging）に伝播する
- 伝播後は「差分なし」となり、feature → staging の直接 PR が作成できなくなる
- GitHub Actions のデプロイ WF は直接 PR のマージイベントで起動するため、伝播では WF が動かない
- スキップしたブランチにデプロイしたい場合は、新しいブランチを切って改めて順序通りに PR を出し直す

### 4.6 sf-dryrun.sh

- `sf-release.sh` のラッパー（オプションなし = dry-run がデフォルト）
- ランチャーから呼ばれる dry-run 専用コマンド
- `--release` を転送した場合は sf-release.sh の安全ガード（セクション 3.4）が働く

### 4.7 sf-launcher.sh

- `sfl` コマンドで起動するメニュー形式ランチャー
- `lib/common.sh` を source しない standalone 設計（ログ不要・カラー定義を独自に持つ）
- VSCode 内では `sf-start` / `sf-restart` をメニューから除外（`$TERM_PROGRAM == "vscode"` で判定）
- `SF_LAUNCHER_ACTIVE=1` をエクスポートして `sf-start.sh` からの二重起動を防止
- `sflf` エイリアスで fzf モードも利用可能

### 4.8 sf-deploy.sh

- `sf-release.sh --release --force` のラッパー
- `force-*` 以外では実行禁止
- `main` / `staging` / `develop` ブランチでは実行禁止
- **安全ガード:** `log "WARNING"` で `--force` の意味を表示 → `ask_yn || die` で続行確認（**赤い警告ボックスなし**。赤いボックスは、管理者向けの sf-init / sf-metasync / sf-update-secret / sf-sync-wf / sf-typecheck のみ（print_admin_warning））
- `export SF_DEPLOY_CONFIRMED=1` で sf-release.sh 側の二重確認を抑制
- **共有環境には、ローカルからリリースできない。** 用途は、個人用の Sandbox / Developer Edition / Scratch Org への強制リリース。共有環境（本番・staging・develop）は、GitHub にコミットし、レビューを通して、GitHub Actions で行う。そのため、接続先のエイリアスが予約名（`SF_RESERVED_ORG_ALIASES` = `prod` / `staging` / `develop` / `main`。`is_reserved_org_alias`、`lib/common.sh`）なら、**確認の前に** `die` する（`-t` / `--target` の指定、なければ `SF_TARGET_ORG`、接続中の組織の順で特定。`GITHUB_ACTIONS=true` ではスキップ）。`sf-release.sh` の 5.1 も、同じ関数で判定する
- `-t` / `--target` の解析規則は、`sf-deploy.sh`（事前判定）と `sf-release.sh` で同じ: 値（エイリアス）が無い、または `-` で始まる値（次のオプションを取り込む指定）は `die`。`--target=ALIAS` 形式は、どちらも未対応（`sf-deploy.sh` は確認の前に `die`、`sf-release.sh` は「不明なオプション」）。`GITHUB_ACTIONS=true` による解除は、ローカルで設定すれば誰でも解除できるが、これは誤操作を防ぐための設計（悪意ある回避は対象外。共有環境への実際の認証情報は、GitHub Secrets にあり、手元にはない）
- 名前で判断する設計（組織の種別や組織 ID は確認しない）。`sf-init` が付ける名前が `prod` / `staging` / `develop`、`sf-start.sh` は `prod` 以外のエイリアスに Sandbox 用のログイン URL を使うため、通常の流れでは、本番に接続できるのは `prod` のときだけ。予約名以外の名前に付け替えた場合は、動作を保証しない（2026-10-05 に、予約名に `prod` が含まれていなかった不具合を修正）
- 確認の `N` / `q` は、`ask_yn ... || die` で中断する（2026-10-05 に修正。以前は `|| die` が無く、`N` でも実行されていた）

### 4.9 sf-upgrade.sh

- npm / Salesforce CLI / Git を更新
- Salesforce CLI は、npm 版（`npm ls -g @salesforce/cli` が成功）なら `npm install -g @salesforce/cli@latest`、それ以外（公式インストーラー・pkg など）なら `sf update` で更新する
- `sf-install.sh` から 24 時間間隔でバックグラウンド起動される
- Git の更新は GitBash（`is_gitbash`: `$OSTYPE` が `msys*` / `mingw*` / `cygwin*`）のみ実行（他環境はパッケージマネージャーを案内）

### 4.10 sf-push.sh

カレントディレクトリ配下だけをコミット＆プッシュする。実行フロー（順序は変更禁止）:

1. origin/main を fetch して現在ブランチにマージ（main ブランチ自身はスキップ）
   - コンフリクト発生時は `merge --abort` してエラー中止
2. カレント配下だけを `git add --all`
3. 変更なしなら WARNING で正常終了
4. `sf-check.sh` でターゲットファイルを検証（エラーなら中止）
5. VS Code を別ウィンドウで開いてコミットメッセージを入力
6. メッセージ未入力なら何もせず正常終了
7. `git commit` → `git push`

### 4.11 sf-update-secret.sh

GitHub Secrets / Variables の JWT 認証情報を再登録する。実行フロー（順序は変更禁止）:

1. `force-*` ディレクトリかチェック
2. git remote から対象リポジトリ（OWNER/REPO）を自動取得
3. `check_gh_owner` で gh 認証ユーザーを確認（不一致は die。オーナーが組織で、ユーザーがその有効な admin なら通過）
4. 赤い警告ボックス + `ask_yn || die`（管理者向け確認）
5. メインメニューで操作を選択 `[1-4/q]`（1文字即時選択）:
   - 1: 秘密鍵（`SF_PRIVATE_KEY` Secret）を更新
   - 2: コンシューマキー（`SF_CONSUMER_KEY_*` Secret）+ ユーザー名（`SF_USERNAME_*` Variable）+ インスタンス URL（`SF_INSTANCE_URL_*` Variable）を組織ごとに更新
   - 3: ユーザー名（`SF_USERNAME_*` Variable）を組織ごとに更新（現在値を `gh variable get` で自動取得して表示）
   - 4: すべて更新（1〜3 を順に実行）
6. 組織選択は `branches.txt` の有効行数（1〜3）に応じて動的に変化:
   - 1行: PROD のみ `[1/q]`
   - 2行: PROD + STG `[1-2/q]`
   - 3行: PROD + STG + DEV `[1-3/q]`

**Secret と Variable の使い分け:**

| 種別 | キー名 | 登録先 | 理由 |
|---|---|---|---|
| 秘密鍵 | `SF_PRIVATE_KEY` | Secret | 漏洩リスクあり |
| コンシューマキー | `SF_CONSUMER_KEY_PROD` 等 | Secret | 漏洩リスクあり |
| ユーザー名 | `SF_USERNAME_PROD` 等 | Variable | 参照用・読み取り可 |
| インスタンス URL | `SF_INSTANCE_URL_PROD` 等 | Variable | 参照用・読み取り可 |
| Slack チャンネル | `SLACK_CHANNEL_ID` | Variable | 参照用・読み取り可 |

> Secret は暗号化されており `gh secret get` で値を読み取れないが、Variable は `gh variable get` で取得できる。ユーザー名はメニュー表示時に現在値を自動取得して表示する。

> `SF_TOOLS_TOKEN` は不要（2026-10-05 に廃止）。`sf-tools` は公開リポジトリのため、wf-metasync / wf-validate / wf-release は、Token なしで `https://github.com/tama-create/sf-tools.git` を clone する（`sf-init.sh` の Phase 11 は無い。以前のバージョンで作ったプロジェクトのワークフローは、Token 付きで clone しているため、その Token を無効にしないこと）。`SF_TOOLS_BRANCH`（Variable）は、sf-init.sh を環境変数 `SF_TOOLS_BRANCH=development` 付きで実行した場合のみ `phases/init/09_repo_rules.sh` が `development` を登録する（検証環境用）。未設定なら Actions は `main` を clone する。

**SF_PRIVATE_KEY の base64 エンコーディング:**
GitHub Actions のワークフローは Secret から取得した値を `base64 -d` でデコードして使用する。そのため `SF_PRIVATE_KEY` は **base64 エンコード済みの文字列** として登録しなければならない。`sf-update-secret.sh` の `_update_private_key` は以下のパイプで登録する:

**ワークフローを書くときの規約（スクリプトの注入の防止。2026-10-06）:** PR のタイトル・ブランチ名（`github.event.pull_request.title` / `head.ref` / `base.ref`、`github.ref_name`）や、そこから作った Step の出力など、**利用者が決められる値は、`run:` のシェルや、`github-script` の JavaScript に、`${{ }}` で直接埋め込まない**。`env:` で環境変数に渡し、スクリプトでは `$変数` / `process.env.変数` で参照する（ブランチ名・PR のタイトルには、`"`・バッククォート・`$( )` などが入れられるため。直接埋め込むと、通知のステップが壊れる、または、任意のコマンドが実行される）。Slack に送る JSON には、値を `json_escape`（`"` と `\` のエスケープ・制御文字の除去・`& < >` の置き換え）に通して入れる。JWT の秘密鍵の一時ファイルは、`umask 077` で作り、`trap 'rm -f /tmp/server.key' EXIT` で、失敗しても消す。`tests/test_sf-init.sh` の `test_wf_no_script_injection` が、直接の埋め込みが無いことを確認する。**既存の `force-*` には、自動では届かない**（配布用の `sf-sync-wf.sh`（4.15）で、管理者が、各リポジトリに、手動で反映する）

```bash
tr -d '\r' < "$key_file" | base64 -w 0 | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME"
```

> `tr -d '\r'` は Windows 改行コード（CRLF）を除去するため。`-w 0` は base64 の折り返しなし（1行）。

**JWT 接続テスト（内部処理）:**
`sf org login jwt` の成否は、終了コードで判定する（`sf` は npm 版が前提）。実行コマンドと出力はログに記録する（コンシューマー鍵は伏せ字）。

### 4.12 sf-hook.sh / sf-unhook.sh

- `sf-hook.sh`: `.git/hooks/pre-push` と `.git/hooks/pre-commit` を上書き生成し、`~/sf-tools/hooks/` からコピーする
- `sf-unhook.sh`: `.git/hooks/pre-push` を削除する

### 4.13 sf-init.sh

新規 Salesforce プロジェクトの初期セットアップ。`phases/init/` 配下のフェーズスクリプトを順次実行する。

**オーナーと XXXX の決め方（フォルダ構成に依存しない）**: リポジトリ名は `force-XXXX`（`force-` は固定、XXXX は管理者が決める）。作業フォルダは、どこでもよい。`resolve_init_identity`（`lib/project.sh`）が、①引数 `--owner` / `--project`（環境変数 `SF_INIT_OWNER` / `SF_INIT_PROJECT`）→ ②対話（オーナーは `gh` から候補、XXXX は入力。`force-` は自動で付く旨を案内し、既存プロジェクトを参考に表示）の順で決める。決めた値は `SF_INIT_OWNER` / `SF_INIT_PROJECT` に export し、Phase 2 と、sf-tools 更新後の再実行に引き継ぐ（Phase 2 は、この 2 つが必須）。管理者用の作業フォルダは `admin`（固定）。同じ `admin` に複数プロジェクトを置くため、状態ファイルは `.sf-init-XXXX.env` / `.sf-init-XXXX.progress`（XXXX = プロジェクト名）とプロジェクトごとに分ける。Phase 1 は `admin` だけを許可する。`sf-job.sh` は、①引数 → ②`{cwd}/*/force-*` のクローンの `git remote` → ③対話で決め（`resolve_job_identity`）、`admin` / `force-*` の中では実行できない。重複判定は、`{ジョブ}/force-XXXX` の有無（同じジョブ名でも、別のプロジェクトなら重複にしない）。

起動時（フェーズの実行・`--resume` / `--only` / `--add-tier` の前）に `check_sf_cli` で、`sf --version` の終了コードを確認し、0 以外なら案内（npm 版への入れ替え）を表示して中断する（3.3 参照）。
**ウィザード形式の画面（`lib/wizard.sh`・設計: `doc/wizard-ux-design.md`）:**
- 利用者に見せるのは、Phase の番号ではなく、**全 9 ステップ**（`WIZ_STEP_TITLES`。ステップ 9 は「動作の確認」で、Phase ではなく、`phases/init/verify.sh` を呼ぶ最後のステップ）。Phase とステップの対応は `WIZ_PHASE_STEP`（1→1, 2→2, 3・4→3, 5→4, 6→5, 7→6, 8・9→7, 10→8）。フェーズループが、新しいステップに入るときに `wizard_step`（現在地・完了済み・目的の 1 文）を出す。各 Phase スクリプトの見出しからは、「Phase N」を外した。
- 開始画面（通常の新規実行のみ。`--only` / `--resume N` は従来の簡易表示）: `wizard_banner` → 作るもの・所要時間の目安 → 管理者向けの警告ボックス（従来どおり）→ `wizard_checklist`（先に用意するもの）→ 全ステップの一覧 → `wizard_confirm`（Enter / Y で進む。N / q は die。CLAUDE.md 2.4 の `ask_yn || die` と同じく、「N / q で必ず中断」）。`resolve_init_identity` は、開始画面の前に実行する（作るリポジトリ名を表示するため）。
- sf-tools の最新化（P14）: 開始画面の、**管理者向けの警告のあと・確認の前**に、**現在のブランチを対象に** `ensure_sf_tools_branch` を呼ぶ（本番 / 検証の選択には依存しない。Git リポジトリのときだけ）。遅れていれば、確認のうえ `git pull --ff-only` し、戻り値 2 を返す。`sf-init.sh` は、`SF_INIT_RESTARTED=1` を付けて、同じ引数で `exec` する（実行しなおしたあとも、開始画面・管理者向けの警告・確認は、毎回出す。確認を飛ばさない）。確認済みのブランチは `SF_INIT_TOOLS_CHECKED_BRANCH` で Phase 2 に渡し、Phase 2 は、最新化を二重に確認せず、選んだ環境とのブランチ違いだけを確認する。Phase 2 が戻り値 2 を受けたとき（起動時に確認できなかった場合）は、終了コード 75 で終了し、`sf-init.sh` が実行しなおす。**実行しなおしは 1 回だけ**（`SF_INIT_RESTARTED` が立っているのに、再び 75 なら、die。無限に繰り返さない）。
- 完了画面: `wizard_done`（できたこと・次にやること: `sf-job.sh` と、リポジトリの URL）。`admin` フォルダは、**削除せず、管理者用として残す**（削除の質問は廃止）。完了画面に、管理者用フォルダ（`REPO_DIR`）のパスと用途（メンテナンス用・日常の開発には使わない）を表示する。完了時（`END_PHASE` が 10 のときだけ）、`.sf-init.env` から `*TOKEN_VALUE=` の行を念のため消す（通常は Phase 8 の push 後に消えている）。**そのあと、状態ファイル（`.sf-init-XXXX.env` / `.sf-init-XXXX.progress`）を削除する**（`--only` のないとき。完了後は、読む場所がないため。完了画面に使う値は、削除の前に読み込み済み）。途中で止まったときは、続きをやるために残る。
- **管理者用のクローンの `admin` ブランチ**: 動作の確認（verify.sh）のあと、完了画面の前に、`ensure_admin_branch REPO_DIR`（`lib/project.sh`）で、クローンを `admin` ブランチにし（`main` から作る。すでにあれば、作り直さず切り替える）、続けて `push_admin_branch REPO_DIR` で GitHub にも作る（`git push --no-verify -u origin admin`。`--no-verify` は、`add_tier.sh` と同じく、管理者による自動の操作のため、pre-push の検証を省く。強制 push はしない: GitHub 側の `admin` と食い違うときは失敗にする）。理由: 管理者の変更は「`main` を取り込む → 変更 → push → PR」で GitHub に反映するため、最初から両方に同じ `admin` を置く。`END_PHASE` が 10 のときだけ。どちらに失敗しても、セットアップは成功のままで、警告と、完了画面の案内（`git switch -c admin` / `git push -u origin admin`）で知らせる。理由: `main` は保護ブランチで、管理者用のクローンが `main` のままだと、その上で作業してしまう（`sf-sync-wf.sh` も、保護ブランチでは実行を断る）。`phases/init/add_tier.sh` は、実行前のブランチを覚え、終わったら、そこへ戻る（以前は `main` で終わっていた）。`sf-metasync.sh` は、元から、終了時に実行前のブランチへ戻る（trap）。`admin` ブランチは、`main` から古くなる（`main` へのマージを取り込まない）。`admin` で、ワークフローの雛形などを見る前には、`main` を取り込むこと（完了画面にも、`git pull origin main` を案内する）。
- 失敗時: `wizard_fail` で、「どこから再開されるか」を、利用者向けの名前で出す（再開の単位は、Phase の先頭）。`die` は、事実のみ（従来の規約）。
- テスト: `tests/test_wizard.sh`（部品）、`tests/test_sf-init.sh` の happy path（開始画面・見出し・完了画面）と `test_sf_tools_autoupdate`（本物の git で、更新 → 自動で実行しなおし）。

実行フロー:
1. 環境チェック（ツール確認・GitHub CLI 認証確認）
2. プロジェクト情報の確認（フォルダ構成から自動導出）→ `.sf-init.env` に書き出し
3. リポジトリ作成（gh repo create + git clone）
4. ファイル生成（sf-install.sh / sf-hook.sh）
5. ブランチ構成（対話選択 → branches.txt 更新）
6. PAT_TOKEN の設定（`phases/init/06_pat_token.sh`。force-* のリポジトリ用の Token であり、sf-tools（公開リポジトリ）とは無関係）。流れ: Token を作るべきアカウント（`REPO_FULL_NAME` のオーナー。組織なら管理者）を表示 → `ask_yn`「発行済みの Token がありますか？」（Y: ブラウザを開かず、使い回しの注意を表示 / N: 手順を表示し `open_browser` + `press_enter`）→ `read_secret`（画面に表示しない）→ `verify_pat_token`（Token は環境変数 `GH_TOKEN` で `gh` に渡し、コマンドの引数に出さない。①`gh api user --jq .login` で認証できるか ②`gh api user --include` の `X-OAuth-Scopes` に `repo`・`workflow` があるか〔ヘッダーがない Fine-grained は不可〕 ③`gh api repos/<REPO_FULL_NAME> --jq .permissions.admin` が `true` か〔個人ならオーナー、組織なら組織の管理者〕。NG なら理由を表示し、3 回まで貼り直し。超えたら die）→ `gh secret set PAT_TOKEN` → `.sf-init.env` に `PAT_TOKEN_VALUE` を書き出し（Phase 8 の push で使用）
7. Slack 連携の設定（SLACK_BOT_TOKEN を Secret / SLACK_CHANNEL_ID を Variable に登録。チャンネル ID は C または G で始まる形式かを検証し、それ以外（D=DM、U=ユーザーなど）は警告して拒否し、入力し直させる。通知先は全員が参加する共有チャンネルのため）
8. 初回コミット＆プッシュ（PAT は GIT_ASKPASS で渡しコマンドのログに残さない。push 後に .sf-init.env から PAT を削除する）
9. GitHub リポジトリ設定・Ruleset の適用（既存 Ruleset の ID は数字のときだけ削除対象にする）
10. JWT 認証情報の設定（SF_PRIVATE_KEY / SF_CONSUMER_KEY_* を Secret / SF_USERNAME_* / SF_INSTANCE_URL_* を Variable に登録）。アプリ種別が外部クライアントアプリ（2）のときは、組織ごとに `register_jwt_secret_eca`（`init-common.sh`）が自動作成する（`sf org login web` → ユーザー名・プロファイル名（表示名）を取得 → `generate_eca_metadata` で 5 ファイルを生成して `sf project deploy` → `sf project retrieve` でコンシューマー鍵を取得 → JWT 接続テスト（反映待ちのためリトライ。`SF_INIT_JWT_RETRIES` / `SF_INIT_JWT_INTERVAL`）→ 登録）。ログイン用の一時エイリアス（`sf-tools-PROD` / `sf-tools-STG` / `sf-tools-DEV`。ユーザーが運用中のエイリアスと重ならないよう `sf-tools-` を付ける）は、ログイン前に `sf alias unset` で外し（前回の古い認証による誤判定の防止）、終了後にも `sf alias unset` で消す（`sf org logout` は同じユーザー名の全エイリアスの認証を消すため使わない）。`sf` は npm 版が前提（Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）。ログイン（`sf org login web`）、接続情報の取得（`sf org display --json`。ユーザー名はその出力から取り出す）、プロファイル名の取得（`sf data query`）、JWT 接続テストの成否は、すべて終了コードで判定し、0 以外なら中断する（JWT 接続テストはリトライ後、スキップの確認）。接続アプリ（1）は従来の手動案内

- **最初のメタデータの同期（`initial_metadata_sync`: `phases/init/init-common.sh`）**: Phase 10 のあと（動作の確認・`admin` ブランチの作成より前）に、`wf-metasync` を実行して、管理者用のクローンに取り込む。初期コミットの `force-app` は空のひな型で、何もしないと、メタデータは次の定期実行（平日 UTC 0・3・6・9 時）まで入らない。クローン（Phase 3）は初期コミットの push に必要なため、同期（Phase 10 の接続情報が必要）より先になる。そこで、同期のあとに `git pull` する（作り直したクローンと同じ結果）。動作: `verify_dispatch_workflow`（`lib/verify-common.sh`）で手動起動 → `SF_INIT_SYNC_TIMEOUT` 秒（既定 1200）まで、30 秒おきに経過を表示して待つ → `verify_run_conclusion` が success → クローンを `main` にして `core.longpaths=true` を設定し、`git pull --ff-only origin main`。実行は `END_PHASE` が 10 で、`--only` がなく、Phase 10 を実行したときだけ。失敗（起動できない・時間切れ・同期の失敗・pull の失敗）しても、`SYNC_RESULT=failed` として警告にとどめ、完了画面に「すぐ同期するには: `gh workflow run wf-metasync.yml -R …`（終わったら `git pull origin main`）」を出す。成功なら `SYNC_RESULT=done`（完了画面: 「同期済みです」）。動作の確認（`verify.sh`）を実行したときは、`admin` ブランチを作る直前に、もう一度 `git pull --ff-only origin main`（Hello World のリリースと削除が `main` に入るため）。Phase 3 の `git clone` には `-c core.longpaths=true` を付ける（Windows のパス長の上限対策。`sf-job.sh` と同じ）。テスト: `tests/test_sf-init.sh`（モックの gh が `workflow run` / `run list`（`--event workflow_dispatch`）/ `run view` に答える。`VERIFY_POLL_SEC=0`。成功・起動失敗・同期失敗）。
**進捗の記録と「続きから」の選択（`bin/sf-init.sh`）:**
- フェーズループで、Phase 2 以降が成功するたびに、**`admin/.sf-init-XXXX.progress`**（入力内容を保存する `.sf-init.env` とは別のファイル）を、`SF_INIT_DONE_PHASE=N` と `SF_INIT_DONE_AT="日時"` の 2 行で書き直す（外部コマンドを使わない）。Phase 1 は状態を持たないため記録しない。`--only` は記録しない。失敗した Phase は記録されない。Phase 10 の実行中は、段階ごとの完了（`SF_INIT_DONE_TIER_*`）が、追記される。
- 引数なしで起動し、`.sf-init-XXXX.env` と `.sf-init-XXXX.progress` があり、`SF_INIT_DONE_PHASE` が 2〜9 で、`REPO_FULL_NAME` が `${GITHUB_OWNER}/force-${COMPANY_NAME}`（作業フォルダのもの）と一致するとき、管理者警告・`check_gh_owner`・admin フォルダへの移動のあとに、`read_key` で `[1] 続き / [2] 最初から / [q] 中断` を選ばせる（既定値なし）。
  - `1`: `START_PHASE=N+1`、`RESUMED=1`。`.sf-init.env` は消さない。Phase 1（環境チェック）を、先頭に付け足して、毎回実行する。
  - `2`: 従来どおり `.sf-init.env` を削除して Phase 1 から。リポジトリ・admin フォルダは削除しない（Phase 3 が冪等のため）。
  - `q`: `die`。
- `SF_INIT_DONE_PHASE` が `10`（完了済み）で、リポジトリが一致するとき: 続きの選択肢の代わりに「セットアップが、すでに完了しています」を表示し、`[1]` 管理者用フォルダ（`REPO_DIR`）で `phases/init/status.sh` を実行して終了（何も変更しない）／`[2]` 管理者用フォルダで `phases/init/verify.sh` を実行し、その終了コードで終了（確認は phases/init/verify.sh の中で聞く）／`[3]` 最初からやり直す（上の `2` と同じ）／`[q]` 終了、を選ばせる。
- **ステップ 9（動作の確認）**: **通しの実行（`FULL_START`）と、中断後の「続きをやる」のときだけ**、最後（`END_PHASE` が 10）まで実行し、`GITHUB_ACTIONS` でなく、端末（`-t 0`。テストは `SF_INIT_VERIFY_ASK=1`）のとき、完了処理（Token の値の行の掃除）のあと、完了画面の前に、`read_input` で「Enter = 確認する / s = あとで」を聞く（EOF は「あとで」）。`--resume N` / `--only N` の明示では、聞かない。Enter なら、`(cd "$REPO_DIR" && SF_VERIFY_CONFIRMED=1 bash phases/init/verify.sh)`。結果（`VERIFY_RESULT`: done / failed / skipped）は、完了画面の 4 番目の項目に表示する。確認の失敗は、sf-init の終了コードに影響しない。進捗（`.sf-init.progress`）には、記録しない（Phase ではないため）。
- **完了済みで `--resume N`**: `SF_INIT_DONE_PHASE` が `10` で、リポジトリが一致するとき、`--resume N`（N > 1）は、`die`（接続処理などを、確認なしで、やり直さないため）。案内: `--reconnect` / 引数なしの実行（[1] 接続を見る・[2] 動作を確認・[3] 最初から）。`--only N` は、拒否しない（デバッグ用）が、開始時に「進捗は、更新しない」を表示する。
- **Phase 10 の段階ごとの再開**（`10_sf_auth.sh` の `_register_org` / `_tier_done`）: 段階（PROD / STG / DEV）が完了するたびに、`.sf-init.progress` に `SF_INIT_DONE_TIER_<接尾辞>=1` を追記する（`SF_INIT_TIER_RESUME=1` のとき。`--only` では、設定されず、記録も、スキップも、しない）。再実行では、その記録があり、かつ、`gh secret list` に `SF_CONSUMER_KEY_<接尾辞>` が、いまもあるときだけ、その段階をスキップする（記録だけを信じない）。Phase 10 が成功したとき、`sf-init.sh` が進捗ファイルを書き直すため、段階の記録は、消える。「最初から」では、進捗ファイルごと消えるため、すべての段階を、実行する。外部クライアントアプリは、名前が決まっている（`SF_TOOLS_<リポジトリ名>`）ため、やり直しても、重複しない。
- **完了済みのプロジェクトの判定（`_project_completed`）**: 完了時に状態ファイルを消すため、状態ファイルではなく、**クローンで判定する**。状態ファイルがないとき、`${admin}/force-XXXX` が Git のクローンで、`origin` が `${GITHUB_OWNER}/force-${COMPANY_NAME}` と同じなら（`clone_matches_repo`: `lib/project.sh`）、完了済み。状態ファイルがあるときは、進捗が 10 で、リポジトリが一致すること（以前の版が残したもの）。進捗が 2〜9 は、完了済みではない（続きをやる、の対象）。完了済みのときの案内（`[1]` 接続を見る / `[2]` 動作を確認 / `[3]` 最初から）と、`--resume N` の拒否は、この判定を使う。対話で XXXX を入力するとき、すでにあるプロジェクトでも、この作業フォルダに、同じリポジトリのクローン（`admin/force-XXXX`）があれば、断らずに受け付け、次の画面で、この案内を選べる（クローンがなければ、断る）。
- 質問しない場合: 状態なし（クローンもなし）・別のリポジトリの状態（従来どおり `.sf-init-XXXX.env` を削除して最初から）、`--resume N` / `--only N` の指定あり。
- Phase 3 以降が失敗したときは、`die`（事実のみ）の前に、「もう一度 sf-init.sh を実行し、『続きをやる』を選ぶと、Phase N から再開できます」を INFO で表示する。
- 値の取り出しは `source` せず、`_env_value KEY`（grep + sed）で行う。
- テスト: `tests/test_sf-init.sh` の `test_resume_choice`（[1]・[2]・q・質問が出ない条件・`--resume`・`--only`）。happy path と Phase 10 失敗のテストにも、記録の確認がある。

オプション:
- `--resume N`: Phase N から、質問なしで再開
- `--only N`: Phase N のみ実行（デバッグ用。進捗は記録しない）
- `--add-tier staging|develop`: 既存プロジェクトへの tier 追加（後述）。初回のセットアップ（GitHub 側 → Salesforce の接続）とは、順序が逆: 先に Salesforce に接続し、成功してから、ブランチ・PR を作る（接続に失敗したときに、GitHub 側を、変更しないため）
- `--reconnect main|staging|develop`: 1 つの段階の接続先（Salesforce 組織）の付け替え（`phases/init/reconnect.sh`。force-* 内で実行。現在の接続を表示 → 確認 → ログイン先の選択 → ログイン → 種類の読み取り → 本番は main のみのガード → 外部クライアントアプリの自動作成 → JWT 接続テスト → Secrets / Variables の一括更新。古い組織が別の組織なら、残る外部クライアントアプリと片付け方を表示する（自動では削除しない））
- `--status`: セットアップの診断と、段階ごとの接続の一覧（`phases/init/status.sh`。読み取りのみ。終了コード: 診断で不足がある、または、本番が main 以外にあれば 1）。
- `--verify`: 動作の確認（`phases/init/verify.sh`。`--plan` / `--cleanup` / `--no-metasync` / `--components` / `--validate-only` / `--with-objects` は、そのまま渡す。`--verify` なしの指定は `die`）。詳細は 4.15.1
  - 診断（`lib/diag.sh` の `diag_run REPO 段階...`）: リポジトリ・branches.txt の各ブランチ・ワークフロー 5 本（`gh api` / `gh repo view`）、Secrets（`gh secret list`）、Variables（`gh variable list`）、直近の実行（`gh run list --workflow`）を、✓ / ✗ / ！ / ？ で表示する。不足（✗）には、直し方（`--only N` / `--reconnect` / `--add-tier` / `sf-sync-wf.sh`）を表示し、件数を `DIAG_NG` に入れる。一覧を取得できなかったものは「？」とし、不足に数えない（通信エラー・権限不足を、不足と誤認しない）。組織の種類の記録（`SF_ORG_ID_*`）がないものは「！」（不足に数えない。古いバージョンで作ったプロジェクトのため）。直近の実行の失敗も「！」（セットアップの不足ではないため）。
  - Salesforce 側（外部クライアントアプリ・JWT 接続）は、ログインが必要なため確認しない。直近の wf-metasync / wf-release の成功で、接続できていることが分かる。
  - 接続の一覧: GitHub Variables を読むだけ。同じ組織が複数の段階にあれば警告、本番が main 以外にあればエラー表示。
- `--legacy-connected-app`（環境変数 `SF_INIT_LEGACY_CONNECTED_APP=1`）: 従来の接続アプリケーション（手動の入力）を使う。既定は外部クライアントアプリ。保存済みの `APP_TYPE=2` と食い違うときは中断する

#### 4.13.1 `--add-tier` による tier 追加

既存 `force-*` プロジェクトに staging または develop 階層を追加する。`phases/init/add_tier.sh` を呼び出す。

実行場所: **`force-*` ディレクトリ内**（`sf-init.sh` の通常実行とは異なる点に注意）

```bash
cd {作業フォルダ}/{作業単位}/force-xxx    # 例: admin/force-acme
sf-init.sh --add-tier staging    # main → main+staging
sf-init.sh --add-tier develop    # main+staging → main+staging+develop
```

`add_tier.sh` の処理フロー:
1. `check_force_dir` で `force-*` ディレクトリか確認
2. `.sf-init.env` を読み込み（なければ git remote から `REPO_FULL_NAME` を導出）
3. バリデーション:
   - 対象 tier がすでに `branches.txt` に存在する場合はエラー
   - `develop` を追加しようとしたとき `staging` が未登録の場合はエラー（`main → develop` のスキップは禁止）
4. **Salesforce 組織に接続する（先に行う）**: ログイン先の選択 → ログイン → 種類の読み取り → 本番は main のみのガード → 外部クライアントアプリの自動作成（`--legacy-connected-app` のときは手動の入力）→ JWT 認証情報（`SF_CONSUMER_KEY_*` を Secret / `SF_USERNAME_*` / `SF_INSTANCE_URL_*` / `SF_ORG_*` を Variable）を登録。接続できなければ、何も変更しない
5. `git push` でリモートにブランチを作成（既存ならスキップ）
6. 作業用ブランチ（`system-add-tier-<tier>-日時`）で `branches.txt` に tier を追記・コミット・push し、**PR を作成する**（`main` への直接 push はしない。PR のマージで、`branches.txt` が main に反映される）

スケールアップのみ対応・スケールダウンは対象外:
- tier の削除（スケールダウン）は自動化していない
- スケールダウンは影響範囲が大きく（ブランチ削除・WF 停止・Secrets 削除・Ruleset 更新）、誤操作リスクが高いため**手動運用とする**
- 必要な場合は GitHub リポジトリ設定・`branches.txt` 編集・ローカルブランチ削除を手動で実施すること

### 4.13.1 sf-init の状態（保存ファイルと環境変数）

`sf-init.sh` の Phase 間の受け渡しと、再開（続きをやる）は、管理者用フォルダ（`{作業フォルダ}/admin/`）の 2 つのファイルと、環境変数で行う。
変更するときは、この表と、書く側・読む側の両方を、確認する。

#### 保存ファイル

| ファイル | 内容 | 形式 | 備考 |
|---|---|---|---|
| `.sf-init-XXXX.env` | 入力内容（Phase 2 以降が読む。XXXX = プロジェクト名） | `KEY="値"`（`source` で読み込む。権限 600） | 完了時に `*TOKEN_VALUE=` の行を消し、**ファイルごと削除する**（最後まで終わったとき。途中で止まったときは残る）。別のリポジトリの状態なら、残骸として扱い、最初から |
| `.sf-init-XXXX.progress` | 進捗（どこまで成功したか。XXXX = プロジェクト名） | `KEY=値`（書き換えに外部コマンドを使わない） | `--only` では書かない。Phase 1 は、状態を持たないため、記録しない。完了時に、削除する |

`phases/init/add_tier.sh` だけは、`force-*/sf-tools/config/.sf-init.env` を読む（別の場所。admin フォルダのものではない）。

#### `.sf-init.env` のキー

| キー | 意味 | 書く | 読む |
|---|---|---|---|
| `GITHUB_OWNER` | リポジトリのオーナー（gh のログインユーザー・組織） | Phase 2（ファイルを作り直す） | Phase 3 以降・完了画面 |
| `PROJECT_NAME` | 会社・プロジェクト名（init の 1 つ上のフォルダ名） | Phase 2 | Phase 3・完了画面 |
| `REPO_NAME` / `REPO_FULL_NAME` | `force-{PROJECT_NAME}` / `{owner}/force-{PROJECT_NAME}` | Phase 2 | Phase 3 以降。`sf-init.sh` が、前回の状態が、同じリポジトリのものかの判定にも使う |
| `REPO_DIR` | 管理者用フォルダ内の clone 先（`admin/force-{PROJECT_NAME}`） | Phase 2 | Phase 4 以降・管理者用フォルダの案内・`verify.sh`（ステップ 9） |
| `ENV_TYPE` | sf-tools の版（`production` / `staging`）。`SF_TOOLS_BRANCH` の決定に使う | Phase 2 | Phase 2（同じ Phase の中） |
| `SF_TOOLS_BRANCH` | Actions が使う sf-tools のブランチ（`main` / `development`） | Phase 2 | Phase 9（`development` のときだけ、GitHub の Variable に登録） |
| `BRANCH_COUNT` | 段階の数（1〜3） | Phase 5（追記） | Phase 8（ブランチ作成）・Phase 10（段階）・ステップ 9（目安の時間） |
| `PAT_TOKEN_VALUE` | PAT（**秘密情報。一時的**） | Phase 6（追記） | Phase 8（push に使い、直後に、この行を消す） |
| `APP_TYPE` | Salesforce の接続の種別（`1` = 接続アプリ（従来）/ `2` = 外部クライアントアプリ） | Phase 10（追記） | Phase 10（再開時に再利用。指定と食い違うと中断） |

#### `.sf-init.progress` のキー

| キー | 意味 | 書く | 読む |
|---|---|---|---|
| `SF_INIT_DONE_PHASE` | 最後に成功した Phase の番号（`2`〜`10`。`10` = 完了済み） | `sf-init.sh`（Phase が成功するたび。ファイルを書き直す） | `sf-init.sh`（続きの選択肢・完了済みの判定・`--resume N` の拒否） |
| `SF_INIT_DONE_AT` | 上の日時（表示用） | 同上 | 続きの選択肢の表示 |
| `SF_INIT_DONE_TIER_PROD` / `_STG` / `_DEV` | Phase 10 で、その段階の接続まで完了した（`1`） | Phase 10（`_register_org` が、追記） | Phase 10（再実行でスキップ。Secret が、いまもあるときだけ）。Phase 10 が成功すると、`sf-init.sh` がファイルを書き直すため、消える |

#### 環境変数（保存しない）

| 変数 | 意味 | 設定する | 使う |
|---|---|---|---|
| `SF_INIT_MODE=1` | init の一部として動く（`common.sh` の force-* のチェックを、飛ばす） | `sf-init.sh` と各 Phase | `lib/common.sh`・各 Phase |
| `SF_INIT_ENV_FILE` / `SF_INIT_PROGRESS_FILE` | 上の 2 つのファイルの絶対パス | `sf-init.sh` | 各 Phase・`10_sf_auth.sh` |
| `SF_INIT_TIER_RESUME=1` | Phase 10 の段階ごとの再開を有効にする（`--only` では、設定しない） | `sf-init.sh` | `10_sf_auth.sh` |
| `SF_INIT_LEGACY_CONNECTED_APP=1` | `--legacy-connected-app`（従来の接続アプリを使う） | `sf-init.sh` | `10_sf_auth.sh`・`add_tier.sh`・`reconnect.sh` |
| `SF_INIT_RESTARTED` | sf-tools を更新して、同じ引数で、実行しなおした（無限に、実行しなおさないため） | `sf-init.sh` | `sf-init.sh` |
| `SF_INIT_TOOLS_CHECKED_BRANCH` | sf-tools の最新確認を済ませたブランチ（Phase 2 で、二重に確認しない） | `sf-init.sh` | `02_project_info.sh` |
| `SF_INIT_RUNNING=1` | Phase 4 → `sf-install.sh` の初期化モード（フック・`npm install` などを、飛ばす） | `04_gen_files.sh` | `sf-install.sh` |
| `SF_INIT_PUSH_TOKEN` | Phase 8 の push の PAT（`GIT_ASKPASS` で、git に渡す。URL・引数には、出さない） | `08_initial_commit.sh` | 一時スクリプト（終了時に削除） |
| `SF_INIT_LOGIN_URL_{PROD,STG,DEV,START}` | ログイン先の指定（`login` / `test` / URL）。対話の質問を、省略する（e2e・テスト用） | 利用者・e2e | `lib/org.sh`・`reconnect.sh`・`sf-start.sh` |
| `SF_INIT_JWT_RETRIES` / `SF_INIT_JWT_INTERVAL` | JWT 接続テストの再試行の回数・間隔（テストで短くする） | テスト | `init-common.sh` |
| `SF_INIT_VERIFY_ASK=1` | 端末でなくても、ステップ 9 の質問を出す（テスト用） | テスト | `sf-init.sh` |
| `SF_VERIFY_CONFIRMED=1` | `sf-init.sh` が確認済みのため、`verify.sh` の確認を省略する | `sf-init.sh` | `verify.sh` |

### 4.14 sf-check.sh

ターゲットファイルの構文チェックと、テストクラス不足検出を行う。`sf-release.sh` / `sf-prepush.sh` / `sf-push.sh` から自動呼び出しされる。

`check_target_file` の処理（`deploy-target.txt` / `remove-target.txt` 共通）:
- `[files]` セクション: ファイルパスの存在確認（`[[ ! -e "$clean" ]]`）→ エラー時は `print_gcc_error` で GCC スタイル出力
- `[members]` セクション: `種別名:メンバー名` 書式確認（コロンなし → `print_gcc_error`）
- 種類の可否（`check_capability`）: `config/metadata-capability.txt`（`SF_CHECK_CAPABILITY_FILE` で差し替え可）を `awk` で引く。`[members]` は先頭の種類名、`[files]` は `type_of_path`（flows / classes / triggers / lwc / aura / servicePresenceStatuses / standardValueSets のパス）から種類を決める。`deploy-target.txt` は release 列、`remove-target.txt` は delete 列を見る。`ng` はエラー（`error_count` に加算）、`limited` は警告のみ、`ok` / `unknown` / 表にない種類は何もしない。`SF_CHECK_IGNORE_CAPABILITY=1` で省略
- `error_count > 0` の場合のみ終了コード 1

`check_missing_tests` の処理（WARNING のみ・エラーにならない）:
- `deploy-target.txt` の `[files]` セクションから `.cls` ファイルを収集
- 各 `.cls` に対して `@isTest` があればテストクラス自身と判断してスキップ
- Step A: 同一ディレクトリ内で `MyClassTest.cls` / `MyClass_Test.cls` を探す
- Step B: A で見つからない場合、`grep -rl --include="*.cls" "@isTest" .` → `xargs grep -lw "$classname"` でコンテンツ検索
- 見つかったテストクラスが `deployed_files` に含まれていなければ `print_gcc_warning` を出力
- 設計思想: 本番/Sandbox に既存のテストクラスは含めなくてよい → WARNING 扱い（エラーにはしない）


### 4.14.1 sf-typecheck.sh（種類ごとの可否の確認）と config/metadata-capability.txt

管理者・開発者向け。個人用の組織（Developer Edition / Sandbox / Scratch / Trial）で、メタデータの種類ごとに、最小のサンプルを実際にリリース → 削除し、結果を TSV（`種類 / release / delete / 備考`、値は `ok` / `ng` / `limited` / `unknown`）にする。本体は `lib/typecheck.js`（Node 標準ライブラリのみ。シェルから呼ぶ境界は `bin/sf-typecheck.sh` の 1 か所）。

- 安全: GitHub Actions 上・予約名のエイリアス（prod / staging / develop / main）・本番・種類を判定できない組織は拒否。作成・削除するのは名前に `SfToolsE2eMin` を含むものだけ（`lib/typecheck.js` が、作成前に確認する）。許可する sf のコマンドは `project deploy start` / `project deploy validate` のみ
- オブジェクト名・メタデータ名は、実行ごとの時刻つき（削除したカスタムオブジェクトの名前は、約 15 日間、予約されるため）
- テストでは `SF_TYPECHECK_CMD` で、sf をモックに差し替える
- 終了コード: `lib/typecheck.js` は 0（すべて ok）/ 3（ng あり）/ 1（実行の失敗）。`sf-typecheck.sh` は、3 を警告にして、0 で終わる（結果の表で判断する）
- `config/metadata-capability.txt` は、この結果を人が確認して反映する表。`ng`（必ずできない）/ `limited`（権限・使用中・標準のもの・移行済み など、条件による）/ `unknown`（サンプルを作れていない・標準の部品しかない）の区別を守る。`ng` には、備考（理由）を必ず書く（テストで検査）。個別の組織の権限で、できないだけのものは、`ng` にせず `limited` にする
- `--coverage`: 組織に接続せず、`config/changeset-types.txt`（変更セットで扱える種類。公式の Metadata Coverage Report の ChangeSets 列。取得日・出典は、ファイルの冒頭）と `config/metadata-capability.txt` を突き合わせ、確認済み / リリースのみ / 条件つき・NG / 判定できない / 未確認の数と一覧を出す（awk のみ。`SF_TYPECHECK_CHANGESET_FILE`・`SF_CHECK_CAPABILITY_FILE` で、ファイルを差し替え可）。表の種類名と、変更セット側の複数形・単数形が違うもの（CustomLabels など）は、別名で引く
- 確認した環境: Developer Edition（API 64.0）。新しい種類の確認を足すときは、`lib/typecheck.js` の `S`（サンプルの一覧）に追加する
- サンプルの定義（`add(種類, files, del, extra)`）: `del` の中の `null` は、削除の段階の区切り（直前の削除が終わってから、次を実行する）。`extra.covers` は、同じサンプルで一緒に確認できた別の種類（表に同じ結果の行を足す）。共有ルールは、作成直後は、再計算が終わるまで、削除が `sharing operation already in progress` で失敗するため、30 秒おき・最大 8 回、やり直す
- 失敗の理由が、サンプルの書き間違い・組織の機能がない（例: `Not available for deploy for this organization`）場合は、表には、`ng` ではなく `unknown` として書く（`ng` は、サンプルが正しいことを確認してから）

### 4.15 sf-sync-wf.sh

作成済みの `force-*` の `.github/workflows/` を、sf-tools の雛形（`templates/.github/workflows/`）に合わせる管理者向けコマンド（設計: `doc/wf-distribution-strategy.md`）。`sf-install.sh` などから自動では実行しない（利用者の意思なく、ワークフローが書き換わるのを防ぐため）。実行フロー（順序変更禁止）:
1. オプション解析（`--check` / `--remove <ファイル名>` / `-v` / `-h`。不明なオプションは die）
2. `check_force_dir`（force-* 以外は die）→ 現在のブランチが `is_protected_branch`（`branches.txt` のブランチ）なら die
3. **sf-tools が最新であること（必須）**: `ensure_sf_tools_latest "$SF_TOOLS_DIR"`（`--check` のときは `--no-update`）。戻り値 2（更新した）なら、`SF_SYNC_WF_RESTARTED=1` を export して、同じ引数（`ORIG_ARGS`）で `exec` して再実行する（実行中のスクリプトが書き換わるため）。すでに再実行済み（`SF_SYNC_WF_RESTARTED` あり）でまだ 2 なら die（無限ループ防止）。古い雛形で、プロジェクトのワークフローを書き換えないための必須の手順
4. **冒頭の警告ボックス + `ask_yn || die`**（CLAUDE.md 2.4。N / q は die。`GITHUB_ACTIONS=true` でも省略しない）。`--check` は、何も変更しないため、表示しない
5. `--remove`: ファイル名を `^[A-Za-z0-9][A-Za-z0-9._-]*.ya?ml$` で検証（パスの区切り・`..` は拒否）→ 存在確認 → **雛形にあるファイルは拒否**（廃止されたものだけが対象）→ 2 回目の `ask_yn`（削除は二重確認）→ `rm`。コミットはしない
6. 雛形と比較（`diff -q --strip-trailing-cr`。CRLF だけの違いは無視）: 内容が違う `CHANGED`・プロジェクトにない `NEW`・雛形にない `EXTRA`（情報として表示するだけで、変更しない）
7. 差分なし → 「最新です」で終了（0）。差分あり → `diff -u` を表示
8. `--check`: ここで終了（差分あり: 終了コード 1）
9. 差分を見たうえで、2 回目の `ask_yn`（N / q は die）→ `cp`（上書き）。コミット・プッシュはしない

**更新の手順（推奨）:** `sf-job.sh` でジョブ名 `system-日付` の作業用ブランチを作る（固定の `system` ブランチは、あらかじめ作らない。`sf-job.sh` は同名のブランチを拒否し、長く残るブランチは古くなるため）→ `sf-sync-wf.sh` → `git diff` → `sf-push.sh` → PR・マージ（複数の環境がある構成では `develop` → `staging` → `main` の順。`sf-next.sh` が案内する）。ワークフローをプッシュするには、`workflow` スコープのある権限が必要。

テスト: `tests/test_sf-sync-wf.sh`（モックの HOME に雛形を置き、ガード・差分・N/q/Y・CRLF・`--check`・`--remove` を確認。実際の雛形のコピーが `--check` で差分なしであることも確認）、`tests/test_common.sh` の `test_ensure_sf_tools_latest`（本物の git で、最新・遅れ・未コミット・未プッシュ・更新を断る・`--no-update` などを確認。bare の origin は `--initial-branch=main` で作る。環境によって既定のブランチ名が違うため）
---

### 4.15.1 verify.sh（sf-init.sh --verify）

管理者が、実際のリポジトリ・実際の組織で、リリースと削除が動くことを確認する（`phases/init/verify.sh`。部品は `lib/verify-common.sh`）。

**フロー:** (1) `GITHUB_ACTIONS` なら中断。force-* の中で実行。`check_gh_owner` (2) 段階の判定: リモートのブランチから（develop + staging があれば 3 層・staging があれば 2 層・それ以外は main のみ）。リリースの順は develop → staging → main (3) 診断（`diag_run`）。不足があれば、確認の前に中断 (3b) 検証用と同名のクラスのファイルが、いずれかの段階のブランチに、すでにあれば、中断（`--cleanup` は、対象外）(4) 実行内容の表示（段階ごとの `SF_ORG_NAME_*`・`SF_ORG_KIND_*`・`SF_USERNAME_*`。種類が developer / sandbox / trial 以外は、本番扱いで赤く表示）。`--plan` はここで終了 (5) 確認（`SF_VERIFY_CONFIRMED=1` のときは、聞かない）: 警告ボックスと `wizard_confirm`（Enter / Y で進む。N / q / EOF は中断。入力を最小にするため）。本番扱いの組織があれば、質問の文面で、本番を含むことを明示する（リポジトリ名・`production` の入力は、求めない） (5b) 環境の確認（`--cleanup` では行わない。NG があれば、そこで止める。`wf-metasync` は、手前の 2 つの確認が OK のときだけ起動する）: `SF_TOOLS_BRANCH` が main / development／`~/sf-tools/logs/*.log` に Token・認証 URL（`ghp_` / `github_pat_` / `xoxb-` / `force://…`）が残っていない（`_logs_clean`）／`wf-metasync` を `verify_dispatch_workflow` で手動起動 → `verify_wait_run` → `_run_ok`（失敗は 1 回だけ再実行）→ ステップ `Salesforce 組織にログイン`・`自動化ツール（sf-tools）を取得` が success（`--no-metasync` で省略）(6) リリース: main の先頭から `verify-hello-時刻` を API で作り（クラスのファイル 4 つ + `deploy-target.txt` + 空の `remove-target.txt`）、段階ごとに PR → wf-validate → マージ → wf-release（→ main のとき wf-propagate）。各 PR の前に、実行 ID の基準を覚え、より新しい実行だけを、その PR の実行とする。失敗した実行は、1 回だけ再実行する (7) 削除: main の先頭から `verify-hello-delete-時刻`（クラスのファイルを API で削除 + `remove-target.txt`）を作り、同じ順に各段階へ (7b) 後始末（`_delete_job_branches`）: 今回作ったブランチ（`verify-hello-時刻` / `verify-hello-delete-時刻`。`--cleanup` では、削除用のみ）を、API で削除する。名前が `^verify-hello(-delete)?-[0-9]{6}$` に合うことと、そのブランチを head とする、開いている PR がない（確認できないときも、ない扱いにしない）ことを確認してから削除する。途中で止めたとき（`exit` の前）は、行わない（調査のために、残す）。削除の失敗は、警告のみで、検証の成否に含めない。PR の履歴は、PR の番号で残る (8) 結果。

**確認（段階ごと・リリースと削除）:** `<段階> の組織にログイン（JWT）` ステップが success（文言の中立化より前の古い名前 `本番組織` / `ステージング組織` / `開発組織` も候補。`_login_step_names`）／ほかの段階のログインのステップが `skipped`（見つからなければ、注意の表示のみ）／`SF_USERNAME_*` が登録されていて、その値がログに出ている（空は NG）／ログに Hello World のクラス名が出ている。Slack の `ok:true` は、注意の表示のみ（成否に含めない）。確認が NG でも、削除まで進める（組織を元に戻すため）。

**失敗時:** リリースの PR をマージした段階を `LEFT` に記録し、削除が成功するまで残す。中断したときは、`LEFT` の段階と `sf-init.sh --verify --cleanup`（削除のみ。全段階を対象にする）を案内する。マージの拒否（ブランチ保護）・wf-validate の失敗では、PR を残して止まる。

**ローカルの clone・git の操作は、行わない**（ブランチ・ファイルは GitHub の API で作る。フック・認証ヘルパーの影響を受けない）。組織への直接のログインも、行わない（ワークフローの結果で確認する）。

**`--components` / `--validate-only` / `--with-objects`（パターン別のサンプル。develop のみ）:**
- 目的: 種類ごとに、ターゲットファイルの書式（`[files]` / `[members]`）・パス・名前の書き方が違っても、リリースの仕組みが動くことの確認。全種類ではなく、書き方のパターンごとに最小のものを 1 つずつ置く。
- ローカルでの dry-run（`sf-dryrun.sh`）は使えない: `sf-release.sh` は、予約名（prod / staging / develop / main）の組織へのローカル実行を拒否する（共有環境の保護。緩めない）。そのため、既存の `--verify` と同じ経路（PR → wf-validate → マージ → wf-release）で行う。
- サンプルの定義は `lib/verify-samples.sh`（`verify_sample_paths [stage1|stage2|all]` / `verify_sample_content_for` / `verify_sample_deploy_target_text` / `verify_sample_remove_target_text [stage1|stage2]`）。`lib/verify-common.sh` の `verify_set_*`（`VERIFY_SET=hello|components`）が、Hello World とサンプルを切り替える。
- 段階: `TIERS=("develop")` に固定。develop がある構成（3 層）だけ。それ以外は `die`（本番・staging にサンプルを入れない）。
- `[files]` は、**ファイルのみ**（`sf-check.sh` が `-f` で検査する）。LWC は `.js` の 1 ファイルを、Aura は `[members]` で指定する。
- LWC と Aura は、**同じ名前空間**を共有する（同名のバンドルは作れない）。Aura は `SfToolsE2eHelloAura`、LWC は `sfToolsE2eHello`（実際の組織の dry-run で、同名の Aura が拒否された）。
- **オブジェクト系**（ApexTrigger・そのテストクラス・Layout・CustomObject・CustomField）は、`VERIFY_SAMPLE_OBJECTS`（verify.sh が決める: 検証のみ = 1 / 通し = `--with-objects` のときだけ 1）。理由: カスタムオブジェクトは、削除すると 15 日間、削除済みで名前が予約され、再作成できない（通しを繰り返すと、2 回目から失敗する）。検証のみは、何も作らないため、常に含める。
- 削除は、既定 1 段階（`remove-target.txt` stage1: ApexClass / LWC / Aura / PermissionSet / EmailTemplate / CustomLabel）。`--with-objects` のときは 2 段階（stage1 に ApexTrigger・トリガーのテストクラスを加え → stage2: CustomField / CustomObject）。
  実際の組織の dry-run で判明: **Layout は、オブジェクトの最後の 1 つにできない**（`Cannot delete the only layout`）ため、削除対象にしない（オブジェクトの削除に任せる）。
- **Flow**: API での削除は、`Flow` 型・`FlowDefinition` 型のどちらでも拒否される場合がある（`insufficient access rights on cross-reference id`。接続ユーザーに、Flow を API で削除する権限がない）。削除できないものを、リリースすると組織に残るため、**通しには含めない**（`VERIFY_SAMPLE_FLOW`: 検証のみ・`--cleanup`（リポジトリのファイルの削除）では 1、通しでは 0）。`remove-target.txt` には、Flow を含めない。組織に残った Flow は、画面（設定 → フロー）で手動で削除する。削除用のブランチは、サンプルのファイルが **develop にだけある**ため、develop の先頭から作る（`_make_delete_branch BR STAGE BASE`）。
- `--validate-only`: `_pr_flow` の `mode=validate`。wf-validate の成功を確認し、PR をマージせずに閉じる（`verify_pr_close`）。削除は、行わない。失敗したときは、PR・ブランチを残す。
- 既存の `force-app/main/default/labels/CustomLabels.labels-meta.xml` が develop にあるときは、`VERIFY_SAMPLE_LABELS=0`（CustomLabels を含めない。上書きして削除してしまうのを避ける）。
  ただし、**サンプルのラベル（fullName が `SfToolsE2eHello`）だけを含むファイル**は、サンプル自身のもの（前回の検証の残り）として扱う（`verify_sample_labels_file_is_ours`）。含めないと、ラベルとファイルが、後始末でも消えなくなる（実際に発生）。ほかのラベルを含む・読めない・空のときは、利用者のものとして、触らない。
- GitHub の contents API のパスは `_verify_urlpath` で URL エンコードする（`%` → `%25`、空白 → `%20`。Layout の名前に空白がある）。
- **`--cleanup` は冪等**: 削除用ブランチの `remove-target.txt` の先頭に `# @ignore-missing` を入れる（`_make_delete_branch`。`CLEANUP_ONLY` のときだけ）。`sf-release.sh` がこの指示行を見つけると `sf project deploy start --ignore-warnings` を付け、組織に存在しない削除対象（`No ApexClass named: X found`）を、エラーにしない。どこまで消えているか分からない後始末が、何度でも通る（付けないと、一部が残っているだけで、dry-run が失敗していた）。通常の削除には入れない（綴りの誤りを、見落とさないため）。
- 後始末の案内: 失敗時の `--cleanup` のコマンドは、`--components`（と `--with-objects`）を含めて案内する（`_CLEANUP_CMD`。含めないと、Hello World の削除になってしまう）。
- 作業用ブランチ: `verify-comp-HHMMSS` / `verify-comp-delete-HHMMSS` / `verify-comp-delete2-HHMMSS`（`--with-objects` のときだけ。最後に削除。`_delete_job_branches` の形式の確認は `^verify-(hello|comp)(-delete2?)?-[0-9]{6}$`）。
- 実際の組織での受理（Flow の最小の XML・削除の順序など）は、モックでは確認できない。最初は、develop で実行して、エラーを見ながら直す。

テスト: `tests/test_verify.sh`（状態つきの gh のモック）。e2e（`tests/e2e/lib.sh`）は、PR・実行の待ち・結果の読み取り・Hello World の本文を、`lib/verify-common.sh` に委譲する。

---

## 5. ドキュメント連動ルール

スクリプトの実装詳細を変更した場合は以下も確認・更新すること:

| 変更内容 | 確認先 |
|---|---|
| `sf-init.sh` のフロー・入力項目 | `doc/setup-guide.md` セクション3 |
| ファイルパス・ディレクトリ構造 | `doc/setup-guide.md` セクション6、`README.md` セクション 4（スクリプト一覧）・セクション 7（ディレクトリ構成）|
| PAT の種類・取得方法 | `doc/setup-guide.md` セクション3.1、`doc/sf-cicd-strategy.md` セクション7.1・8 |
| WF ファイル名・ジョブ名 | `doc/setup-guide.md` セクション5、`doc/sf-cicd-strategy.md` セクション4.2 |
| `templates/.github/workflows/` の `name:` | `doc/setup-guide.md` のワークフロー一覧 |
| `templates/.github/workflows/` の内容 | `phases/init/09_repo_rules.sh` の `required_status_checks.context` との整合 |
| mm / rr の運用・リリース手順 | `CLAUDE.md` 1.3・4.3、`README.md` セクション 9、本書セクション 9 |

> ドキュメントの詳細（フロー・パス等）はコードを確認してから記載すること。推測で書かないこと。

---

## 6. スクリプト依存関係マップ

変更の波及確認に使うこと。

| 呼び出し元 | 呼び出し先 | 備考 |
|---|---|---|
| `sf-restart.sh` | `sf-start.sh` | 設定クリア後に start を実行 |
| `sf-start.sh` | `sf-install.sh` | バックグラウンド起動 |
| `sf-start.sh` | `sf-launcher.sh` | install 完了後に起動（二重起動防止あり） |
| `sf-install.sh` | `sf-hook.sh` | フックインストール |
| `sf-install.sh` | `sf-upgrade.sh` | 24h 経過時バックグラウンド起動 |
| `sf-dryrun.sh` | `sf-release.sh` | オプションなし（dry-run）で呼ぶ |
| `sf-deploy.sh` | `sf-release.sh` | `--release --force` 付きで呼ぶ |
| `sf-push.sh` | `sf-check.sh` | コミット前にターゲットファイル検証 |
| `sf-init.sh` | `phases/init/02〜10_*.sh` | フェーズ順に実行 |
| `sf-init.sh --add-tier` | `phases/init/add_tier.sh` | tier 追加モード |
| `hooks/pre-push` | `sf-release.sh` | push 時に dry-run 実行 |

---

## 7. デバッグコマンド集

### 7.1 テスト

```bash
bash tests/run_tests.sh                           # 全テスト実行（mm 前に必ず実行）
bash tests/run_tests.sh --changed                 # 変更ファイルに対応するテストのみ（開発中）
bash tests/run_tests.sh --jobs 4                  # 同時に動かすテストファイルの数を指定（既定: CPU の数。環境変数 SF_TEST_JOBS でも指定できる）
bash tests/run_tests.sh --serial                  # 1 つずつ実行（並列で、原因を切り分けにくいときの確認用）
bash tests/run_tests.sh test_sf-start.sh          # 単体実行
cat logs/run_tests.log | grep '\[FAIL\]'          # 失敗行のみ抽出
cat logs/error.log                                # run 失敗コマンドのログ
```

実環境で `sf-init.sh` を通しで検証する e2e は、通常のテストには含まれない（9.6 参照）。

```bash
bash tests/e2e/bootstrap.sh                       # 鍵一式の作成（最初の 1 回だけ）
bash tests/e2e/bootstrap.sh --add-orgs            # staging・develop のテスト用組織を、鍵一式に追加（2 層・3 層の確認に必要）
bash tests/e2e/bootstrap.sh --refresh-orgs        # 登録済みの認証 URL の有効性を確認し、無効なものだけを、ブラウザでのログインで取り直す
bash tests/e2e/run.sh --with-args                  # sf-init / sf-job に、引数 --owner / --project を付ける（既定は、引数なしの対話と、クローンからの自動判定）
bash tests/e2e/run.sh --no-add-tier                # 最後の --add-tier の確認（約 4 分）を省略する
bash tests/e2e/run.sh --layout 3                  # 3 層で、段階ごとに、ワークフローを動かして確認（既定は 1 層）
bash tests/e2e/run.sh                             # 前掃除 → sf-init の通し実行 → 確認 → 終了（既定では、テスト用のものを残す。--cleanup で削除）
bash tests/e2e/cleanup.sh                         # 削除対象の一覧（何も消さない）。--yes で削除
```

### 7.2 Salesforce CLI

```bash
sf org list                                       # 接続済み組織一覧
sf org display --target-org tama                  # 組織情報・接続確認
sf config list                                    # デフォルト組織などの設定確認
cat .sf/config.json                               # ローカル設定ファイル確認
```

### 7.3 Git / GitHub

```bash
git log --oneline -10                             # 最近のコミット
gh run list --limit 5                             # CI ワークフロー実行状況
gh pr list                                        # オープン PR 一覧
git diff HEAD~1                                   # 直前コミットとの差分
```

---

## 8. force-* ローカル環境ディレクトリ

ローカルの作業ディレクトリは以下の構造で配置する。
フォルダツリーから GitHub 組織名・企業名・案件名（ブランチ名）を自動導出できる設計になっている。

```
C:\home\<github-owner>\<company>\<branch>\force-<company>/
         ↑              ↑         ↑
         GitHub組織名   企業名    案件名（ブランチ名）
```

| ディレクトリ例 | 作業ブランチ | 用途 |
|---|---|---|
| `C:\home\tamashimon-org\test\system\force-test` | `system` | 開発作業用 |

- 開発は基本的に上記の `system` ブランチ用ディレクトリで行うこと
- 検証のために一時的にブランチを切り替えることは許可されるが、作業完了後は元のブランチに戻すこと

---

## 9. 開発・リリース手順（sf-tools）

sf-tools の `main` への反映は、全ユーザーへの配布と同義である。修正は `development` で行い、検証環境で確認してから `main` に入れる。

### 9.1 ブランチと配布の関係

| 対象 | 参照するブランチ | 決まり方 |
|---|---|---|
| ユーザーのローカル `~/sf-tools` | `~/sf-tools` で今チェックアウトしているブランチ | `sf-install.sh` が `git pull origin <現在のブランチ>` を実行する |
| force-* の GitHub Actions | Variable `SF_TOOLS_BRANCH`（未設定なら `main`） | `wf-metasync` / `wf-validate` / `wf-release` が `git clone -b` で取得する |

- 一般ユーザーの `~/sf-tools` は `main` のため、`main` へのマージで配布される
- 開発者の `~/sf-tools` を `development` にし、検証環境の force-* の `SF_TOOLS_BRANCH` を `development` にすれば、`main` を汚さずに検証できる
- `sf-init.sh` は、Phase 2 で環境種別を選んだ直後に `ensure_sf_tools_branch`（`phases/init/init-common.sh`）で `~/sf-tools` の最新化を確認する（本番 = `main`、検証 = `development`）。ブランチ違いは確認（Y/N/q）、遅れていれば確認のうえ `git pull --ff-only` を実行して中断する（実行中のスクリプトが書き換わるため。再実行すれば最新で動く）。ローカルに未コミット・未 push の変更があれば更新せず警告のみ。ブランチの自動切り替えは行わない

### 9.2 検証環境の作り方

| 対象 | 方法 |
|---|---|
| 新規に作る force-* | `sf-init.sh` の Phase 2 で「2. 検証環境」を選ぶ（`SF_TOOLS_BRANCH=development` が Variable として登録される） |
| 既存の force-* | `gh variable set SF_TOOLS_BRANCH --body "development" -R <owner>/<repo>` |
| ローカル | `~/sf-tools` を `development` にチェックアウトしておく |

- `SF_TOOLS_TOKEN` は不要（`sf-tools` は公開リポジトリのため、Actions は Token なしで clone する。2026-10-05 に廃止。`sf-init.sh` の Phase 11 は無い）。以前のバージョンで作ったプロジェクトのワークフローは、Token 付きで clone しているため、その Token を無効にしないこと

### 9.3 検証チェックリスト（rr の前提）

変更内容に応じて、必要な項目を実施し、結果をユーザーが報告する。

| 確認項目 | 方法 |
|---|---|
| テスト | `bash tests/run_tests.sh` が全件 PASS |
| `sf-init.sh` を変更した場合 | 検証環境の新規 force-* を作成し、最後まで通ること。`bash tests/e2e/run.sh` で自動化できる（9.6） |
| ワークフロー・`sf-metasync.sh` を変更した場合 | `wf-metasync` を `workflow_dispatch` で手動実行して成功すること |
| `sf-release.sh` / `wf-validate` / `wf-release` を変更した場合 | デプロイ対象を含む PR を作り、`wf-validate` が通ること（動作確認のみの PR はマージせずに閉じる。マージすると `wf-release` が実際にデプロイする） |

> `templates/` の変更は配布済みの force-* に自動反映されない。検証環境の force-* の `wf-*.yml` は、手動で `templates/` と一致させること。

### 9.4 リリース（rr）

1. 9.3 の確認が完了し、ユーザーが結果を報告している
2. 「rr」の指示で、`development` → `main` の PR を作成してマージする（手順は `CLAUDE.md` 1.3.2）
3. マージ後、`main` の内容を検証環境の force-* でもう一度確認する

### 9.5 ガードレール

- `main` のブランチ保護・Ruleset: `sf-tools` 自身は公開リポジトリのため、無料プランでも設定でき、**設定済み**（Ruleset `protect-main`: `deletion` / `non_fast_forward` / `pull_request`（承認者 0 人）。バイパスなし。2026-10-05）。force-* のような Private リポジトリでは、`Upgrade to GitHub Pro or make this repository public` で設定できない。Actions は実行のたびに `sf-tools` の `main`（検証環境は `development`）を取得してコードを実行するため、`main` の書き換え権限の管理が重要。rr は PR 経由（`gh pr merge`）なので、この Ruleset の影響を受けない
- そのため、`CLAUDE.md` 1.1 の運用ルール（mm / rr は明示された場合のみ、rr は検証報告が前提）で守る
- プランの変更、またはリポジトリを公開にできるようになった場合は、`main` に Required reviewers を設定すること

### 9.6 e2e（sf-init の通し検証の自動化）

実際の GitHub / Salesforce で `sf-init.sh` を Phase 1〜10 まで自動実行し、検証し、削除する。`tests/e2e/` に置き、通常の `bash tests/run_tests.sh` には含めない（実環境を使うため）。安全ガードと部品は `tests/test_e2e.sh`（モック）で確認する。

**方式:** `sf-init.sh` 本体は変えず、外から標準入力と PATH の差し替えで操作する（本番のコードに近道を入れない）。

| 部品 | 役割 |
|---|---|
| `tests/e2e/lib.sh` | 共通関数。名前の判定、ガード、鍵一式の読み込み、削除、エイリアスの保存・復元、`e2e_make_input`（標準入力の台本） |
| `tests/e2e/run.sh` | 前掃除 → `sf-init.sh` の実行 → 確認 → 終了。既定では、終了時にテスト用のリポジトリなどを削除せず残す（あとから見返せる。次回の前掃除で削除）。`--cleanup`（終了時に削除）、`--resume`（前回残したリポジトリで、Hello World の部分だけを再実行。前掃除・sf-init・wf-metasync は行わない。ジョブ名は時刻付き。前回の残りの Hello World の Apex は、最初に削除する）、`--no-actions`（Actions の確認を省略）。`--keep` は、以前の名残り（何もしない） |
| `tests/e2e/cleanup.sh` | 削除。既定は一覧のみ、`--yes` で削除（確認で `delete` の入力が必要。`--no-confirm` で省略） |
| `tests/e2e/bootstrap.sh` | 鍵一式（`~/.sf-tools-e2e/fixture.env`）の作成。最初の 1 回だけ。雛形は `fixture.example.env`。`--add-orgs`: 既存の鍵一式に、staging・develop の組織の認証 URL（`E2E_SFDX_AUTH_URL_STG` / `_DEV`）だけを追加する（ほかの段階と同じ組織は拒否）。`--refresh-orgs`: 登録済みの認証 URL（main・staging・develop）で、実際にログイン（`sf org login sfdx-url`）して有効性を確認し、**無効なものだけ**を、確認のうえ、ブラウザでログインし直して取り直す（Token などは変えない。取り直した組織が、ほかの段階と同じなら中断し、保存は、すべての確認の後にまとめて行う。無効なまま残したときは、非ゼロで終了）。リフレッシュトークンは、同じユーザーで、ログインを繰り返すと、古いものから失効する（e2e が `RefreshTokenAuthError` で失敗する） |
| （層数対応: `run.sh` / `lib.sh`） | `--layout 1\|2\|3`: `e2e_make_input N`（Phase 5 の番号は、3 層 = 1・2 層 = 2・1 層 = 3。ログイン先の答えは段階の数だけ）。リポジトリの構成は、ブランチから判定（`TIERS`: develop → staging → main）し、`_hello_flow` が、段階の数だけ、`_hello_pr_flow`（同じブランチから、段階ごとの PR）を繰り返す。実行の取り違え防止: PR を作る前の最新の実行 ID（`e2e_latest_run_id`）を覚え、それより新しい実行だけを、その PR の実行とする（`e2e_wait_pr_run` の 4 番目の引数）。段階の指定: 環境変数 `E2E_TIER`（`e2e_sf_admin_login` / `e2e_apex_count` / `e2e_list_target_apex` / `e2e_delete_apex` などが、その段階の組織・エイリアス（`sf-tools-e2e-admin[-stg\|-dev]`）を使う）。`sf` の差し替えは、`--alias` の末尾（STG / DEV）で、段階の認証 URL を選ぶ。確認: 各段階のリリースで、その段階の組織にだけクラスができる（先の段階にはない）・`wf-propagate` で staging / develop に main が入る（`compare` の `ahead_by` = 0）・main の削除は、ほかの段階に及ばない。 |
| `tests/e2e/shims/sf` | `sf org login web` だけを `sf org login sfdx-url`（認証 URL）に差し替える。他のコマンドは本物の `sf` に渡す |
| `tests/e2e/shims/browser` | `start` / `xdg-open` / `open` の名前でコピーされ、ブラウザを開かない |

**テスト用の名前:** プロジェクト `e2e-YYYYMMDD-HHMMSS` → リポジトリ `force-e2e-YYYYMMDD-HHMMSS` → 外部クライアントアプリ `SF_TOOLS_force_e2e_YYYYMMDD_HHMMSS`。毎回別の名前なので、前回の削除を待たずに実行できる。

**確認する内容:** Secret / Variable / ブランチ / ワークフローの存在、`SF_TOOLS_BRANCH=development`、`SLACK_CHANNEL_ID` の一致、トークンが出力・ログに出ていないこと、`wf-metasync` の成功（`workflow_dispatch` で起動し、完了を待ってから Hello World の流れに進む。並行すると、組織からの取得（retrieve）と Hello World のデプロイが重なり、`MetadataTransferError` で失敗した（2026-10-05 の実機））、Hello World のリリース・削除（下記）。

**Hello World のリリース・削除（`_hello_flow`）:** 実際の PR の流れで、`wf-validate` → マージ → `wf-release` を通す（`wf-release` の途中のステップ（JWT ログイン・公開 `sf-tools` の clone）と Slack 通知（`"ok":true`）、成功の通知）。
- 部品は `tests/e2e/lib.sh`: `e2e_gh_pr_create` / `e2e_gh_pr_merge` / `e2e_wait_pr_run`（`gh run list --workflow … --branch … --event pull_request` で実行を探し、完了まで `E2E_POLL_SEC` 秒（既定 5）おきに確認。起動待ちは `E2E_RUN_FIND_TRIES` 回（既定 24）、完了待ちは `E2E_WF_TIMEOUT` 秒）。これらは `_e2e_check_repo` で、オーナー（`E2E_OWNER`）とテスト用リポジトリの名前の形式が一致しないと動かない
- リリース（通常の運用と同じ道。`_hello_local_release`）: `e2e_run_sf_cmd` で、`sf-job.sh`（ブランチ `e2e-hello` の作成・clone・`sf-start.sh`。標準入力は `ジョブ名 / Y / エイリアス（E2E_JOB_ALIAS）`）→ `e2e_wait_sf_install`（`sf-start.sh` が背景で動かす `sf-install.sh` の完了を、`sf-tools/logs/sf-install.log` の完了メッセージで待つ。`E2E_INSTALL_TIMEOUT` 秒、既定 600。`npm install` も、通常の運用と同じく動く）→ `tests/e2e/fixtures/` の 4 ファイルと `deploy-target.txt`（`[files]` と `[members]`）を書く（開発者の手作業にあたる部分。`remove-target.txt` は、`sf-install.sh` が作った雛形のまま）→ `sf-dryrun.sh`（`@isTest` の検出と `--tests` を確認）→ `sf-push.sh`（commit・push。`pre-push` フックが動く）。`e2e_run_sf_cmd` は、テスト用の作業フォルダ（`{E2E_HOME_ROOT}/{E2E_OWNER}/e2e-…`）の中だけで動き、出力を `${E2E_TMP}/{ラベル}.out` に残し、失敗したら末尾を表示する。差し替え（`tests/e2e/shims/`）は、`sf`（`org login web` を認証 URL に）、`code`（`code .` は何もしない。`--wait <ファイル>` は、`E2E_COMMIT_MSG` を書き込む）、ブラウザ。`sf-launcher.sh`（対話のメニュー）は、`SF_LAUNCHER_ACTIVE=1` で起動しない。そのあと、`gh` で PR を作り、`wf-validate` → マージ → `wf-release`
- どちらのジョブも、`deploy-target.txt` と `remove-target.txt` の両方が、クローンにある（`sf-install.sh` が雛形から作る。書き換えるのは、使う側だけ）（`sf-release.sh` は、どちらかが無いと止まる。通常は `sf-install.sh` が雛形から作る）。使わない側は、空の雛形（`e2e_empty_target_text`: `[files]` と `[members]` のみ）。`wf-validate` の「対象ファイル確認」は、実質の中身がある側だけを見る（2026-10-05 の初回の実機で、`remove-target.txt` が無く検証が失敗した）
- 削除（リリースと同じ道。`_hello_cycle` に、`_hello_write_remove` を渡す）: `sf-job.sh`（ブランチ `e2e-hello-delete`。新しいクローン）→ `release/e2e-hello-delete/remove-target.txt`（`ApexClass:SfToolsE2eHelloTest` / `ApexClass:SfToolsE2eHello`）を書く（`deploy-target.txt` は雛形のまま）→ `sf-dryrun.sh` → `sf-push.sh` → PR → マージ。`@isTest` の検出の確認は、リリースだけ
- そのほかの sf-tools のコマンド: リリース後に、リリースしたジョブのクローンで、`sf-next.sh`（出力に「マージ済み」。質問には N で答える。`_hello_sf_next`）と、`sf-deploy.sh -t main --no-open`（予約名 `main` の組織への。開発者の本物の `prod` などを避けるため `main` を使う。、ローカルからの強制リリースの拒否。終了コード 0 以外・「共有環境のため」の文言・`project deploy start` が出ないこと。`e2e_run_sf_cmd_refused`・`_hello_deploy_refused`）を確認する
- ワークフローの結果（`conclusion`）とステップの結果の読み取り（`e2e_run_conclusion` / `e2e_step_conclusion`）は、空のときだけ、`E2E_POLL_SEC` 秒（既定 5）おきに、最大 `E2E_CONCLUSION_TRIES` 回（既定 6）やり直す。完了した直後に、API の反映の遅れや `gh` の一時的な失敗で空になり、成功した実行が FAIL になった（2026-10-05 の実機）。`failure` などの値は、やり直さず、そのまま使う（本当の失敗を、成功にしない）
- ワークフロー（`wf-validate` / `wf-release` / `wf-propagate` / `wf-metasync`）が失敗したら、ログを表示したあと、**1 回だけ** `gh run rerun --failed` で再実行する（`_run_ok`・`e2e_rerun_and_wait`。開発者が GitHub の画面で「Re-run」を押す操作と同じ。再実行の前後の試行番号（attempt）を見て、完了を待つ）。再実行で成功したら PASS にするが、警告を表示し、結果にも「再実行で成功したワークフローが N 件」と出す（一時的な失敗の頻度が、あとから分かるように）。再実行でも失敗したら FAIL。Salesforce や通信側の一時的なエラー（`MetadataTransferError` など。2026-10-05 の実機で、wf-metasync と wf-validate で各 1 回）で、e2e 全体が失敗するのを防ぐ。`sf-release.sh` 本体には、再試行を入れていない（成否は終了コードだけで判定する方針。検証が失敗するたびに再実行すると、本当の失敗でも時間が倍になるため）
- **コードレビュー（2026-10-06）で直したもの:** (1) sf のエイリアスの保存（`e2e_alias_snapshot`）は、`sf alias list` が失敗したら、空の一覧を保存せず中断する。復元は、保存成功の目印（`.ok`）がないとき、`sf alias list` が失敗したときは、何も外さない（空の保存のまま復元すると、開発者の本物の `prod` などを、すべて外してしまうため）。 (2) 掃除（`e2e_cleanup_all`）は、管理用ログインに失敗しても、ローカルの掃除を続け、失敗として終わる（Salesforce 側は `_e2e_cleanup_salesforce` に分けた）。 (3) `_dispatch_workflow` は、起動の前の最新の実行 ID を覚え、それより新しい実行だけを、起動した実行とみなす（古い実行の取り違えを防ぐ）。起動に失敗したら、実行を探さない。 (4) run.sh の `gh` は、すべて `_e2e_gh`（時間の上限付き）を通す。 (5) push の一致（`_pushed_to_remote`）は、どちらかが空（読めない）なら、一致とみなさない。 (6) `e2e_run_sf_cmd_refused` は、終了コード 125〜127（実行そのものの失敗）を、拒否とみなさない。拒否の確認は、予約名 `main` で行う。 (7) 使わなくなった `e2e_gh_branch_create` / `e2e_gh_file_put` / `e2e_empty_target_text` と、そのテストを削除した。 (8) 秘密の伏せ字は、`_e2e_mask_line` に一本化した。 (9) `e2e_apex_count` のエラー出力の一時ファイルの名前を、掃除の対象の形（`e2e-run.XXXXXX`）にした。 (10) 直接実行するコマンド（mkdir / cp / rm）に、`run` 不使用の理由のコメントを付けた（CLAUDE.md 2.1）
- **止まったのか、動いているのか分かるように:** `e2e_run_sf_cmd` は、`E2E_HEARTBEAT_SEC` 秒（既定 30）おきに、経過時間を表示し、`E2E_CMD_TIMEOUT` 秒（既定 1200）を超えたら、打ち切る（終了コード 124、「時間切れ」と表示）。run.sh は、各段階の終わりに、`経過時間: N 分 M 秒` を表示する
- **管理者用フォルダ・対話・`--add-tier` の確認（2026-10-16 追加。手動の検証を、e2e に置き換えた）:**
  - `sf-init.sh` は、既定では**引数なしの対話**で実行する。先頭に、オーナーの選択 → XXXX の入力 → 確認の入力を足す（`e2e_make_identity_input OWNER XXXX`。オーナーの候補は `gh_owner_candidates admin` と同じ。複数なら位置の番号、1 つなら番号なし、なしならオーナーを入力）。`--with-args` で、引数 `--owner` / `--project` に切り替える。`sf-job.sh` も、既定は引数なし（作業フォルダの下のクローンの git remote から決まる。出力の「このフォルダの下のクローンから取得」で確認する）。
  - `sf-init` のあとの確認（新しく作ったときだけ。`--resume` の前回分は、古い形のことがある）: `admin/force-XXXX` ができた / 状態ファイルが `.sf-init-XXXX.env` / `.progress`（プロジェクト名つき）/ 進捗が Phase 10 / 古い形のフォルダ（`init` / `init-*`）がない / クローンが `admin` ブランチ（ローカル）/ GitHub に `admin` がある / `origin/admin` を追跡 / 完了画面の案内（「ローカルと GitHub の両方」「`main` から古くなる」。対話のときは、XXXX だけ入力の案内も）/ `sf-sync-wf.sh --check` が `admin` で実行でき、`main`（保護ブランチ）では断られる（確認のため一時的に `main` に切り替え、`admin` に戻す）。
  - **最初のメタデータの同期の確認**（`sf-init` のあと）: 完了直後のクローン（`admin` ブランチ）に、メタデータのファイル（`.gitkeep` 以外）が入っている / `main` に「定期更新」のコミットがある / ローカルの `main` が `origin/main` と一致 / 完了画面に「同期済みです」。
  - `--add-tier`（`_add_tier_check`）: 新しく作った**1 層**のリポジトリで、鍵一式に staging の組織があるとき、**Hello World の確認のあと**（先に行うとリポジトリが 2 層になり、リリースの確認の対象が変わるため）に、管理者用のクローン（`admin` ブランチ）で `sf-init.sh --add-tier staging`（入力: `Y` → ログイン先 `1`）を実行する。確認: コマンドの成功 / 終わったあとも `admin` ブランチ / `staging` ブランチ / Secret・Variable（`*_STG`）/ `branches.txt` を更新する PR / `main` へ直接 push していない（`main` の SHA が変わらない）。約 4 分。`--no-add-tier` で省略できる。
  - **起動のしかた（Windows）:** 標準の Git Bash（`C:\Git\bin\bash.exe -l`。`MSYSTEM=UCRT64`）で起動する。`C:\Git\usr\bin\bash.exe`（`MSYSTEM=MSYS` / `MINGW64` にしても）は、`openssl` が MSYS 版になり、`sf-init` の `-subj "//CN=…"`（Git Bash の Windows 版 `openssl` 向けの書き方）が読み飛ばされて、Phase 10 の証明書の生成で失敗する（コードの不具合ではない）。`gh` は、鍵一式の `E2E_GH_USER`（テスト用の組織の管理者）のトークンを、`GH_TOKEN` に設定して実行する（gh のアクティブなアカウントは書き換えない）。確認の質問には `Y` を渡す。所要時間は約 30 分。
  - **e2e の確認のコメントの書き方:** `chk "説明" \` の次の行に、コメントを書かない（行の継続の途中のコメントは、後ろのコマンドごと消える。以前、`sf-job.sh` の確認が、常に PASS になっていた）。
- 組織側の確認は `e2e_apex_count`（SOQL `SELECT COUNT() FROM ApexClass WHERE Name = '…'`。`totalSize` を読む）。前後で 0 → 1 → 0 になること
- 件数の確認の前に、管理用ログイン（`e2e_sf_admin_login`）を、やり直す（リリース後・削除後）。2 回目の `sf-job.sh`（`sf-start.sh`）が、同じ組織の接続を `sf org logout` してログインし直し、同じユーザーの認証は、エイリアスが違っても共通の保存先を使うため、問い合わせ用の接続が、使えなくなったと見ている（2026-10-06 の実機で、削除は成功したのに、削除後の件数の確認が失敗した。原因は推定）。`e2e_apex_count` は、失敗したとき、`sf` のエラーの要点を警告として表示する（次回から、原因が分かる）
- 後掃除（`e2e_cleanup_all`。前掃除、`--cleanup`、`cleanup.sh` で動く）は、組織に残った `SfToolsE2eHello` / `SfToolsE2eHelloTest` も、一覧（`e2e_list_target_apex`。名前の完全一致のみ）→ 削除（`e2e_delete_apex`。削除用のデプロイ）→ 再取得で確認する。一覧の取得失敗は、ECA と同様に「対象なし」とせず、失敗として記録する
- `gh` の呼び出し（`_e2e_gh`）は、`timeout`（`E2E_GH_TIMEOUT` 秒。既定 120）と標準入力の遮断付き。応答しない `gh` で、e2e が止まり続けないようにする（Git Bash で、`gh` の起動前に止まる現象が一度あったが、その場合は、この上限では防げない）
- ワークフロー（`wf-validate` / `wf-release` / `wf-metasync`）が失敗したら、後掃除の前に、失敗したステップのログの末尾（`E2E_FAIL_LOG_LINES` 行。既定 40）を表示する（`e2e_show_run_failure`。鍵一式の値は `***` に置き換える）。リポジトリは既定で残る（`--cleanup` のときは消える）が、その場で原因を追えるようにするため
- マージ時には `wf-propagate`（main へのマージ）も動く。e2e のリポジトリは `main` のみで `staging` / `develop` がないため、スキップして成功になること（`wf-propagate.yml` は、ブランチがなければスキップする。以前は `git checkout staging` が失敗して、赤い ✗ になっていた）を確認する。`wf-sequence` は、PR を開いたときに動き、成功する

**削除の安全ガード:**

- 削除対象は、名前の形式（上記のタイムスタンプ付き）が一致するものだけ。`SF_TOOLS`、`force-test-win` などは対象外（`e2e_is_target_*`）
- オーナーは、鍵一式の `E2E_OWNER` のみ。gh のログインユーザーが `E2E_GH_USER` と一致しないと動かない
- `e2e_guard_env` を通らないと、削除系の関数は動かない（`E2E_GUARD_OK=1`）。GitHub Actions 上では動かない
- `cleanup.sh` は既定で何も消さない。`--yes` でも、一覧を見せたうえで `delete` の入力を求める
- JWT 用の証明書フォルダ（`~/.sf-jwt/force-e2e-…`）は、中身が `server.key` / `server.crt` だけのときに限り削除する。ほかのファイルが入っていれば、消さずに失敗として返す（ほかの掃除は続ける）。シンボリックリンクは、対象外
- `$TMPDIR` の一時ファイル・フォルダ（`e2e-run.*` など）は、名前の形式・30 分以上経過・所有者が自分・シンボリックリンクでない、のすべてを満たすものだけ（2026-10-05 に、Codex のレビューを受けて補強）

**鍵一式の認証 URL（`E2E_SFDX_AUTH_URL`）:**

- 新しい `sf`（2.152 以降）は、`sf org display --verbose` で認証 URL を**隠し**、「`[REDACTED] Use 'sf org auth show-sfdx-auth-url' to view`」という文章を返す。そのため、`bootstrap.sh` は、`sf org auth show-sfdx-auth-url --no-prompt --json` で取得する（`e2e_get_sfdx_auth_url`。古い `sf` では、`display --verbose` にフォールバックする）
- 取得した値、および鍵一式の読み込み時の値は、形式（`force://<クライアント ID>:<シークレット>:<リフレッシュトークン>@<ホスト>`）を確認する（`e2e_valid_sfdx_url`）。形式に合わない値（隠された文章など）は、保存も使用もしない

**管理用ログイン（`e2e_sf_admin_login`）:** 認証 URL で、テスト用組織にログインし直す（削除・一覧の前）。失敗したら、`sf` の出力（原因。トークン・認証 URL のリフレッシュトークンは伏せ字）を表示し、`E2E_ADMIN_RETRY_WAIT` 秒（既定 5）待って、1 回だけやり直す。実機で、一度だけ原因不明の失敗（`RefreshTokenAuthError`）があり、同じ認証 URL での再実行は成功したため、一時的な失敗に備えている。

**一覧の取得失敗（「対象なし」と取り違えない）:** 削除の前に、GitHub のリポジトリ一覧（`e2e_list_target_repos`）と Salesforce のアプリ一覧（`e2e_list_target_ecas`）を取得する。取得の成否を確認せず、失敗を「対象なし」とみなすと、削除されないまま e2e が「成功」と報告する（実機で、アプリが 1 つ残る実例があった）。そのため、(1) 取得に失敗したら、`E2E_LIST_RETRY` 回（既定 3）、`E2E_LIST_RETRY_WAIT` 秒（既定 5）おいて再試行し、(2) それでも失敗なら、戻り値 1（何も出力しない）、(3) `e2e_cleanup_all` は、「対象なし」とは表示せず、ERROR を表示して失敗として記録する（`cleanup.sh` / `run.sh` の前掃除は中断、後掃除は結果を失敗にする。ほかの掃除は止めずに続ける）。取得の成否は、`gh` / `sf` の終了コードで判定する。アプリの削除（deploy）が失敗した場合は、失敗として記録し、削除後の再取得に失敗した場合も、削除できたとはみなさない。

**強制終了後の後始末:** `run.sh` が強制終了（ウィンドウが閉じるなど）すると、一時フォルダ（`$TMPDIR/e2e-run.XXXXXX`。認証 URL のファイルを含む）と、作成済みのテスト用リソースが残る。次回の前掃除、または `cleanup.sh` が、残った一時ファイル・フォルダ（`e2e-run.*` / `e2e-eca-del.*` / `e2e-sfdx-url.*`）も、掃除の対象にする。ただし、いま実行中の `run.sh` の一時フォルダ（`E2E_TMP`）と、30 分以内のもの（`E2E_TMP_MIN_AGE`。別の実行の途中かもしれない）は、対象外。

**Salesforce の外部クライアントアプリの削除:** 削除用のデプロイ（`sf project deploy start --manifest package.xml --post-destructive-changes destructiveChanges.xml`）で、5 つの構成要素を消す（`ExternalClientApplication` / `ExtlClntAppGlobalOauthSettings` / `ExtlClntAppOauthSettings` / `ExtlClntAppOauthConfigurablePolicies` / `ExtlClntAppConfigurablePolicies`）。ローカルのソースは要らない。アプリを消すと、そのアプリでの JWT のセッションも無効になるため、削除の前に、認証 URL（`sfdxAuthUrl`）で管理用にログインし直す。これで、テスト後の `sf` の認証は、健全な状態に戻る。

**sf のエイリアス:** `sf-init` は `prod` / `staging` / `develop` を付けるため、実行前の状態を保存し、終了時に復元する（増えたものは外し、変わったものは戻す）。

**前提と限界:**

- 台本（`e2e_make_input`）は、`sf-init` の質問の順番に依存する。質問を変えたら、台本も直す。`tests/test_sf-init.sh` の `test_e2e_input_sequence`（モック）が、ずれを検知する
- Token の作成と、テスト用組織への最初のログインは自動化できない（`bootstrap.sh` で 1 回だけ手動）
- 実機の Windows（Git Bash）で動かす前提。`sf` は npm 版が前提（`sf-init.sh` の `check_sf_cli` が確認する）。`run.sh` / `cleanup.sh` / `bootstrap.sh` も、冒頭の `check_sf_cli` で、終了コードが 0 でなければ中断する。e2e の `sf` の成否も、すべて終了コードで判定する（回避用の `E2E_SF_REDIRECTED` は廃止）
- テスト用組織は、本番または Developer Edition（Sandbox ではない）
- リポジトリの削除には、`gh` の `delete_repo` の権限が要る（`gh auth refresh -h github.com -s delete_repo`）
