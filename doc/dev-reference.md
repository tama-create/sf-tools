# sf-tools 開発リファレンス

> **本書の位置づけ:** CLAUDE.md のルール・判断基準を補完する詳細リファレンス。
> コーディング中に「どう書くか」を調べるときに参照すること。

---

## 1. クロスプラットフォーム詳細

### 1.1 Bash バージョン要件

- **Bash 3.2 以上で動くこと**。macOS 標準の `/bin/bash` は 3.2 で、今後も更新されない。スクリプトの先頭行は `#!/bin/bash` のため、Homebrew で新しい Bash を入れても、使われない。**追加のインストールなしで、macOS の標準のターミナル（zsh）から動かす**ために、3.2 を下限にする（Windows の Git Bash・Linux は 5 系で、同じコードが動く）
- `lib/common.sh` 冒頭で `BASH_VERSINFO` をチェックし、3.2 未満は、エラーを表示して `exit 1` する
- **Bash 4 以降の機能は、使わない**。代わりの書き方:

| 使わない（Bash 4 以降） | 代わり |
|---|---|
| `local -n`（nameref） | `set_var VARNAME VALUE`（`lib/platform.sh`。`printf -v`。変数名を検査する。`eval` は使わない）。配列を返すときは、決まった名前の配列に入れて、呼び出し元でコピーする（`sf-release.sh` の `_pl_out`） |
| `declare -A`（連想配列） | 通常の配列（キーと値を、同じ添字の 2 つの配列で持つ。`phases/init/status.sh`）、または、名前の配列（`phases/init/verify.sh` の `LEFT`） |
| `mapfile` / `readarray` | `while IFS= read -r line; do arr+=("$line"); done <<< "$text"` |
| `${x^}` / `${x^^}` / `${x,,}` | `tr '[:lower:]' '[:upper:]'` |
| `wait -n` | `sleep 0.2` ごとに `jobs -rp` で数え直す（`tests/run_tests.sh`。バージョンでは分岐しない） |
| `$( case ... esac )` | `$( )` の外で `case` を書き、変数に入れる（3.2 は、`case` の `)` を、`$( )` の終わりと取り違え、**構文チェック（`bash -n`）は通るのに、実行時に、コードの一部が文字として出力される**） |
| `\|&`・`&>>`・`${x@Q}`・`[[ -v x ]]`・`printf '%(...)T'`・負の添字 `${a[-1]}` | 使わない |

- 関数の中で `set_var "$1" ...` を使うときは、その関数の `local` 変数に、接頭辞（`_xx_`）を付ける（呼び出し元の変数名と同じ名前の `local` があると、そちらに代入されるため）
- 時間の上限つきの実行は `timeout` ではなく `run_with_timeout`（`lib/platform.sh`。macOS に `timeout` がないため）
- `tests/test_common.sh` の `test_bash32_compat` が、`bin lib phases hooks templates tests` を検索し（コメントの行は除く）、nameref・連想配列・`mapfile` / `readarray`・`${x^}` / `${x,,}`・`wait -n`・`|&` / `&>>`・`$( )` の中の `case` を使っていないことを確認する（`${x@Q}`・`[[ -v x ]]`・`printf '%(...)T'`・負の添字は、検索していない。レビューで守る）。あわせて、`set_var` / `run_with_timeout` の動作・`bin/*.sh` が実行権限つき（100755）で git に記録されていること・`common.sh` の下限が 3.2 であることを確かめる。CI の `test-macos`（結合テストを除く全件）と `integration` の macOS のジョブは、`/bin/bash`（3.2）で実行する

### 1.2 OS 検出の統一ルール

| 目的 | 使う方法 | 理由 |
|---|---|---|
| GitBash 検出 | `is_gitbash`（`lib/platform.sh`。`$OSTYPE` が `msys*` / `mingw*` / `cygwin*`） | Bash 組み込み・サブプロセス不要。Git Bash でも、環境により `$OSTYPE` が `cygwin` になるため、`msys` / `mingw` だけを見ない |
| macOS 検出 | `[[ "$OSTYPE" == "darwin"* ]]` | 同上 |
| WSL 検出 | `grep -qi microsoft /proc/version 2>/dev/null` | `/proc` 非存在環境は `2>/dev/null` で抑制（`open_browser`・`sf-start.sh`） |
| macOS/Linux 分岐が必要な場合のみ | `uname -s` | `stat` 書式差異など限定的に使用（`sf-install.sh` の `_get_mtime`） |

> `open_browser` は、Git Bash → WSL → macOS → Linux の順に判定する（`$OSTYPE` の判定のほうが確実なため、Git Bash を先にする）。

> `uname -s` はサブプロセスを起動するため遅い。OS 検出は原則 `$OSTYPE` に統一すること。

### 1.3 新規スクリプト追加・大きな変更後のチェック

**動作環境（すべての OS で動くことが目標。どの環境を、実際に動かして確かめたかは、9.7 の記録が正本）:**

- **クライアント PC: Windows + Git Bash / macOS / WSL（Ubuntu）**: 単体テスト（CI または手元）と、実環境の通し検証（e2e）を、実際に動かして確認済み
- **サーバー: Linux（GitHub Actions の Ubuntu ランナー）**: 検証・リリース・メタデータ同期のワークフローが、`sf-release.sh` / `sf-metasync.sh` を実行する。単体テストと shellcheck を CI で毎回確認し、ワークフローは e2e で実際の Salesforce に対して実行して確認済み。**Linux をクライアント PC として使うことは、想定しない**（WSL の Ubuntu は、確認済み）
- 新しい環境や、未検証の環境で動かすときは、先に `bash tests/e2e/doctor.sh` で、環境を確認する（9.6）
- 環境ごとの「検証済み」は、実際に動かした範囲だけを書く（README・文書サイト（`site/guide/install.html`）の表と、9.7 の記録を、実際の確認と一致させる）

- プラットフォーム固有コマンド（`powershell.exe` / `open` / `xdg-open` 等）は `command -v` で存在確認してから使うこと
- `/proc/version` / `/proc/` 配下のファイルは macOS / GitBash に存在しないため `2>/dev/null` を付けること

---

## 2. テスト詳細

### 2.1 主要テスト対象

> `tests/run_tests.sh` の `TEST_FILES` に登録したファイルを、すべて載せる（`test_helper.sh` は部品のため除く）。新しいテストファイルは、`TEST_FILES` とこの表の両方に足す（引数なしの全件実行は、`tests/test_*.sh` のうち `TEST_FILES` に未登録のものを WARNING で出す）。各ファイルのテストケースの正本は、そのファイルの冒頭コメント。

| ファイル | 対象スクリプト |
|---|---|
| `test_common.sh` | lib/common.sh・input.sh・platform.sh・project.sh（`check_gh_owner`・入力関数（`read_secret` / `read_key` / `press_enter`）・`_mask_secrets`・`is_gitbash`・`open_browser`・`is_reserved_org_alias`・`is_protected_branch`・`check_sf_cli`・`print_admin_warning`・`run_isolated_home`・`ensure_sf_tools_latest`・`merge_package_xml`・`sed_inplace` など・Bash 3.2 対応（`test_bash32_compat`。1.1）・`ensure_admin_branch` / `push_admin_branch`・`get_target_org`。`json_get`: 基本・先頭のドット・配列・日本語や引用符・警告つき・不正な JSON・`node` がない・`set -e` を含む。`node -e` だけは、モックではなく本物の node に渡す: `test_helper.sh`） |
| `test_init-common.sh` | phases/init/init-common.sh（`ensure_sf_tools_branch`・JWT 用の証明書の発行先（subject）。実際の Git と一時 bare リポジトリを使用） |
| `test_org.sh` | lib/org.sh（ログイン先の 3 択・環境変数の指定・組織の種類の判定・本番は main のみのガード・保存） |
| `test_verify.sh` | phases/init/verify.sh と lib/verify-common.sh（実行できない場所・--plan・診断の不足・確認（N / q / EOF・本番の明示）・1 層・3 層（develop → staging → main の順）・失敗（マージしない・案内）・取り違えの検出・--cleanup・部品） |
| `test_diag.sh` | lib/diag.sh（セットアップの診断: すべてそろっている・不足と直し方・一覧を取得できない（？。不足に数えない）・段階の数に応じた確認・組織の種類の記録がない（！）・直近の実行・読み取りのみ） |
| `test_wizard.sh` | lib/wizard.sh（ウィザード形式の画面の部品: 現在地・チェックリスト・確認・失敗・完了） |
| `test_sf-unhook.sh` | sf-unhook.sh |
| `test_sf-hook.sh` | sf-hook.sh |
| `test_sf-init.sh`・`test_sf-init2.sh`・`test_sf-init3.sh` | sf-init.sh（テスト関数を、3 つのファイルに、所要時間で均等に分けた。時間のかかる 1 ファイル（Actions の Windows で 約 10 分）を、並列に動かすため。共通の部品は `tests/init-test-lib.sh`。各ファイルの冒頭に、そのファイルのテスト関数の一覧がある。新しいテスト関数は、いちばん軽いファイルに足す。`--changed` は、`bin/sf-init.sh`・`phases/init/*`・`tests/init-test-lib.sh` の変更で、3 つとも動かす） |
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
| `test_sf-launcher.sh` | sf-launcher.sh（`common.sh` を読み込まない standalone のランチャー） |
| `test_security.sh` | セキュリティ修正の退行の検出（静的解析: `run` 経由の `sf org display --verbose` の禁止・`run` の一時ファイルの置き場所など。実行時: ログに `sfdxAuthUrl` が残らない・ログのフォルダが 700） |
| `test_e2e.sh` | tests/e2e/ の安全ガードと部品（gh / sf はモック。実環境には接続しない。名前の判定・Actions 上のガード・削除関数・鍵一式の読み込み・`cleanup.sh` の既定など） |
| `test_run-tests.sh` | tests/run_tests.sh の `--shard`（`SF_TEST_LIST_ONLY=1` で分け方だけを確かめる: 漏れ・重複がない・いつも同じ分け方・不正な指定は終了コード 2） |
| `test_cli_args.sh` | 全 `bin/sf-*.sh` の引数: 冒頭コメントの【オプション】を 1 つずつ値なしで渡し、15 秒以内に終わる・「不明なオプションです」と言われない。文書にないオプションでも止まらない |
| `test_sf-check.sh` | sf-check.sh（種類の可否の判定・同梱の表 `config/metadata-capability.txt` の形式を含む） |
| `test_integration-coverage.sh` | 結合テストのカバレッジ表（`doc/integration-test-plan.md` の 10）のガード。全コマンド・フック・ワークフローが表に載っていること、各行が「結合あり（パターンの番号が定義済み）」か「結合なし（理由が空でない）」であることを確かめる。新しいコマンドを足して、表に載せ忘れると失敗する |
| `test_integration.sh` | 結合テスト L1（ローカル結合）。実 git ＋ローカルの bare の origin ＋ fake（gh・sf・npm・curl・code・ssh。`tests/integration/lib.sh`）で、複数のコマンドを連動させる。シナリオ: A13a（sf-job → sf-start → sf-install → sf-hook → sf-dryrun → sf-push）・X2-3（プッシュ失敗 → 再実行）・X6-2（確認の n / q / EOF / 空 Enter で、外部へ書き込まない）・X6-1（`GITHUB_ACTIONS=true` での、コマンドごとの挙動の表）。計画: `doc/integration-test-plan.md`。詳細は 2.1.2 |
| `test_integration-git.sh` | 結合テスト L1: 実 git のフック（pre-commit・pre-push）・main の取り込み・コンフリクト・2 つのジョブ・sf-unhook ⇄ sf-hook・同時 push（A15・A2・A5・A6・A7・A9・X4-1a） |
| `test_integration-guards.sh` | 結合テスト L1: 安全ガード（別のオーナー・admin・force-* の外・prod 接続中の拒否（X6-1b）・remove-target の危険な入力（X6-4）・sf-sync-wf の上書き（X6-5）） |
| `test_integration-secrets.sh` | 結合テスト L1: sf-update-secret の成功・失敗で、秘密鍵・コンシューマーキーが、画面・ログ・一時ファイルに残らない（X7-1・X7-2・B2 のローカル部分） |
| `test_integration-job.sh` | 結合テスト L1: sf-job の失敗（gh・権限・リポジトリ・ブランチの衝突・API の失敗・clone の失敗）・ジョブ名の不正・パスの空白（X1・X2-2・X5-1・X5-2） |
| `test_integration-misc.sh` | 結合テスト L1: 壊れた Apex・sf-deploy の確認・branches.txt と deploy-target の不正・古い ~/sf-tools・sf-install の間隔・再実行・環境の不備・同時のデプロイ（A1・A10・A12・X3-2〜X3-4・X4-1c・X5-3・X8-1） |
| `test_integration-init.sh` | 結合テスト L1: sf-init の通し（1 層）・生成物を後続コマンドが使う・完了済みの再実行・中断と再開（clone・push・Secret・SIGTERM・SIGKILL）・PAT の扱い（I1・A13・X8-1・X2-1・X7-1） |
| `test_integration-init2.sh` | 結合テスト L1: sf-init の状態の食い違い（X3-5〜X3-7）・PAT の権限不足・別ユーザー・名前の衝突（X1-2・X1-3）・同時起動（X4-1） |
| `test_integration-metasync.sh` | 結合テスト L1: sf-metasync のローカルの動作（作業ブランチから main への反映・元のブランチへの復帰・stash の復元・失敗時の後始末）（B3 のローカル部分・X8-4・X8-5） |
| `test_integration-rerun.sh` | 結合テスト L1: 再実行（冪等）と手元のフックの改変（sf-push・sf-dryrun・sf-update-secret を 2 回続けて実行・フックの改変と削除を sf-hook が戻す）（X8-1・X3-10） |
| `test_integration-next.sh` | 結合テスト L1: sf-next の判定（3 層で、なし・PR 発行中・マージ済み・順序外・Y で開く URL）と、main が進んだときの取り込み（A5） |
| `test_integration-init3.sh` | 結合テスト L1: sf-init の診断（--status が、Secret・Variable・ワークフロー・ブランチ・リポジトリの欠けを見つける）・admin ブランチの欠け・Salesforce の失敗・JWT のリトライの上限・同名のリポジトリの同時作成（X3-8・X3-9・X1-4・X9-1・X4-1b） |
| `test_sf-typecheck.sh` | sf-typecheck.sh / lib/typecheck.js（node が無い環境では、スキップ。sf はモック） |
| `test_sf-prepush.sh` | sf-prepush.sh（hooks/pre-push から呼ばれる本体。`--changed` は、`hooks/pre-push` の変更でも動かす） |
| `test_sf-precommit.sh` | sf-precommit.sh（hooks/pre-commit から呼ばれる本体） |
| `test_sf-push.sh` | sf-push.sh |
| `test_sf-update-secret.sh` | sf-update-secret.sh |
| `test_docs.sh` | Markdown 文書の見出しの番号（番号がある・深さが階層と合う・連番・LF。`CLAUDE.md` 1.4 の決まり） |
| `test_docs_facts.sh` | 文書（`site/` の HTML・README。`doc/` は対象外）に書かれた事実（コマンド名・オプション・パス・環境変数）が、コードと食い違っていないか（例外は `tests/docs-facts-allow.txt`。コマンドの一覧に、全 `bin/sf-*.sh` が載っているかの逆向きの確認も含む）。Windows はプロセス起動が遅いため、awk でまとめて処理する |
| `test_docs_stamps.sh` | 冒頭コメントが、文書を最後に見直したときから変わっていないか（`doc/doc-stamps.txt` の印。`tests/docs-stamp.sh` で確認・付け直し）。自己テストつき |
| `test_site.sh` | HTML の文書サイト `site/`（書き出しの決まり・相対リンクと見出しの実在・目次（`assets/site.js` の NAV）への登録漏れ・LF・コードのブロックのエスケープ・`pages.yml`。見た目は、確認しない） |
| `test_sf-sync-wf.sh` | sf-sync-wf.sh |
| `test_wf-sequence.sh` | templates/.github/workflows/wf-sequence.yml（YAML の判定スクリプトを取り出して、実際の git リポジトリで、順序どおり・順序外・最下位・環境ブランチからの PR を確認） |

> テスト以外の部品: `tests/test_helper.sh`（2.2）・`tests/init-test-lib.sh`（sf-init のテストの共通部品）・`tests/integration/lib.sh`・`init-lib.sh`（2.1.2）・`tests/docs-stamp.sh`（文書の見直しの印の確認・付け直し）・`tests/docs-facts-allow.txt`（`test_docs_facts.sh` の例外）。
> 実環境の e2e（`tests/e2e/`: `run.sh`・`scenario.sh`・`doctor.sh`・`cleanup.sh`・`bootstrap.sh`・`lib.sh`・`ci-fixture.sh` / `ci-mask.sh` / `ci-notify.sh`・`shims/`（`sf org login web`・ブラウザなどの差し替え）・`fixture.example.env`）は、`run_tests.sh` に含めない。詳細は 9.6。

#### 2.1.1 テストの実行方式と CI

- **並列実行**: `run_tests.sh` は、複数ファイルを、同時に（既定は CPU の数まで）動かす。時間のかかるファイル（`HEAVY_FIRST`: `test_sf-init.sh` など）を先に起動し、標準入力は閉じる（入力待ちで止まらないため）。出力は、ファイルごとに溜めて、`TEST_FILES` の順に表示・集計する。実測（8 コア・WSL）: 直列 約 400 秒 → 並列 約 170〜230 秒。並列数を 4〜100 で変えても、大きな差は、出なかった。
- **WSL**: Git Bash から実行すると、自動で WSL に移り、ext4 にコピーして実行する（`/mnt/c` の 9P は、遅いため）。WSL には `node` がなく `node.exe` だけがある場合があり、`test_helper.sh` の node のモックは、`node -e` を、本物（`node` または `node.exe`）に渡す（`json_get` のテストのため）。
- **クロスプラットフォームの CI**: 同じワークフローに、`test-macos`（`macos-latest`。macOS 標準の `/bin/bash`（3.2）と、BSD の `sed` などを、そのまま使う。何も追加で入れない）と `test-windows`（`windows-latest` の Git Bash。`SF_TEST_NO_WSL=1`・`core.autocrlf=false`。**2026-10-20 から、全件（結合テスト L1 を含む）を `--shard` で 6 つのジョブに分けて並列に動かす**。実測は、計画書 12）がある。**2026-10-14 から、失敗扱い**（`continue-on-error` なし。以前は、導入の初期として、結果の表示のみだった）。Windows は、並列で実行する（約 15 分）。再び異常終了するときは、`--serial` に戻す。**BSD / GNU の差**として、`sed -i`（BSD は、`-i` の直後に拡張子が必要 → `sed_inplace`）・sed の `\x` / `\t`（BSD は解釈しない → Bash の `$'..'` で展開）・`date -d`・`touch -d`・`stat -c`・`nproc`・`timeout`（macOS にない → `run_with_timeout`）・`base64 -w 0`（macOS にない → `base64_oneline`）・`wc -l`（BSD は、数字の前に空白が付く → 文字列として使うときは `tr -d ' '`）・`sort -u`（macOS の sort は、環境によって、日本語の文字列を、同じものとみなして、数が合わなくなる → 重複を除くだけなら `awk '!seen[$0]++'`。並べ替えも要るときは `LC_ALL=C sort -u`（バイト順。`merge_package_xml`・`discover_clones`）。2026-10-24 に、必須チェック名のテストで発生）に注意する。`openssl req -subj`（先頭の `//` は Git Bash 専用。macOS・Linux に渡すと、発行先が空の証明書ができ、Salesforce が「証明書ではありません」と拒否する → `_jwt_cert_subject_arg` が OS で切り替え、`generate_jwt_cert` が生成後に空でないことを確認する。既存の空の証明書は、`ensure_jwt_cert_subject` が、秘密鍵そのままで作り直す）。macOS の `TMPDIR` は、`/` で終わる（`"${TMPDIR:-/tmp}/x"` が `T//x` になり、bash の `cd` が作る PWD（`T/x`）と、テストの期待値が食い違う）ため、`tests/test_helper.sh` が、末尾の `/` を除く。macOS の `tar` は、日本語のファイル名を NFD に変えて展開するため、テストで、HOME を差し替えて git を使うときは、`core.precomposeunicode` をリポジトリに設定する。
- **CI**: `.github/workflows/test.yml`（Ubuntu のランナー）。PR（main・development 向け）と development への push で、全件テスト（`bash tests/run_tests.sh`）と shellcheck（`-S warning`。バージョン固定 `shellcheck-py==0.11.0.1`）を実行し、どちらも失敗扱いになる。Secrets は使わない。shellcheck の設定は、リポジトリ直下の `.shellcheckrc`（`SC1090` / `SC1091`・`SC2034`・`SC2155` を、理由つきで無効化）。個別の誤検知は、該当行の直前に `# shellcheck disable=SCxxxx  # 理由` で除外する。手元での実行: `shellcheck -S warning $(git ls-files 'bin/*.sh' 'lib/*.sh' 'phases/*.sh' 'hooks/*' 'templates/*.sh')`（`pip install shellcheck-py` など）。

#### 2.1.2 結合テスト L1（`tests/test_integration*.sh`・`tests/integration/lib.sh`・`init-lib.sh`）

実際の `git` で、複数のコマンドを、続けて動かす（単体テストは、コマンドごとに、`git` などをモックにする。結合テストは、モックにしない）。

- **サンドボックス**: `mktemp -d` の下に、`home/`（HOME。`~/sf-tools` に、`bin lib hooks config templates phases` の写し。git リポジトリにして、`sf-install` の `git pull` が動くようにする）・`bin/`（fake）・`state/`（fake の状態）・`origin.git`（bare。実 git）・`work/`（作業フォルダ）を作る。終了時に、`trap` で削除する（`IT_KEEP=1` で残せる。調査用に `it_attach` でつなぎ直せる）。
- **リモートの扱い**: グローバルの git の設定 `url."ssh://git@github.com/".insteadOf "https://github.com/"` ＋ 環境変数 `GIT_SSH_COMMAND`（fake の `ssh`）で、`https://github.com/...` を、ローカルの bare に向ける。`https` のまま bare に向けると、`git remote get-url origin` がローカルのパスを返し、オーナー・リポジトリ名を読むコード（`lib/project.sh` など）が動かないため、`ssh://git@github.com/OWNER/REPO` の形で返るようにしている（`sf-init --verify` など、URL を読むコマンドが動く）。
- **fake**: `gh`（`auth`・`repo view`・`api user`・`api repos/R/branches/B`・`api repos/R/git/refs` の POST のみ。ブランチの作成は、bare への `update-ref`）・`sf`（`org display`・`org login`・`project generate manifest`・`project deploy start` など。ログイン状態は `state/sf.alias`）・`npm`・`curl`・`code`（`--wait` で渡されたファイルに、コミットメッセージを書く）。**未対応の呼び出しは、終了コード 99 と「未対応の呼び出し」で失敗する**（黙って成功しない）。呼び出しは、すべて `state/calls.log` に記録する。
- **fake の追加分**: `gh` の `repo create`（空の bare を作る）・`repo edit`・`api user --include`（PAT のスコープ。`state/gh.scopes`）・`api repos/R`（`permissions.admin`）・`rulesets`（POST で本文を保存・GET で名前から ID）・`secret set` / `variable set`（値は `state/secrets`・`state/variables`。呼び出しの記録には残さない）・`workflow run` / `run list` / `run view`（実行の記録 `state/runs`。結果は `state/gh.run_conclusion`）、`sf` の `data query`（Organization・プロファイル）・`project retrieve start`（コンシューマーキーの目印）・`project generate manifest`・`org login jwt`。`ssh` の失敗は `it_ssh_fail`、デプロイの失敗は `it_deploy_fail`、push の拒否は `it_origin_reject`、古い `~/sf-tools` は `it_sftools_advance`。
- **手早いクローン**: `it_make_clone 名前 ブランチ` は、origin から clone → ブランチ作成 → フック設置 → `release/ブランチ/` の準備までを行う（`sf-job`・`sf-start`・`sf-install` を通さない版。通しは A13a・A13 が確認する）。`it_add_class`・`it_set_deploy_target`・`it_origin_commit`（別の開発者として origin に積む）も、部品。
- **sf-init の部品**（`tests/integration/init-lib.sh`）: 標準の入力（1 層）・`_init`・`_state`（完了後の状態を 1 行にして、通しの基準と比べる）・`mk_interrupted`（push の拒否で止めた状態）・`_init_kill`（バックグラウンドで起動し、fake の呼び出しが始まったら SIGTERM / SIGKILL で止める。遅い呼び出しは `it_fault ... 0 "" 25`（25 秒の遅延）で作る）・`_no_leak`（秘密の目印が、出力・ログ・一時ファイルに残らない。陽性対照つき）。
- **故障注入**: `it_fault CMD パターン N 回数 終了コード メッセージ [遅延]`（fake の呼び出しの N 回目から、回数だけ失敗させる）。git のプッシュの失敗は、`it_origin_reject on`（bare の `pre-receive` フック）。
- **環境の隔離**: `it_run` は、`GITHUB_ACTIONS`・`CI`・`GH_TOKEN`・`GITHUB_TOKEN` を外して実行する（CI のランナーは `GITHUB_ACTIONS=true` を持っており、持ち込むと、管理者向けの確認が省略され、結果が変わる。CI で初めて見つかった）。X6-1 は、`env GITHUB_ACTIONS=true` で明示する。
- **ツール更新の保護**: `sf-install` の 24 時間に 1 回のツール更新は、Windows で本物の `git update-git-for-windows` を動かすため、サンドボックスには、更新済みのスタンプ（`.sf-tools-last-update`）を置く。更新の経路を確かめるテストでは、先に `it_block_git_update` を呼ぶ。
- **不変条件の部品**: `it_snap`（HEAD・コミット数・ブランチ・フック数・未コミット数）・`it_remote_snap`・`it_mutating_calls`（外部へ書き込む呼び出しの一覧）・`it_leak_count`（秘密の漏れ）。
- **時間**: シナリオごとの所要時間を出す。`IT_SHOW_RUNS=1` で、遅い呼び出しの上位を出す。CI の実測（2026-10-19。結合テストの第 1 弾）は、Ubuntu 約 16 秒・macOS 約 40 秒・Windows 約 2 分。手元の Windows（Git Bash）は、プロセスの起動が遅く、10 倍ほどかかる。`IT_SCENARIOS`（実行するシナリオ。既定は全部）・`IT_X62_QUICK=1` で、短くできる。
- **実行**: `run_tests.sh` の全件に含まれる（時間のかかるファイルとして先に起動）。CI の全件テストのジョブは、`SF_TEST_SKIP_INTEGRATION=1` で、結合テスト（`test_integration*.sh`。表のガード `test_integration-coverage.sh` は残す）を外し、別のジョブ `integration`（Ubuntu・macOS）で、`run_tests.sh` に名前を渡して並列に動かす（Windows は、結合テストを含む全件を、`--shard` で 6 つのジョブに分けて動かす）。`--changed` は、`bin/sf-*.sh`・`hooks/*`・`tests/integration/*`・結合テストの変更で、結合テスト全部を含める。
- **結合テストで見つかり、直したもの**: `sf-push` は、変更がないと「コミット対象なし」で終わり、コミット後にプッシュが失敗した再実行で、未プッシュのコミットが取り残された。現在は、変更がなくても、追跡先（upstream）より進んだコミットがあれば、コミットせず、`git push` だけ行う（X2-3 が確認する）。 また、`sf-push` は、detached HEAD・保護ブランチ（main など）の上では、コミットする前に止める（R5）。そのほか、`sf-check` は、存在していても、リポジトリの外を指すパス（絶対パス・`..` を含むパス）を、エラーにするようにした（X6-4）。`sf-init` の「続きから」は、Phase 8 まで完了と記録されているのに、origin に `main` がないときは、続けずに拒否する（完了の直前の記録のときも、完了にしない。X3-6・X3-7）。

### 2.2 `test_helper.sh` の前提

読み込むと、`SF_TOOLS_DIR`・`TESTS_DIR` を決め、`SF_TOOLS_SF_CHECK_STAMP=/dev/null`（`check_sf_cli --cache` の記録を、本物のホームに作らない）を export し、`TMPDIR` の末尾の `/` を除く（2.1.1）。

判定・集計の関数: `pass` / `fail` / `skip`・`assert_exit_ok` / `assert_exit_fail`・`assert_file_exists` / `assert_file_not_exists`・`assert_dir_exists` / `assert_dir_not_exists`・`assert_file_contains` / `assert_file_not_contains`・`assert_executable`・`assert_equals`・`assert_output_contains` / `assert_output_not_contains`・`print_summary`（最後に呼ぶ。失敗があれば戻り値 1）。

セットアップ関数:

| 関数 | 用途 |
|---|---|
| `setup_force_dir` | `force-*` の一時ディレクトリを作成（`.git/hooks`・`.sf`・`sf-tools/config/branches.txt`（main・staging・develop）など） |
| `setup_regular_dir` | 通常ディレクトリを作成 |
| `setup_mock_bin` | モックコマンド用ディレクトリを作成（**呼び出し後に必ず `export MOCK_CALL_LOG="$mb/calls.log"` を実行すること**） |
| `setup_std_env TD MB MH` | 上の 3 つ（`setup_force_dir`・`setup_mock_bin`・`setup_mock_home`）を作って、指定した名前の変数に入れ、`MOCK_CALL_LOG` も export する（`local td mb mh; setup_std_env td mb mh`） |
| `setup_release_dir TD [BRANCH]` | `release/<branch>/`（省略時 `feature/test`）に `deploy-target.txt`・`remove-target.txt`、`branch_name.txt`、参照先の `TestClass.cls` を作成 |
| `setup_mock_home` | sf-tools 一式（`.git`・`logs` を除く）を `sf-tools/` にコピーした一時 HOME を作成 |
| `run_script_with_no SCRIPT [ARGS]` | 標準入力に `n` を流して実行する（確認で止まらないため） |
| `teardown ARG...` | 指定ディレクトリを削除 |
| `sedi SCRIPT FILE` / `touch_ago 分 FILE...` | テストの中で使う、GNU / BSD 共通の置換・更新日時の変更（`sed -i`・`touch -d` を直接使わない） |

モック生成関数（`create_all_mocks` で一括生成）:

| 関数 | モック対象 |
|---|---|
| `create_mock_git` | git |
| `create_mock_sf` | sf（Salesforce CLI） |
| `create_mock_npm` | npm |
| `create_mock_code` | code（VS Code） |
| `create_mock_gh` | gh（GitHub CLI） |
| `create_mock_node` | node（`node -e` だけは本物の node / node.exe に渡す。`json_get` のため） |
| `create_mock_browser` | powershell.exe / xdg-open / open / wslview / start |
| `create_mock_openssl` | openssl（JWT の証明書の生成。`-out` にダミーの鍵を書く。`MOCK_OPENSSL_SUBJECT`・`MOCK_OPENSSL_EXIT`） |

> モックは、呼び出しを `MOCK_CALL_LOG` に記録する（git は `MOCK_GIT_*` などの環境変数で挙動を変える。詳細は、各関数の中）。

> `create_mock_browser` は WSL 環境でブラウザが実際に起動することを防ぐために必須。新規スクリプトがブラウザ・GUI 系コマンドを追加した場合はこのモックに追記すること。

---

## 3. 共通ライブラリ (`lib/common.sh`) 詳細

> 仕様の正本は、各ファイルの冒頭コメント（【提供する関数】）と、関数ごとの説明コメント。ここは要点だけ。
> **構成**: `lib/common.sh` が窓口で、ログ（`log`）・実行（`run`）・終了（`die`）・`show_help`・`reject_unknown_args`・`print_admin_warning`・`json_get`・`_mask_secrets` / `_strip_ansi` / `_strip_term_codes` と定数を持つ。残りの関数は、責務ごとのファイルに分けてあり、`common.sh` が、最後に `input.sh` → `platform.sh` → `project.sh` の順で `source` する（呼び出し側は、`common.sh` だけを `source` すればよい。この 3 つは、単独では `source` しない）。
> - `lib/input.sh`（対話入力: `read_input` / `read_key` / `press_enter` / `read_or_quit` / `read_secret` / `ask_yn`）
> - `lib/platform.sh`（OS・外部コマンド: `is_gitbash` / `set_var` / `sed_inplace` / `base64_oneline` / `run_with_timeout` / `run_isolated_home` / `check_sf_cli` / `open_browser`）
> - `lib/project.sh`（プロジェクト: `get_target_org` / `check_force_dir` / `resolve_init_identity` / `resolve_job_identity` / `check_gh_owner` / `get_branch_list` / `is_reserved_org_alias` / `is_protected_branch` / `required_status_check_names` / `ensure_sf_tools_latest` / `merge_package_xml` / 管理者用のクローンの関数など）
>
> `lib/org.sh`・`lib/wizard.sh`・`lib/diag.sh`・`lib/verify-common.sh`（これが `lib/verify-samples.sh` を読む）は、`common.sh` からは `source` しない。使うスクリプトが、`common.sh` のあとに個別に `source` する。`lib/typecheck.js` は、`bin/sf-typecheck.sh` が `node` で起動する（Node の標準ライブラリのみ。境界は、このファイルだけ）。
> テスト: `common.sh`・`input.sh`・`platform.sh`・`project.sh` は `tests/test_common.sh`（`project.sh` のプロジェクトの特定は `tests/test_project-identity.sh`）。`org.sh` は `test_org.sh`、`wizard.sh` は `test_wizard.sh`、`diag.sh` は `test_diag.sh`、`verify-common.sh` は `test_verify.sh`、`typecheck.js` は `test_sf-typecheck.sh`。

全スクリプトは `source "$SCRIPT_DIR/lib/common.sh"` の前に以下を `readonly` で定義すること。

| 変数 | 役割 |
|---|---|
| `SCRIPT_NAME` | スクリプト名（拡張子なし）。`run` のログの行（`[SCRIPT_NAME.sh]`）に使う |
| `LOG_FILE` | ログファイルのパス（必須。未定義なら `[FATAL ERROR]` を表示して `exit 1`） |
| `LOG_MODE` | `NEW` = source 時にログファイルを空にする / それ以外（`APPEND` など）= 追記 |
| `SILENT_EXEC` | `--verbose` / `-v` 指定時のみ 0、それ以外は 1（定義しない。source 時に、引数から自動で設定する） |

source 時の動作: Bash 3.2 未満なら `exit 1` → `LOG_FILE` の確認 → カレントディレクトリ名が `force-` で始まらなければ `exit 1`（`SF_INIT_MODE=1` のときは確認しない。force-* の外で動く `sf-init.sh` とその `phases/init/`・`sf-job.sh`・`sf-typecheck.sh`・`tests/e2e/` が export する）→ `LOG_FILE` のフォルダを作る（chmod 700）→ 色の定数（標準入力・標準エラーのどちらも端末でないときは空）→ 上の 3 ファイルを `source`。

### 3.1 主な関数

| 関数 | シグネチャ | 用途 |
|---|---|---|
| `log` | `log LEVEL MESSAGE [DEST]` | 画面（標準エラー）・ログファイル（色なし）に出力。`DEST` は `BOTH`（既定）/ `SCREEN` / `FILE`。戻り値は常に 0 |
| `run` | `run CMD [ARGS...]` / `VAR=$(run CMD ...)` | コマンド実行、ログ出力、戻り値判定（3.3）。標準出力が端末でないとき（命令置換など）は、出力（標準エラーを含む）を標準出力に返す。応答は `SILENT_EXEC=1`（既定）でログのみ、`-v` で画面にも出す |
| `die` | `die MESSAGE [EXIT_CODE]` | `log FATAL` で出力して終了（既定 1）。命令置換の中では、そのサブシェルだけが終わる |
| `show_help` | `show_help` | 呼び出し元の冒頭コメントの第 2 ブロック（2 つ目〜3 つ目の `# ===`）を表示して `exit 0`（`--help` / `-h`） |
| `reject_unknown_args` | `reject_unknown_args "$@"` | `-v` / `--verbose` 以外の引数があれば「不明なオプションです」で `die`（引数を受け付けないコマンド用） |
| `print_admin_warning` | `print_admin_warning [--standard] [行...]` | 管理者向けの赤い警告ボックス（3.4.1）。確認は含まない |
| `_strip_ansi` / `_strip_term_codes` | `... \| _strip_ansi` | 標準入力から ANSI エスケープ（`_strip_term_codes` は絵文字・U+2000〜U+2FFF の記号も）を除く（GNU / BSD 共通）。名前は `_` で始まるが、外からも使ってよい（`sed` に `\x1b` を直書きしない: CLAUDE.md 2.2） |
| `sed_inplace` | `sed_inplace SCRIPT FILE`（`lib/platform.sh`） | ファイルを、その場で置換する（GNU / BSD の sed 共通。`sed -i.bak` ＋ バックアップの削除）。`sed -i` の代わりに使う |
| `base64_oneline` | `... \| base64_oneline`（`lib/platform.sh`） | 標準入力を base64 にして、改行なしの 1 行で出す（GNU / BSD 共通）。`base64 -w 0` は macOS にないため、代わりに使う |
| `set_var` | `set_var VARNAME VALUE`（`lib/platform.sh`） | 指定した名前の変数に、値を代入する（nameref の代わり。Bash 3.2 で動く）。変数名が、英数字と `_` でなければ `die`。値は、評価しない |
| `run_with_timeout` | `run_with_timeout 秒 CMD [ARGS...]`（`lib/platform.sh`） | 時間の上限つきで実行する。`timeout` があれば使い、なければ（macOS）、背景で実行して監視する。時間切れは 124。標準入力は、そのまま渡す |
| `json_get` | `VALS=$(json_get "$JSON" パス...) \|\| ...`（複数のパスは `while IFS= read -r L; do V+=("$L"); done <<< "$VALS"`。`mapfile` は Bash 4 以降のため使わない） | JSON から値を取り出す（sf CLI の出力など。GitHub の情報は `gh --jq`）。Node の標準機能のみ。パスは `.` 区切り（`result.records.0.Id`。先頭の `.` は許容。`*` は配列・オブジェクトの全要素に展開し、要素ごとに 1 行）。パス 1 つにつき 1 行（値なし・null は空行。オブジェクト・配列は JSON 文字列。値の中の改行は空白 1 つ）。まず全体を厳密に読み、失敗したときだけ最初の `{` から最後の `}` までを読む（`run` は標準エラーも標準出力に混ぜるため、sf の警告が前後に付く）。読み取れない・node がないときは終了コード 1 |
| `get_target_org` | `get_target_org [ALIAS]` | 対象組織エイリアスを解決して出力。優先順位: 引数 > 環境変数 `SF_TARGET_ORG` > `sf org display --json`。`sf org display` で取れないときは、待って、やり直す（`SF_TOOLS_ORG_DISPLAY_TRIES` 既定 3・`SF_TOOLS_ORG_DISPLAY_WAIT` 既定 2 秒）。それでも取れなければ、sf の応答の要点（message）を WARNING で残して、戻り値 1。一時的な失敗（理由が空の `RefreshTokenAuthError` など）で、e2e の新しいジョブのクローンの `sf-dryrun` が、1 度だけ「特定できません」で止まったことへの備え（原因は未確定。次に起きたとき、ログで分かる） |
| `check_force_dir` | `check_force_dir` | カレントディレクトリ名が `force-` で始まるか（0 / 1） |
| `resolve_init_identity` | `resolve_init_identity` | sf-init 用: オーナーと XXXX を、引数（`SF_INIT_OWNER` / `SF_INIT_PROJECT`）→ 対話で決め、`GITHUB_OWNER` / `COMPANY_NAME` をセット。決めた値は `SF_INIT_OWNER` / `SF_INIT_PROJECT` に export する |
| `resolve_job_identity` | `resolve_job_identity OWNER XXXX` | sf-job 用: 引数 → カレントの下のクローンの git remote（`discover_clones`）→ 対話。値が不正なら `die` |
| `prompt_project_identity` | `prompt_project_identity init\|job` | 上の 2 つが使う対話（オーナーの候補が 0 件なら入力・1 件ならそれ・複数なら番号で選ぶ。XXXX は入力 → 確認。init は、すでにあるリポジトリ名を断る（`admin/` に同じリポジトリのクローン・状態ファイルがあれば受け付ける）） |
| `parse_github_remote` | `parse_github_remote URL` | GitHub の URL（HTTPS / SSH / `ssh://`）から `owner repo` を取り出す（GitHub でない・2 階層でなければ戻り値 1） |
| `normalize_project_name` | `normalize_project_name X` | 入力から XXXX を取り出す（前後の空白と先頭の `force-` を除く。使える文字: 英数字・`-`・`_`・`.`。区切りは英数字の間に 1 つだけ・50 文字まで・末尾の `.git` は不可。不正なら戻り値 1） |
| `discover_clones` | `discover_clones DIR` | `DIR/*/force-*/` のクローンの `git remote` から `owner repo` を出す（GitHub の `force-*` だけ） |
| `gh_owner_candidates` | `gh_owner_candidates admin\|member` | `gh` のログインから、オーナー候補を出す（組織 → 自分のアカウント） |
| `gh_existing_projects` | `gh_existing_projects OWNER` | そのオーナーの `force-*` リポジトリの XXXX を出す（`gh repo list` の最大 200 件） |
| `check_gh_owner` | `check_gh_owner OWNER` | gh 認証ユーザーがリポジトリオーナーと一致するか確認（大文字と小文字は区別しない。不一致は die。オーナーが組織で、ユーザーがその有効な admin なら通過。gh が空を返す場合はスキップ。3.4.3） |
| `get_branch_list` | `branches=$(get_branch_list)` | `sf-tools/config/branches.txt`（`BRANCH_LIST_FILE`）のブランチを 1 行ずつ出す（`#` の行・空行は飛ばす。ファイルがない・空なら WARNING を出して `main` だけ） |
| `is_protected_branch` | `is_protected_branch BRANCH` | `get_branch_list` の一覧に、行全体で一致するか（固定の文字列。大文字と小文字は区別する） |
| `is_reserved_org_alias` | `is_reserved_org_alias ALIAS` | 共有環境の予約名（`SF_RESERVED_ORG_ALIASES` = `prod staging develop main`）か。ローカルからのリリースの禁止に使う（名前を変えた本番組織は、`org_local_release_check` で止める） |
| `required_status_check_names` | `required_status_check_names` | Ruleset の必須チェックの名前（ワークフローのジョブ名: 対象ファイル確認・デプロイ検証・順序チェック）を 1 行ずつ出す。ワークフロー名は含めない。Phase 9 と `lib/diag.sh` が使う |
| `merge_package_xml` | `merge_package_xml OUT IN...` | package.xml を 1 つに統合する（種類 → メンバーを重複なく、バイト順に並べる。入力がない・読めない・書けないときは OUT を消して戻り値 1）。理由は 4.2 |
| （管理者用のクローン） | `clone_matches_repo DIR O R` / `state_matches_repo FILE O R` / `mark_setup_complete DIR` / `clear_setup_mark DIR` / `clone_setup_completed DIR O R` / `ensure_admin_branch DIR` / `push_admin_branch DIR` / `git_origin_redacted [DIR]` | origin（または状態ファイル）が O/R か（大文字と小文字は区別しない）・セットアップ完了の印（`git config sf-tools.setup-complete` の 1 / 0 / 未設定）・`admin` ブランチへの切り替えと push（強制 push はしない）・origin の URL を認証情報を伏せて出す。`sf-init.sh` と `phases/init/` が使う |
| （`lib/org.sh`） | `org_choose_login_url VAR LABEL TIER [SUFFIX]` / `org_validate_url URL` / `org_tier_of_suffix SUFFIX` / `org_read_info ALIAS` / `org_parse_info JSON` / `org_kind` / `org_kind_label KIND` / `org_guard TIER LABEL` / `org_local_release_check ALIAS` / `org_jwt_test ALIAS KEY KEYFILE USER URL` / `org_save SUFFIX` | Salesforce 組織の接続情報の共通部品（`doc/wizard-ux-design.md` 4.7）。`common.sh` のあとに個別に `source` する（`phases/init/init-common.sh`・`verify.sh`・`sf-start.sh`・`sf-update-secret.sh`・`sf-typecheck.sh`・`sf-release.sh`・`sf-deploy.sh`）。ログイン先は URL の 3 択（Enter = Sandbox。環境変数 `SF_INIT_LOGIN_URL_<PROD\|STG\|DEV\|START>` で、質問なしで指定できる。URL は https で salesforce.com / force.com のサブドメインだけ: `org_validate_url`）。ログイン後に `Organization`（`Id`・`Name`・`IsSandbox`・`OrganizationType`・`TrialExpirationDate`）を読み取り（`ORG_*` 変数）、種類（production / sandbox / developer / trial / unknown）を判定する（ID・IsSandbox が読み取れない・OrganizationType が空のときは unknown。推測しない）。`org_local_release_check`: ローカルからのリリースの保護（戻り値 0 = 本番でない / 1 = 本番 / 2 = 確認できない。`sf-release.sh`・`sf-deploy.sh` は 1・2 で中断）。`org_guard`: **Salesforce の本番組織は main のみ**（staging・develop に本番は、戻り値 2。**判定不能（unknown）も、main 以外は戻り値 2**。確認では通さない。main は、unknown でも続行）。`org_jwt_test`: 従来の接続アプリ用。JWT 接続テストと組織情報の読み取りを、同じ一時的なホームの中で行う（Secrets を登録する前にガードできるように）。`org_save`: 組織の ID・名前・種類・確認日時を GitHub Variables（`SF_ORG_*_<接尾辞>`）に保存 |
| （`lib/wizard.sh`） | `wizard_banner` / `wizard_rule` / `wizard_step N TOTAL TITLE [PURPOSE [完了...]]` / `wizard_checklist` / `wizard_do` / `wizard_next` / `wizard_hint` / `wizard_auto` / `wizard_confirm [PROMPT]` / `wizard_fail CAUSE [FIX] [RESUME]` / `wizard_done` | ウィザード形式の画面の部品（`doc/wizard-ux-design.md`。`sf-init.sh`・`phases/init/verify.sh` が個別に `source`）。表示は標準エラー。`wizard_confirm`: Enter / Y で進み、N / q / EOF は `die`、それ以外は再入力（`ask_yn \|\| die` と同等に扱う: CLAUDE.md 2.4）。`wizard_fail`: 原因・直し方・再開の方法（`die` の前に呼ぶ。`die` のメッセージは事実のみ） |
| （`lib/diag.sh`） | `diag_run REPO 段階...`（結果の不足の数は `DIAG_NG`） | セットアップの診断（`sf-init.sh --status`・`--verify` が使う）。リポジトリ・ブランチ・ワークフロー・Secrets・Variables・ブランチ保護（Ruleset の必須チェックの名前が `required_status_check_names` と合うか）・直近の実行を、GitHub から読み取って、✓ / ✗（直し方つき）/ ！ / ？ で表示する。読み取りのみ。一覧を取得できないものは「？」とし、不足に数えない |
| （`lib/verify-common.sh`） | `verify_gh` / `verify_pr_create` / `verify_pr_merge` / `verify_pr_close` / `verify_latest_run_id` / `verify_wait_pr_run`（基準の ID より新しい実行だけを対象にする）/ `verify_run_conclusion` / `verify_step_conclusion` / `verify_rerun_and_wait` / `verify_dispatch_workflow` / `verify_wait_run` / `verify_run_log_has` / `verify_branch_sha` / `verify_branch_create` / `verify_branch_delete` / `verify_branch_has_open_pr` / `verify_file_sha` / `verify_file_put` / `verify_file_delete` / `verify_hello_*` / `verify_set_*` | 実際のリポジトリの検証（`phases/init/verify.sh`）・`sf-init.sh`（最初のメタデータの同期）・e2e（`tests/e2e/lib.sh`）が共有する部品。GitHub の API（ブランチ・ファイルの追加・削除）と PR・ワークフローの実行の待ち、Hello World の本文。`gh` は `run` を通さず `verify_gh`（時間の上限つき・標準入力は `/dev/null`）で呼び、失敗は戻り値・空の出力で返す（`die` しない）。リポジトリは引数で受け取り、操作してよいリポジトリの安全ガードは、呼び出し側が行う（e2e: `_e2e_check_repo`）。環境変数 `VERIFY_*`（多くは `E2E_*` も使える）。`VERIFY_SET=components` で、サンプルを `lib/verify-samples.sh` に切り替える |
| （`lib/verify-samples.sh`） | `verify_sample_paths [stage1\|stage2\|all]` / `verify_sample_content_for PATH` / `verify_sample_deploy_target_text` / `verify_sample_remove_target_text [stage1\|stage2]` / `verify_sample_labels_file_is_ours` | `sf-init.sh --verify --components` のサンプル（書き方のパターンごとに最小のもの。名前は `SfToolsE2eHello` 系）。`verify-common.sh` が `source` する。`VERIFY_SAMPLE_LABELS` / `_OBJECTS` / `_FLOW` で含めるものが変わる |
| （`lib/typecheck.js`） | `node lib/typecheck.js --list` / `--org ALIAS --work DIR [--mode full\|validate] [--only ...] [--out FILE]` | メタデータの種類ごとの「リリース・削除」の可否を、実際の組織で確かめる（`bin/sf-typecheck.sh` から呼ぶ）。実行する sf は `project deploy start` / `validate` だけ・書くファイルと削除するメンバーは `SfToolsE2eMin`（LWC は `sfToolsE2eMin`）を含むものだけ・予約名の組織は中断。終了コード 0 / 3（ng がある）/ 1（中断） |
| `ensure_sf_tools_latest` | `ensure_sf_tools_latest [--no-update] [DIR]`（DIR の省略時は `$SF_TOOLS_DIR`） | sf-tools（DIR）が origin の最新か確認し、遅れていれば確認のうえ `git pull --ff-only` で更新する。戻り値: 0=最新（または判定できない: Git リポジトリでない・HEAD がブランチでない・origin に同じブランチがない。WARNING を出す）／2=更新した（呼び出し側は、更新した sf-tools で、再実行すること）。die: origin に接続できない・fetch 失敗・遅れていて未コミットの変更または未プッシュのコミットがある・更新を断った・pull 失敗・`--no-update` で遅れている |
| `is_gitbash` | `if is_gitbash; then ...` | Windows の Git Bash か判定（`$OSTYPE` が `msys*` / `mingw*` / `cygwin*`） |
| `check_sf_cli` | `check_sf_cli [--warn-only] [--cache]` | `sf --version` の終了コードが 0 か確認する（sf は npm 版が前提）。0 以外なら、sf の場所と対処を ERROR で表示して `die`（`--warn-only` は表示のみで戻り値 1）。`--cache`（日常のコマンド用）は、成功を `~/.sf-tools-sf-check`（`SF_TOOLS_SF_CHECK_STAMP` で変更可）に sf の場所つきで記録し、24 時間は確認を省略する（失敗は記録せず、毎回確認する）。sf 未インストール・GitHub Actions 上（`GITHUB_ACTIONS=true`）では何もしない |
| `run_isolated_home` | `out=$(run_isolated_home CMD [ARGS])` | 一時的なホームフォルダ（`HOME` と `USERPROFILE` を `mktemp -d` のフォルダに）の中でコマンドを実行し、出力と終了コードを返す。終了後に一時フォルダを削除する。sf の認証・エイリアスを隔離するために使う（JWT 接続テスト） **Windows（Git Bash）以外では、`SF_USE_GENERIC_UNIX_KEYCHAIN=true` も設定する**（mac は、sf の暗号鍵を OS のキーチェーン（サービス `sfdx`・アカウント `local`）に保存する。一時ホームには `Library/Keychains` がなく、「キーチェーンが見つかりません」のダイアログが出るため。設定すると、鍵は一時ホームの `.sfdx/key.json` に保存され、一時フォルダごと消える。本物のキーチェーンには触れない） |
| `open_browser` | `open_browser URL` | OS 判定してブラウザを開く（GitBash/WSL/macOS/Linux 対応。GitBash の判定を先に行う）。開けなくてもエラーにしない（戻り値は常に 0） |
| `read_input` | `read_input VAR [PROMPT]` | readline 対応テキスト入力（矢印キー・BS 有効）。戻り値は `read` のもの（EOF で 0 以外。呼び出し側が `\|\| die` などで扱う） |
| `read_key` | `read_key VAR [PROMPT] [VALID]` | 1文字即時入力（Enter 不要・空 Enter と `VALID`（正規表現）に合わない文字は無視・EOF は `die`。`VALID` の省略時は空 Enter 以外のすべて。q の判定は呼び出し側） |
| `press_enter` | `press_enter [MSG]` | Enter 待ち（q / Q・EOF で中断） |
| `read_or_quit` | `read_or_quit VAR PROMPT` | テキスト入力（空 Enter は再入力・q / Q・EOF で中断） |
| `read_secret` | `read_secret VAR PROMPT` | 秘密情報の入力（1 文字ごとに `*` を表示・BackSpace 対応・制御文字は無視・Enter のあと「N 文字を受け取りました（先頭: ghp_…）」を表示・空 Enter は再入力（端末のときは貼り付け方を案内）・q で中断・末尾の CR を除去・改行なしの EOF は確定）。Token の入力に使う（値は画面・ログに出さない） |
| `_mask_secrets` | `_mask_secrets TEXT` | GitHub（`ghp_` / `gho_` / `ghu_` / `ghs_` / `ghr_` / `github_pat_`）と Slack（`xoxa-` / `xoxb-` / `xoxp-` / `xoxr-` / `xoxs-`）の Token らしい文字列を伏せ字にする。`run` のコマンドの行（画面とログの CMD の行・error.log の見出し）に自動適用される。コマンドの出力には適用しない（保険。Token はそもそも引数に含めず、環境変数・標準入力・`GIT_ASKPASS` で渡すこと） |
| `ask_yn` | `ask_yn "質問"` | Y/N/q 確認（1文字即時入力。Y = 0 / N = 1 / q は `die`。それ以外の文字・空 Enter は無視） |

### 3.2 `log` のレベル

`HEADER` / `INFO` / `SUCCESS` / `WARNING` / `ERROR` / `FATAL` / `CMD`

- `FATAL` は `die` が使う（直接呼ばない: CLAUDE.md 2.2）。`CMD` は `run` がコマンドの行を記録するのに使う
- 上記以外のレベルは、画面にはメッセージだけを出す（ログファイルには `[LEVEL]` を付ける）

### 3.3 `run` の戻り値

| 定数 | 値 | 意味 |
|---|---|---|
| `RET_OK` | 0 | 成功 |
| `RET_NG` | 1 | 失敗（`LOG_FILE` と同じフォルダの `error.log` にも、見出しの行とコマンドの出力を追記） |
| `RET_NO_CHANGE` | 2 | `NothingToDeploy` など変更なし |

**成功判定のルール:** `run()` は、**終了コードのみ**で成否を判定する（出力の文字列では判定しない）。ただし、出力に `NothingToDeploy` / `No local changes to deploy` が含まれる場合は `RET_NO_CHANGE`（終了コードより優先）。以前（〜2026-03-23）は、出力の成功キーワード（`Success` / `Succeeded` / `Deployed` / `status": 0` など）でも `RET_OK` にしていたが、失敗を成功と誤判定する恐れがあるため、2026-03-24 に削除した。

**Salesforce CLI の前提:** Windows の Git Bash で、Salesforce CLI の公式インストーラー版（自動更新後）を使うと、`sf` が成功しても終了コード 1 を返す（`sf --version` や `sf alias unset` も 1。同じバージョンの npm 版は正しく返す）。このため sf-tools は **npm 版を前提**とし、`sf-init.sh` / `sf-start.sh` / `sf-release.sh`（`sf-deploy` / `sf-dryrun` / pre-push の検証を含む）/ `sf-metasync.sh` / `sf-update-secret.sh` / `sf-typecheck.sh` の起動時に、`check_sf_cli`（`sf --version` の終了コードが 0 か）で確認し、NG なら案内を表示して**中断する**（日常のコマンドは `--cache`: 成功は 24 時間省略）。`sf` の成否は、すべて終了コードで判定する（`run` と同じ。出力の文言や、終了コードの無視による判定はしない）。`sf-install.sh` だけは `check_sf_cli --warn-only`（警告のみ）で、中断しない。中断すると、sf-tools 自身の最新化（`git pull`）まで止まるため。

**JWT 接続テストの隔離:** `sf` の認証はユーザー名単位なので、JWT 接続テスト（`sf org login jwt`）をそのまま実行すると、エイリアス（`prod` / `staging` / `develop`）が増え、同じユーザーの既存の認証が JWT の認証に置き換わる（その鍵・アプリを後で消すと、そのユーザーの `sf` が使えなくなる）。そのため、JWT 接続テスト（`init-common.sh` の `register_jwt_secret` / `register_jwt_secret_eca`、`sf-update-secret.sh`。`register_jwt_secret` と `sf-update-secret.sh` は `org_jwt_test`（`lib/org.sh`）経由）は `run_isolated_home`（一時的なホームフォルダ）の中で実行する。ほかの場所では、この JWT 用のエイリアスは使われない（`sf-start.sh` は、ユーザーが指定したエイリアスで `sf org login web` をする）。JWT 接続テストの成否は、`run_isolated_home` の戻り値（`sf org login jwt` の終了コード）で判定する。

**`run` と `log` の速度の設計（2026-10-28）:** `run` は、ほぼすべてのコマンドの実行で使うため、1 回の呼び出しで外部のプログラムを起動すると、Windows の Git Bash（プロセスの起動が遅い）で、全体が極端に遅くなる。実測（Windows の Git Bash）: 変更前は `log` 68ms・`run true` 595ms（WSL は 3ms・20ms）。変更後は `log` 3ms・`run true` 198ms。起動を減らした箇所は、①時刻（`date` → 組み込みの `printf '%(...)T'`。Bash 4.2 以上。Bash 3.2 は `date`。`_now_ts`）、②`NothingToDeploy` の検知（`grep` → 組み込みの `read` と文字列の比較。NUL を含む出力だけ `grep`）、③Token の伏せ字（`_mask_secrets_var`。Token らしい文字列を含むときだけ `sed`）、④ログへの記録（色・絵文字を含まない出力は、`sed` を使わず、`_prefix_lines`。ESC・`0xe2`・`0xef`・`0xf0` のバイトを含むときは、従来どおり `_strip_term_codes` と `sed`。`_has_term_codes`）。残る起動は、`mktemp`（一時ファイルを 0600 で作るため）・`tee`（画面に流しながら記録するため）・`rm`。旧版と新版の出力（画面・戻り値・ログ・`error.log`）を、色・絵文字・日本語・CRLF・末尾の改行なし・Token・失敗・NUL などの 19 ケースで比べて、1 点を除いて一致した。差は、**最後の行に改行がない出力**: 旧版（GNU の sed）は、改行を付けず、次のログが同じ行に続いていた（BSD の sed は付ける）。新版は、どちらも付ける。回帰テストは `tests/test_common.sh` の `test_run_fast_paths`。

### 3.4 安全ガードパターン

管理者向けコマンドには2種類の安全ガードを組み合わせて使う。

#### 3.4.1 警告ボックス + `ask_yn || die`（管理者向けコマンドの冒頭）

意図しない実行を防ぐための視覚的警告と確認プロンプト。`sf-metasync.sh`・`sf-update-secret.sh` は、`GITHUB_ACTIONS=true` の場合はスキップして自動続行する。次は、`GITHUB_ACTIONS=true` でも省略しない（Actions 上で実行する想定がない）: `sf-init.sh`（開始画面は `wizard_confirm`。`--resume N` / `--only` のときは `ask_yn`）・`sf-sync-wf.sh`・`phases/init/add_tier.sh`・`reconnect.sh`。`sf-typecheck.sh` と `phases/init/verify.sh`（`sf-init.sh --verify`）は、Actions 上では実行を拒否する。

```bash
# 管理者向けコマンドの冒頭パターン（sf-metasync / sf-update-secret）
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    print_admin_warning --standard "GitHub Secrets を更新します。" "誤った値を設定すると CI/CD が停止します。"
    ask_yn "続行しますか？" || die "中断しました。"
fi
```

> **警告ボックスは、`print_admin_warning`（`lib/common.sh`）を使う。`echo` でボックスを直書きしない**（書き写しによる、幅のずれ・書き漏れを防ぐため）。
> - `--standard`: 先頭に「このコマンドは管理者専用です / 管理者以外は絶対に実行しないでください」を付ける（続く行があれば、空行を 1 つ挟む）
> - 行は 1 引数 = 1 行（空文字は空行）。左に空白 2 つの余白が付く。見出しは `"!!  …"`、続きの行は空白 4 つで、そろえる
> - 幅は、表示の幅（全角 2・半角 1）で、54 にそろう（`_display_width`）。確認（`ask_yn` / `wizard_confirm`）は、含まない
> - 赤色（`CLR_ERR`）で、標準エラーに出る。枠の内側の幅（54）を超える行は、切り詰めず、右の枠がずれる
> - `sf-typecheck.sh` は、起動したら最初に（`--list`・`--coverage` でも）、この警告を出し、続けて確認（Y/N。`-y` で省略）をして、はじめて実行する。**警告は、必ず、確認とセットにする（表示だけで流れると、意味がないため）**

#### 3.4.2 二重確認の防止パターン

ラッパースクリプト（`sf-deploy.sh`）から被呼び出しスクリプト（`sf-release.sh`）を呼ぶ場合、確認が二重に表示されるのを防ぐ。

```bash
# ラッパー側（sf-deploy.sh）: 確認（ask_yn || die）のあとで
export SF_DEPLOY_CONFIRMED=1
exec bash "$RELEASE_SH" --release --force "$@"

# 被呼び出し側（sf-release.sh の 5.2。--release のときだけ）
if [[ "${GITHUB_ACTIONS:-false}" != "true" && "$IS_VALIDATE_MODE" -eq 0 && "${SF_DEPLOY_CONFIRMED:-0}" != "1" ]]; then
    ask_yn "リリースを実行します（実際に、組織へ反映されます）。続行しますか？" || die "中断しました。"
fi
```

> `sf-release.sh` / `sf-deploy.sh` の確認は、警告ボックスを出さない（開発者向けのため: CLAUDE.md 2.4）。共有環境の保護（予約名・`org_local_release_check`）は、`SF_DEPLOY_CONFIRMED` に関係なく、両方で行う（`GITHUB_ACTIONS=true` のときだけ省く）。

**スキップ条件まとめ:**

| 条件 | 意味 |
|---|---|
| `GITHUB_ACTIONS=true` | GitHub Actions WF 実行中 → 全スキップ |
| `SF_DEPLOY_CONFIRMED=1` | ラッパー経由の呼び出し → 被呼び出し側スキップ |

#### 3.4.3 `check_gh_owner`（gh 認証ユーザー確認）

GitHub に書き込む管理者向けスクリプトは、リポジトリオーナーが確定したあと、書き込みの前に `check_gh_owner` を呼び出す。認証ユーザーがオーナーと一致しない場合は `die` で即終了する（`die` のメッセージは事実のみで、復旧案内は含めない）。比較は、大文字と小文字を区別しない（GitHub の名前は区別しないため。`tr` で小文字にして比べる）。ただし、オーナーが組織で、認証ユーザーがその組織の有効な管理者（`role=admin` かつ `state=active`）である場合は通過する（INFO を表示）。

```bash
resolve_init_identity        # GITHUB_OWNER / COMPANY_NAME をセット（--owner / --project → 対話）
# …（sf-init.sh は、開始画面の警告と確認のあと）
check_gh_owner "$GITHUB_OWNER"   # 認証ユーザーの一致確認
```

- 呼び出している場所: `sf-init.sh`・`sf-update-secret.sh`・`phases/init/add_tier.sh`・`reconnect.sh`・`verify.sh`（後の 3 つは、`sf-init.sh` の `--add-tier` / `--reconnect` / `--verify` から別のプロセスで動くため、それぞれ呼ぶ）
- 組織の管理者判定は `gh api user/memberships/orgs/<オーナー>` の `role` と `state` で行う。API が失敗した場合は通過させず `die` する（安全側）
- gh が空を返す場合（ネットワーク障害・未認証）はチェックをスキップして続行する
- `sf-init.sh` の各 Phase（`phases/init/01_check_env.sh`〜`10_sf_auth.sh`）は、メインスクリプトで確認済みのため個別呼び出し不要
- `sf-job.sh` は呼ばない（開発者が毎日使うコマンドで、管理者向けではないため）

---

## 4. スクリプト別処理概要

### 4.1 sf-start.sh

> 仕様の正本は、`bin/sf-start.sh` の冒頭コメント（`--help`）。ここは要点だけ。

- `check_sf_cli --cache` で sf を確認する（終了コードが 0 以外なら中断。成功は 24 時間、確認を省略）
- `.sf/config.json` があれば `sf org display --json` で接続を確認し、エイリアスが取れ、組織 ID が `00D` で始まれば、ログインを省略する。`FORCE_RELOGIN=1` を付けると再ログインを強制できる
- 未接続のとき: エイリアスを入力（空 Enter は再入力。`q` / EOF で中断）→ `sf alias unset vscodeOrg` → ログイン先の URL を選ぶ（`[1]` login / `[2]` test（Enter）/ `[3]` 組織の URL。`SF_INIT_LOGIN_URL_START` があれば質問しない。**エイリアスの名前では決めない**）→ `sf org logout` → `sf org login web`（WSL で wslview がなければ、`/tmp/sf-wsl-bin` にシムを一時生成してブラウザ起動）。ログインに失敗したら中断する（設定ファイルの書き込み・VS Code・ランチャーの起動は行わない）
- `.sf/config.json` / `.sfdx/sfdx-config.json` を上書き（書き込めなければ中断）し、`code` があれば `code .` で VS Code を起動（なければ警告のみ）
- バックグラウンドで `sf-install.sh` を実行（フック・リリースDir準備・npm install・ツール更新はすべて sf-install.sh が担当。完了は待たない）
- 続けて、前面で `sf-launcher.sh` を起動（`SF_LAUNCHER_ACTIVE=1` なら起動しない。二重起動の防止）
- Ctrl+C は無効（`trap '' INT`。子の bash にも継承される）。終了コードは、ランチャー・バックグラウンドの sf-install.sh の結果によらず 0（中断・失敗は 1）
- 前提: force-* フォルダで実行（`SF_INIT_MODE=1`（sf-job.sh 経由）なら確認を省略）。接続済みの組織を切り替えるときは `sf-restart.sh`

### 4.2 sf-release.sh

> 仕様の正本は、`bin/sf-release.sh` の冒頭コメント（`--help`）。ここは要点と設計の経緯。

- ターゲットファイルをもとに `package.xml`（と、削除用の `destructiveChanges.xml`）を生成
- `sf project deploy start` で検証（既定。`--dry-run`）またはリリース（`--release`）。`destructiveChanges.xml` は `--pre-destructive-changes` で渡す（削除が先）
- 処理の順: `check_sf_cli --cache` → 接続先の決定（`-t` > `SF_TARGET_ORG` > `sf org display` の alias）→ 共有環境の保護（5.1）→ リリースの確認（5.2）→ `branch_name.txt` の読み込み → 対象リストの確認と `sf-check.sh` → マニフェスト生成と `@isTest` の検出（`phase_generate_manifest`）→ `sf org open`（`-n` がなければ。5 秒待つ）→ `sf project deploy start`
- 両方のリストに対象が 1 件もなければ、「デプロイ対象なし。正常終了します。」で終了コード 0（CI でリリースの定義だけを先に準備する運用を許すため）。`deploy-target.txt` が空で `remove-target.txt` にだけ対象があれば、メンバーのない `package.xml`（version 60.0）で削除だけ行う
- 終了コード: 成功（対象なしを含む）は 0、中断・失敗は 1

**マニフェストの生成（`generate_manifest`）:** `[files]`（`--source-dir`）と `[members]`（`--metadata`）は、**別々に** `sf project generate manifest` で生成し、`merge_package_xml`（`lib/project.sh`）で 1 つに統合する。
理由: `sf project generate manifest` は、`--source-dir` と `--metadata` を同時に渡すと、両方の**共通部分だけ**を返す（重なりがなければ `<types>` のない空のマニフェストになり、しかも成功として終わる）。
空のマニフェストでは、`sf project deploy start` が `NothingToDeploy` を返し、sf-release.sh は「変更がないため処理をスキップしました」と成功扱いにしていたため、
`[files]` と `[members]` を混在させたリストは、検証もリリースもされないまま、緑になっていた（`sf-init.sh --verify --components` で発見）。
`deploy-target.txt` に対象があるのに、統合後に `<members>` が 1 つもなければ、エラーで中断する（`NothingToDeploy` の成功扱いにしない）。
**`remove-target.txt` の指示行 `# @ignore-missing`**（コメント行の形）: あるときだけ、`sf project deploy start --ignore-warnings` を付け、組織に存在しない削除対象を、エラーにしない。後始末（`sf-init.sh --verify --cleanup`）用。通常のリリース・削除には、付けない。
`merge_package_xml` は、awk と sort だけ（GNU / BSD 共通）。種類は名前の順・メンバーは重複なし・version は最初のもの。
テスト: `tests/test_sf-release.sh`（混在・`[members]` のみ・`[files]` のみ・空のマニフェスト）、`tests/test_common.sh` の `test_merge_package_xml`。`tests/test_helper.sh` の sf のモックは、実際の sf と同じく、両方を同時に渡すと空になる。

主なオプション: `--release`（`-r`）/ `--validate`・`--dry-run`（既定と同じ）/ `--no-open`（`-n`）/ `--force`（`-f`。`--ignore-conflicts` を付ける）/ `--target`（`-t`）/ `--json`（`-j`）/ `--verbose`（`-v`）

**共有環境の保護（5.1）:** 接続先のエイリアスが予約名（`prod` / `staging` / `develop` / `main`。`is_reserved_org_alias`）なら、ローカル（`GITHUB_ACTIONS` が `true` 以外）からは `die` する（dry-run を含む）。共有環境へのリリースは、GitHub Actions だけ。
**組織の種類の確認:** 予約名以外の名前を付けた本番組織は、名前では止められない。そのため、ローカルでは、予約名でなくても、組織の種類を調べる（`org_local_release_check`、`lib/org.sh`。`sf data query` で Organization を読み取り、`org_kind` で判定する）。本番（`production`）なら `die`、種類を確認できない（読み取れない・判定不能）ときも `die` する（本番でないと推測しない）。Sandbox / Developer Edition / Trial は通る。GitHub Actions 上では調べない。`sf-deploy.sh` も、同じ関数で、確認（Y/N）の前に判定する。

**安全ガード（セクション 3.4）:**
ローカル実行 + `--release` + `SF_DEPLOY_CONFIRMED!=1` の条件をすべて満たす場合のみ、確認（`ask_yn ... || die`。赤い警告ボックスは、なし）を実行する。`-f` も指定されていれば、確認の前に上書きの警告（`log "WARNING"`）を出す。`GITHUB_ACTIONS=true` / validate モード / `SF_DEPLOY_CONFIRMED=1`（sf-deploy.sh 経由）の場合はスキップ。

`@isTest` 自動検出フロー:
1. `phase_generate_manifest` 内で `deploy_args` を走査し、`--source-dir` に続く `.cls` ファイルを `grep -qi "@isTest"` で検査
2. 検出されたクラス名をスクリプトレベル変数 `RUN_TESTS=()` に追加
3. `phase_release` で `${#RUN_TESTS[@]} -gt 0` の場合、`--test-level RunSpecifiedTests` と、クラスごとの `--tests <クラス名>`（繰り返し。`--run-tests` は存在しないフラグ）を `deploy_cmd` に追加して実行
4. テストクラスが 0 件の場合は従来通り（`--test-level` 未指定）の動作を維持

### 4.3 sf-metasync.sh

> 仕様の正本は、`bin/sf-metasync.sh` の冒頭コメント（`--help`）。ここは要点だけ。

- `prod` エイリアスの組織（**本番・Sandbox のどちらでもよい**）から、メタデータを取得し、`main` にコミットして `push` する（**PR は作らない**）。push したときは、`branches.txt` の `main` 以外の各ブランチへ、`main` をマージして push する（伝播）
- どのブランチから実行しても、`main` に切り替えて処理し、終了時に元のブランチへ戻る（追跡中のファイルに未コミットの変更があれば、`git stash` で退避して、戻すときに `stash pop`）
- `sf sgd source delta` で差分を求め、`metadata.txt` の全種類を `retrieve` する
- 事前の確認（何も変更せずに中断）: `sf org display --target-org prod --json` が成功すること（出力はアクセストークンを含むため、表示もログへの記録もしない）・detached HEAD でないこと・`metadata.txt` があること
- 差分がなくても、未プッシュのコミット（前回の push の失敗で残った）があれば、コミットの一覧（`git log --oneline`）を表示し、確認のうえ（`GITHUB_ACTIONS=true` では確認なし）、push だけ行う（`git rev-list --count origin/main..HEAD`）。差分も未プッシュのコミットもなければ、伝播は行わずに終了する
- `main` への push と、伝播の push は、どちらも `git push --no-verify`（このコマンド専用。pre-push フック（sf-prepush.sh）は、保護ブランチの上からの push・保護ブランチへの push を必ず拒否するため、手元で実行すると、伝播の push がすべて失敗する。サーバー側の保護（Ruleset）は、そのまま効く。結合テスト M0・M4 で見つかった）
- 伝播は、リモートにないブランチ・失敗したブランチを WARNING でスキップする（終了コードは 0 のまま。完了のメッセージは、実際に伝播できたブランチだけ）
- 手元で実行したとき、追跡していないファイル（`.gitignore` の対象と `sf-tools/release/` を除く）があれば、手順 5 で中断する（無関係なファイルが、同期のコミットに入るのを防ぐ）

**安全ガード（セクション 3.4）:**
- sf の確認と事前の確認のあと（`main` への切り替えより前）に、赤い警告ボックス（`print_admin_warning`）+ `ask_yn || die`（`GITHUB_ACTIONS=true` 時はスキップ）
- `phase_git_sync` のコミット直前: `GITHUB_ACTIONS=true` でなければ `git status --short` を表示し `ask_yn || die` で確認（push だけのときは、`git log --oneline` を表示して同様に確認）

### 4.4 sf-install.sh

> 仕様の正本は、`bin/sf-install.sh` の冒頭コメント（`--help`）。ここは要点だけ。

処理順（順序変更禁止）:
1. `check_sf_cli --warn-only`（`sf --version` の終了コードを確認し、0 以外なら警告のみ。中断しない。`sf-tools` 自身の最新化を止めないため）
2. `~/sf-tools` を、現在のブランチ（取得できなければ `main`）で `git pull origin <ブランチ>`（失敗は WARNING で続行）。`sf-init.sh` から実行中（`SF_INIT_RUNNING` あり）はスキップする（実行中の `sf-init.sh` が書き換わると、bash の読み位置がずれるため）
3. `./sf-tools/config/metadata.txt`・`branches.txt` の確認: `sf-init.sh` から実行中は、ないものだけテンプレートからコピー（失敗は中断）。それ以外は、どちらかがなければ中断する（プロジェクトの破損として扱い、生成しない）
4. `sf-hook.sh` で Git Hook（pre-commit / pre-push）をインストール（失敗は WARNING で続行）
5. `release/<branch>/` と `branch_name.txt` を準備（detached HEAD では何もしない。`main` では `release/` と `.gitkeep` だけ作り、`release/<branch>/`・`branch_name.txt` は作成・更新しない）
6. `sf-init.sh` から実行中のみ、`templates/gitmessage` を `.gitmessage` にコピーし、`git config commit.template .gitmessage`（失敗は WARNING で続行）
7. `package.json` がある場合は `npm install`（失敗は WARNING で続行）。`sf-init.sh` から実行中は、初期セットアップ用の一時フォルダなのでスキップする（約 90 秒の短縮）。`node_modules/.package-lock.json` の更新時刻が `package-lock.json` 以上のときもスキップ（`_get_mtime`）
8. `~/.sf-tools-last-update` がない、または 24 時間以上経過していれば `sf-upgrade.sh` をバックグラウンド起動（引数なし。標準出力は捨て、標準エラーは `sf-install.log` に追記）。スタンプは、起動を確認できた時点で更新する（完了の時点ではない）

終了コードは 0（手順 3 の中断・不明なオプションは 1）。GitHub Actions のワークフロー（`.github/workflows/`）は扱わない（新規は sf-init.sh、既存への反映は sf-sync-wf.sh）。

### 4.5 sf-next.sh

> 仕様の正本は、`bin/sf-next.sh` の冒頭コメント（`--help`）。ここは要点と設計の背景。

現在の feature ブランチが各ターゲットブランチにどの状態かを判定し、次に PR を出すべきブランチを案内する。確認（Y/N/q）のうえ、PR の作成画面（`<origin の https URL>/compare/<次の PR 先>...<現在のブランチ>?expand=1`）をブラウザで開く（PR そのものは作らない）。

- detached HEAD・保護ブランチ（`is_protected_branch`）の上では、エラーで終了する
- マージの順は、`branches.txt` の逆順（例: `develop → staging → main`）
- `git fetch origin <全ブランチ>` は 1 回のコマンド（失敗しても警告で続行し、手元の `origin/*` で判定）。`gh pr list` は、マージ済み・オープンを、それぞれ最新 50 件だけ取得する（失敗しても警告なしで、PR なしとして扱う）
- 終了コード: 0（N を含む）/ 1（エラー・q）

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
2. `git merge-base --is-ancestor HEAD origin/<対象>` で間接伝播（上位ブランチ経由）を確認 → `synced`
3. `gh pr list --state open` で PR 発行中を確認 → `pr_open`
4. いずれも該当なし → `none`（NEXT_TARGET に設定）

ステータスと表示:
- `merged` → `✓ マージ済み`
- `synced` → `✓ マージ済み（ブランチ同期）`（デプロイ WF 未実行）
- `out_of_order` → `⚠ マージ済み（順序外）`（前に synced/pr_open/none があった merged）
- `pr_open` → `→ PR発行中`
- `none` かつ NEXT_TARGET → `▶ 次のPR先`
- `none` → `✗`

次の PR 先がないときは、`pr_open` が残っていれば「マージ完了を待ってください」、なければ「全ブランチへのマージが完了しています！」と表示して終了する。

順序外マージの制約:
`develop → staging → main` の順番を守らずにマージした場合、スキップしたブランチへのデプロイは**永久にできない**。
- 上位ブランチ（例: main）にマージすると、コードが下位ブランチ（例: staging）に伝播する
- 伝播後は「差分なし」となり、feature → staging の直接 PR が作成できなくなる
- GitHub Actions のデプロイ WF は直接 PR のマージイベントで起動するため、伝播では WF が動かない
- スキップしたブランチにデプロイしたい場合は、新しいブランチを切って改めて順序通りに PR を出し直す

### 4.6 sf-dryrun.sh

- `sf-release.sh` のラッパー（自身ではオプションを付け足さない。sf-release.sh の既定が検証モード（`--dry-run`）のため、検証になる）
- ランチャーから呼ばれる dry-run 専用コマンド
- 受け取った引数は、検査せず、すべて `exec bash sf-release.sh "$@"` でそのまま渡す（不明なオプションは sf-release.sh が中断する。終了コードは sf-release.sh のもの。sf-release.sh がなければ 1）
- 第 1 引数の `-h` / `--help` だけが sf-dryrun.sh のヘルプ。2 番目以降は sf-release.sh へ渡る
- `--release` を転送した場合は sf-release.sh の安全ガード（セクション 3.4）が働く

### 4.7 sf-launcher.sh

> 仕様の正本は、`bin/sf-launcher.sh` の冒頭コメント（`--help`）。ここは要点だけ。

- `sf-launcher.sh` で起動するメニュー形式ランチャー（`sf-start.sh` の最後に自動で起動する。`sf-job.sh` からは `sf-start.sh` 経由。別名（`sfl` など）は作らない。直接 `sf-launcher.sh` を打つ。2026-10-23 の決定）
- メニュー: 1 Check / 2 Push / 3 Next / 4 Dryrun / 5 Deploy / 6 Start / 7 Restart（同じフォルダの `sf-xxx.sh` を、引数なしで bash で実行）。番号は 1 文字（Enter 不要）、`q` で終了。範囲外・数字と `q` 以外は無視。実行したコマンドが失敗しても、ランチャーは終了しない
- `lib/common.sh` を source しない standalone 設計（ログファイルを作らない・カラー定義を独自に持つ）
- force-* フォルダの外では、警告を表示して終了する（終了コード 1。`-h` / `--help` だけは外でも動く）
- VSCode 内では `sf-start` / `sf-restart`（6・7）をメニューから除外（`$TERM_PROGRAM == "vscode"` で判定。番号 6・7 は範囲外になる）
- `SF_LAUNCHER_ACTIVE=1` をエクスポートして `sf-start.sh` からの二重起動を防止
- `sf-launcher.sh <番号>` で、その番号を 1 回だけ実行して終了（終了コードは、実行したコマンドのもの。範囲外・スクリプトがなければ 1）
- `sf-launcher.sh --fzf` で fzf モードも利用可能（fzf がなければ、警告を表示して終了コード 1）

### 4.8 sf-deploy.sh

> 仕様の正本は、`bin/sf-deploy.sh` の冒頭コメント（`--help`）。ここは要点と設計の経緯。

- `sf-release.sh --release --force` のラッパー（受け取った引数は、その後ろに付けて渡す。`exec bash sf-release.sh --release --force "$@"`。終了コードは sf-release.sh のもの、中断は 1）
- `force-*` 以外では実行禁止
- 処理の順: sf-release.sh の存在確認 → ブランチの確認 → 引数の確認 → 接続先の決定 → 予約名の判定 → 確認（Y/N/q）→ `SF_DEPLOY_CONFIRMED=1` で `exec`。**中断の判定は、すべて確認より前**
- 現在のブランチが取得できない（detached HEAD など）とき、または `branches.txt` に書かれたブランチ（ファイルがない・空なら `main` だけ）の上では、中断する（作業用のブランチの上で実行する）
- 不明なオプション・引数（2 番目以降の `-h` / `--help` を含む）は、確認の前に「不明なオプションです」で中断する（`-f` / `--force` / `-r` / `--release` は、常に付くため、受け付けるだけ）
- **安全ガード:** `log "WARNING"` で `--force` の意味を表示 → `ask_yn || die` で続行確認（**GitHub Actions 上でも、確認は省かない**。**赤い警告ボックスなし**。赤いボックスは、管理者向けの sf-init / sf-metasync / sf-update-secret / sf-sync-wf / sf-typecheck のみ（print_admin_warning））
- `export SF_DEPLOY_CONFIRMED=1` で sf-release.sh 側の二重確認を抑制
- **共有環境には、ローカルからリリースできない。** 用途は、個人用の Sandbox / Developer Edition / Scratch Org への強制リリース。共有環境（本番・staging・develop）は、GitHub にコミットし、レビューを通して、GitHub Actions で行う。そのため、接続先のエイリアスが予約名（`SF_RESERVED_ORG_ALIASES` = `prod` / `staging` / `develop` / `main`。`is_reserved_org_alias`、`lib/common.sh`）なら、**確認の前に** `die` する（`-t` / `--target` の指定、なければ `SF_TARGET_ORG`、接続中の組織の順で特定。`GITHUB_ACTIONS=true` ではスキップ）。`sf-release.sh` の 5.1 も、同じ関数で判定する
- `-t` / `--target` の解析規則は、`sf-deploy.sh`（事前判定）と `sf-release.sh` で同じ: 値（エイリアス）が無い、または `-` で始まる値（次のオプションを取り込む指定）は `die`。`--target=ALIAS` 形式は、どちらも未対応（`sf-deploy.sh` は確認の前に `die`、`sf-release.sh` は「不明なオプション」）。`GITHUB_ACTIONS=true` による解除は、ローカルで設定すれば誰でも解除できるが、これは誤操作を防ぐための設計（悪意ある回避は対象外。共有環境への実際の認証情報は、GitHub Secrets にあり、手元にはない）
- 名前と、組織の種類の両方で判断する。`sf-init` が付ける名前は `prod` / `staging` / `develop`（予約名）。`sf-start.sh` のログイン先は、エイリアスの名前ではなく、URL の選択（Enter = `https://test.salesforce.com`。`[1]` で `https://login.salesforce.com`）で決まるため、予約名以外のエイリアスで本番組織に接続することもできる。名前だけでは止められないため、予約名でなくても、組織の種類を調べて（`org_local_release_check`）、本番、または種類を確認できない組織は、`die` する（2026-10-25 に追加。それ以前は、名前だけで判断していたため、名前を付け替えた本番組織は止められなかった。2026-10-05 には、予約名に `prod` が含まれていなかった不具合を修正）
- 確認の `N` / `q` は、`ask_yn ... || die` で中断する（2026-10-05 に修正。以前は `|| die` が無く、`N` でも実行されていた）

### 4.9 sf-upgrade.sh

- npm（`npm install -g npm@latest`）→ Salesforce CLI → Git（最後）の順に更新。コマンドがなければ WARNING でスキップ
- Salesforce CLI は、npm 版（npm があり、`npm ls -g @salesforce/cli --depth=0` が成功）なら `npm install -g @salesforce/cli@latest`、それ以外（公式インストーラー・pkg など）なら `sf update` で更新する
- `sf-install.sh` から 24 時間間隔でバックグラウンド起動される（引数なし。標準出力は捨て、標準エラーは `sf-install.log` に追記）。手動でも実行できる
- Git の更新は GitBash（`is_gitbash`: `$OSTYPE` が `msys*` / `mingw*` / `cygwin*`）のみ `git update-git-for-windows --yes` で実行（他環境はパッケージマネージャーを案内）
- どの手順が失敗しても WARNING で続行し、最後に「すべてのアップデートが完了しました」を表示する

### 4.10 sf-push.sh

> 仕様の正本は、`bin/sf-push.sh` の冒頭コメント（`--help`）。順序は変更禁止。

カレントフォルダ配下だけをコミット＆プッシュする。実行フロー:

1. **ブランチの確認（最初）**: `git`・`code` のコマンドと Git リポジトリの中であることを確認したうえで、ブランチの上にいない（detached HEAD。`git symbolic-ref -q HEAD` が失敗）・保護ブランチ（`is_protected_branch`。`branches.txt` のブランチ。ファイルがない・空なら `main`）の上にいるときは、何も変更せず `die`（コミットだけが手元に残り、プッシュが通らない状態を作らない。結合テスト R5 で見つけた）
2. `git fetch origin main` → `git merge origin/main --no-edit` で、現在のブランチに取り込む（`main` ブランチ自身では行わない。fetch の失敗はエラーで終了。マージの失敗（コンフリクトなど）は、git merge の出力を表示し、`merge --abort` して中止）
3. カレント配下だけを `git add --all`
4. カレント配下にステージ済みの変更がないとき: 未プッシュのコミット（`@{u}..HEAD`。手順 2 で取り込んだものを含む。upstream がなければ 0 件）があれば、コミットせず `git push` だけ行って終了する（コミット後にプッシュが失敗した再実行用）。なければ、何もせず終了
5. `sf-check.sh` でターゲットファイルを検証（エラーなら中止。出力は run を通さず、`-v` がなくても画面に出る）
6. VS Code（`code --new-window --wait`）を開いて、コミットメッセージを入力
7. 行末の CR・`#` で始まる行・先頭と末尾の空行を除き、残りが空なら、コミット・プッシュせず終了（手順 2・3 の結果は、元に戻さない）
8. `git commit -F` → `git push`（`git commit` はパスを指定しないため、カレント配下の外で前からステージ済みの変更も、一緒にコミットされる。インストール済みの pre-commit / pre-push フックも動く）

終了コード: 0（何もせず終了を含む）/ 1（エラー）。

### 4.11 sf-update-secret.sh

> 仕様の正本は、`bin/sf-update-secret.sh` の冒頭コメント（`--help`）。ここは要点と設計の背景。

GitHub Secrets / Variables の JWT 認証情報を再登録する。実行フロー（順序は変更禁止）:

1. `sf`・`gh`・`git`・`openssl` のどれかがなければ中断（`force-*` 以外での実行は、`lib/common.sh` が source の時点で終了させる）
2. 赤い警告ボックス（`print_admin_warning`）+ `ask_yn || die`（管理者向け確認。`GITHUB_ACTIONS=true` では表示・確認しない）
3. git remote（origin）から対象リポジトリ（OWNER/REPO）を自動取得（`parse_github_remote`。取得できなければ中断。URL に認証情報が入ることがあるため、メッセージに URL を出さない）
4. `check_gh_owner` で gh 認証ユーザーを確認（不一致は die。オーナーが組織で、ユーザーがその有効な admin なら通過）
5. `check_sf_cli --cache`（終了コードが 0 以外なら中断）
6. メインメニューで操作を選択 `[1-4/q]`（1文字即時選択）:
   - 1: 秘密鍵（`SF_PRIVATE_KEY` Secret）を更新（パスは常に入力。確認（Y/N）のあと登録。接続テストは行わない）
   - 2: コンシューマーキー（`SF_CONSUMER_KEY_*` Secret）を組織ごとに更新（接続ユーザー名（`SF_USERNAME_*` があれば、それを使うかを確認）・ログイン先を決め、接続テストに成功してから登録。ユーザー名・インスタンス URL は登録しない）
   - 3: ユーザー名（`SF_USERNAME_*` Variable）を組織ごとに更新（現在値を `gh variable get` で自動取得して表示。コンシューマーキーは接続テスト用で、登録しない）
   - 4: すべて更新（確認（Y/N）で Y なら `SF_PRIVATE_KEY` を先に登録し、続けて組織ごとに、`SF_CONSUMER_KEY_*`・`SF_USERNAME_*`・`SF_INSTANCE_URL_*` を、接続テストに成功してから登録）
7. 「JWT Secrets の更新が完了しました。」を表示して終了（手順 6 の確認で N と答えて登録しなかったときも表示する）

- 組織選択は `branches.txt` の有効行数（コメント行・空行を除く。ファイルがなければ 1）に応じて動的に変化:
   - 1行: PROD のみ `[1/q]`
   - 2行: PROD + STG `[1-2/q]`
   - 3行以上: PROD + STG + DEV `[1-3/q]`
- 秘密鍵ファイル: メニュー 2〜4 は `~/.sf-jwt/<リポジトリ名>/server.key` があれば、それを使う（なければパスを入力）。先頭の `~` はホームに展開。ファイルがなければ中断
- ログイン先: login / test（Enter）/ 組織の URL の 3 択（`SF_INIT_LOGIN_URL_<組織>` があれば質問しない）。メニュー 2・3 では、接続テストにだけ使い、登録しない
- **本番組織のガード:** 接続テストのあと、STG・DEV に、本番組織または種類を判定できない組織をつなごうとしたら、登録する前に中断する（PROD で判定できないときは WARNING で続行）
- 登録（`gh secret set` / `gh variable set`）の失敗・入力中の `q` は中断

**Secret と Variable の使い分け:**

| 種別 | キー名 | 登録先 | 理由 |
|---|---|---|---|
| 秘密鍵 | `SF_PRIVATE_KEY` | Secret | 漏洩リスクあり |
| コンシューマキー | `SF_CONSUMER_KEY_PROD` 等 | Secret | 漏洩リスクあり |
| ユーザー名 | `SF_USERNAME_PROD` 等 | Variable | 参照用・読み取り可 |
| インスタンス URL | `SF_INSTANCE_URL_PROD` 等 | Variable | 参照用・読み取り可 |
| 組織の情報 | `SF_ORG_ID_PROD`・`SF_ORG_NAME_*`・`SF_ORG_KIND_*`・`SF_ORG_CHECKED_*` 等 | Variable | `--status` の表示用。接続テストで組織の ID を読み取れたときに保存（`org_save`。`SF_CONSUMER_KEY` などの登録より前。失敗しても WARNING で続行） |
| Slack チャンネル | `SLACK_CHANNEL_ID` | Variable | 参照用・読み取り可（sf-update-secret.sh では更新しない。sf-init.sh の Phase 07 が登録） |

> Secret は暗号化されており `gh secret get` で値を読み取れないが、Variable は `gh variable get` で取得できる。ユーザー名は、メニュー 3 で組織を選んだあとに、現在値を自動取得して表示する。

> `SF_TOOLS_TOKEN` は不要（2026-10-05 に廃止）。`sf-tools` は公開リポジトリのため、wf-metasync / wf-validate / wf-release は、Token なしで `https://github.com/tama-create/sf-tools.git` を clone する（`sf-init.sh` の Phase 11 は無い。以前のバージョンで作ったプロジェクトのワークフローは、Token 付きで clone しているため、その Token を無効にしないこと）。`SF_TOOLS_BRANCH`（Variable）は、Phase 2 で「開発版（development）」を選んだ場合のみ `phases/init/09_repo_rules.sh` が `development` を登録する（検証環境用。環境変数では指定できない）。未設定なら Actions は `main` を clone する。

**SF_PRIVATE_KEY の base64 エンコーディング:**
GitHub Actions のワークフローは Secret から取得した値を `base64 -d` でデコードして使用する。そのため `SF_PRIVATE_KEY` は **base64 エンコード済みの文字列** として登録しなければならない。`sf-update-secret.sh` の `_update_private_key`・`_update_all` は以下のパイプで登録する（秘密鍵の内容をログに記録しないため、`run` を通さない）:

```bash
tr -d '\r' < "$key_file" | base64_oneline | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME"
```

> `tr -d '\r'` は Windows 改行コード（CRLF）を除去するため。`base64_oneline`（`lib/platform.sh`）は base64 の折り返しなし（1行）。`base64 -w 0` は macOS にないため使わない。

**JWT 接続テスト（内部処理）:**
`sf org login jwt` と組織の情報（Organization）の読み取りを、一時的なホームフォルダの中で実行する（`org_jwt_test`・`run_isolated_home`。ユーザーの sf にエイリアスが増えず、同じユーザーの既存の認証も置き換わらない）。成否は、終了コードで判定する（`sf` は npm 版が前提）。失敗したら中断する（それより前に登録した値は、そのまま残る）。実行コマンドと出力はログに記録する（コンシューマー鍵は伏せ字）。組織の情報を読み取れなかったときは中断せず、種類を判定できない組織として、本番組織のガード（`org_guard`）で扱う。

**ワークフローを書くときの規約（スクリプトの注入の防止。2026-10-06）:** PR のタイトル・ブランチ名（`github.event.pull_request.title` / `head.ref` / `base.ref`、`github.ref_name`）や、そこから作った Step の出力など、**利用者が決められる値は、`run:` のシェルや、`github-script` の JavaScript に、`${{ }}` で直接埋め込まない**。`env:` で環境変数に渡し、スクリプトでは `$変数` / `process.env.変数` で参照する（ブランチ名・PR のタイトルには、`"`・バッククォート・`$( )` などが入れられるため。直接埋め込むと、通知のステップが壊れる、または、任意のコマンドが実行される）。Slack に送る JSON には、値を `json_escape`（`"` と `\` のエスケープ・制御文字の除去・`& < >` の置き換え）に通して入れる。JWT の秘密鍵の一時ファイルは、`umask 077` で作り、`trap 'rm -f /tmp/server.key' EXIT` で、失敗しても消す。`tests/test_sf-init.sh` の `test_wf_no_script_injection` が、直接の埋め込みが無いことを確認する。**既存の `force-*` には、自動では届かない**（配布用の `sf-sync-wf.sh`（4.15）で、管理者が、各リポジトリに、手動で反映する）

### 4.12 sf-hook.sh / sf-unhook.sh

> 仕様の正本は、`bin/sf-hook.sh`・`bin/sf-unhook.sh` の冒頭コメント（`--help`）。ここは要点だけ。

- `sf-hook.sh`: `~/sf-tools/hooks/` の `pre-commit` / `pre-push` を、`.git/hooks/` へコピーして（既存のファイルは確認・バックアップなしに上書き）`chmod +x` する。コピー元は `$HOME/sf-tools/hooks/` に固定（スクリプトの場所ではない）。`.git` がない・コピー元がないときは中断
  - `git config --local core.hooksPath` に `husky` が含まれていれば、確認なしに `--unset` で削除する。husky 以外の `core.hooksPath`（ローカル・グローバル）が残っているときは、フックが動かないため、WARNING を出し、「自動的に検証が実行されます」の案内は出さない（コピーは行う）
  - コピーするのは、`~/sf-tools/bin/sf-precommit.sh` / `sf-prepush.sh`（`--verbose`）を呼ぶだけのラッパー。bin/ 側の更新は全プロジェクトに即時反映され、ラッパー自体の変更は、各プロジェクトで sf-hook.sh を再実行するまで反映されない
- `sf-unhook.sh`: `.git/hooks/pre-push` を削除する（pre-commit は残す。プッシュの検証だけを止めるのが狙い。意図した仕様として確認済み）
  - pre-push がなければ「すでに無効化されています」で終了。目印（`SF_HOOK_MARKER`: `# Generated by sf-tools: wrapper for pre-push hook`）を含まないファイルは、sf-tools が管理するフックではないとして、WARNING を出し、削除しない（終了コードはどちらも 0）
  - sf-hook.sh が削除した `core.hooksPath`（husky の設定）は、元に戻さない

#### 4.12.1 sf-job.sh・sf-prepush.sh の、結合テストで見つかった変更

- **`sf-job.sh`（X2-2）**: ジョブ名に、環境ブランチ・管理者用のブランチの名前（`main` / `staging` / `develop` / `admin`。完全一致）は使えない。GitHub 上に同名のブランチがすでにあるときは、最後のコミットの作者・日時（`gh api ... --jq`）を表示して、`ask_yn` で確認する。Y なら `USE_EXISTING_BRANCH=1`（`phase_create_branch` は、作成の API を呼ばずに、戻る。ブランチ作成のあとに、clone が失敗した前回のジョブの、続き）。N なら、別のジョブ名を聞く（q は中断）。
- **`sf-prepush.sh`（X3-2）**: `phase_fetch` は、`branches.txt` のブランチが、origin に（`git ls-remote --exit-code origin <名前>`）まだないとき、取得せず、警告を出して続ける（以前は、`git fetch` が「見つからない」で失敗し、すべての push が止まった）。
- **`lib/project.sh`（A14）**: `resolve_job_identity` は、`--project` だけの指定で、同じ XXXX のクローンが、複数のオーナーにある（大文字と小文字だけの違いは、同じ）とき、最初のものを黙って使わず、`_pick_from_list` で、選ばせる（`--owner` を指定すれば、選ばせない）。
- **`sf-next.sh`（A5）**: 開く PR 作成画面の URL は、origin の URL が `ssh://git@github.com/...`・`git@github.com:...`・https のどれでも、https の URL にする（http(s) の URL に含まれる認証情報（`//<ユーザー>:<Token>@`）と末尾の `.git` は除く。origin の URL を取得できなければエラーで終了）。
- **`sf-start.sh`（X5-3）**: エイリアスの入力（`read_input`）が EOF（標準入力が閉じた）のときは、「入力が中断されました」で中断する（以前は、空の入力を、無限に繰り返した）。
- **`lib/diag.sh`（X3-9）**: `SF_TOOLS_BRANCH` は、検証環境（開発版）だけが登録する任意の Variable。診断の確認項目に含めない（なくても、不足にしない）。

### 4.13 sf-init.sh

> 仕様の正本は、`bin/sf-init.sh` と `phases/init/*.sh` の冒頭コメント（`--help`）。ここは要点と設計の経緯。

新規 Salesforce プロジェクトの初期セットアップ。`phases/init/` 配下のフェーズスクリプトを順次実行する。保守用のモード（`--add-tier` / `--verify` / `--status` / `--reconnect`）は、force-* の中で実行し、この順で最初に該当した 1 つだけを実行して終了する（ほかのモードの指定は無視。ロックは取らない）。Ctrl+C は、`--help` の判定のあとから無効（`trap '' INT`）。ログは `~/sf-tools/logs/sf-init.log`（起動のたびに空にする）。

**オーナーと XXXX の決め方（フォルダ構成に依存しない）**: リポジトリ名は `force-XXXX`（`force-` は固定、XXXX は管理者が決める）。作業フォルダは、どこでもよい。`resolve_init_identity`（`lib/project.sh`）が、①引数 `--owner` / `--project`（環境変数 `SF_INIT_OWNER` / `SF_INIT_PROJECT`）→ ②対話（オーナーは `gh` から候補、XXXX は入力。`force-` は自動で付く旨を案内し、既存プロジェクトを参考に表示）の順で決める。決めた値は `SF_INIT_OWNER` / `SF_INIT_PROJECT` に export し、Phase 2 と、sf-tools 更新後の再実行に引き継ぐ（Phase 2 は、この 2 つが必須）。管理者用の作業フォルダは `admin`（固定）。同じ `admin` に複数プロジェクトを置くため、状態ファイルは `.sf-init-XXXX.env` / `.sf-init-XXXX.progress`（XXXX = プロジェクト名）とプロジェクトごとに分ける。Phase 1 は `admin` だけを許可する。`sf-job.sh` は、①引数 → ②`{cwd}/*/force-*` のクローンの `git remote` → ③対話で決め（`resolve_job_identity`）、`admin` / `force-*` の中では実行できない。重複判定は、`{ジョブ}/force-XXXX` の有無（同じジョブ名でも、別のプロジェクトなら重複にしない）。

引数の解析のあと（保守用のモードを含む、`--help` 以外のすべての実行で）、`check_sf_cli` で、`sf --version` の終了コードを確認し、0 以外なら案内（npm 版への入れ替え）を表示して中断する（sf が未インストールのとき・GitHub Actions 上では、確認しない。3.3 参照）。`--only` / `--resume` の値は、Phase 番号（1〜10 の整数。先頭の 0 は不可）だけを受け付け、それ以外は、実行の前に中断する（`_require_phase_number`）。

**ウィザード形式の画面（`lib/wizard.sh`・設計: `doc/wizard-ux-design.md`）:**
- 利用者に見せるのは、Phase の番号ではなく、**全 9 ステップ**（`WIZ_STEP_TITLES`。ステップ 9 は「動作の確認」で、Phase ではなく、`phases/init/verify.sh` を呼ぶ最後のステップ）。Phase とステップの対応は `WIZ_PHASE_STEP`（1→1, 2→2, 3・4→3, 5→4, 6→5, 7→6, 8・9→7, 10→8）。フェーズループが、新しいステップに入るときに `wizard_step`（現在地・完了済み・目的の 1 文）を出す。各 Phase スクリプトの見出しからは、「Phase N」を外した。
- 開始画面（`FULL_START`: `--resume N`（2 以上）/ `--only` の指定がないとき。続き・完了済みの選択画面より前に出る）: `wizard_banner` → 作るもの・所要時間の目安（30〜60 分）→ 管理者向けの警告ボックス（`print_admin_warning`）→（sf-tools の最新化）→ `wizard_checklist`（先に用意するもの）→ 全ステップの一覧 → `wizard_confirm`（Enter / Y で進む。N / q / EOF は die。CLAUDE.md 2.4 の `ask_yn || die` と同じく、「N / q で必ず中断」）。`--resume N`（2 以上）/ `--only` の指定があるときは、警告ボックスのあと `ask_yn "続行しますか？" || die`。どちらも、確認のあとに `check_gh_owner`。`resolve_init_identity` は、開始画面の前に実行する（作るリポジトリ名を表示するため）。
- sf-tools の最新化（P14）: 開始画面の、**管理者向けの警告のあと・確認の前**に、**現在のブランチを対象に** `ensure_sf_tools_branch` を呼ぶ（本番 / 検証の選択には依存しない。Git リポジトリで、HEAD がブランチのときだけ。そうでなければ、ここでは確認せず、Phase 2 が、選んだ版で確認する）。fetch できない・origin にブランチがないときは、警告して続行。未コミットの変更か未 push のコミットがあれば、更新せずに続行。遅れていれば、確認（Y/N/q）のうえ `git pull --ff-only` し（N は更新せずに続行。q・更新の失敗は die）、戻り値 2 を返す。`sf-init.sh` は、`SF_INIT_RESTARTED=1` を付けて、同じ引数で `exec` する（まだ admin/ に移動しておらず、ロックも取っていない。実行しなおしたあとも、開始画面・管理者向けの警告・確認は、毎回出す。確認を飛ばさない）。確認済みのブランチは `SF_INIT_TOOLS_CHECKED_BRANCH` で Phase 2 に渡し、Phase 2 は、最新化を二重に確認せず、選んだ版とのブランチ違いだけを確認する（N / q は die）。Phase 2 が `ensure_sf_tools_branch` の戻り値 2 を受けたとき（起動時に確認しなかった場合）は、状態ファイルを書かずに終了コード 75 で終了し、`sf-init.sh` が、作業フォルダに戻り、ロックを解放してから、実行しなおす（`exec` では EXIT トラップが動かないため）。**実行しなおしは 1 回だけ**（`SF_INIT_RESTARTED` が立っているのに、再び 75 なら、「sf-tools を更新しても、最新になりませんでした。」で die。無限に繰り返さない）。
- 完了画面: `wizard_done`（できたこと・次にやること: `sf-job.sh` と、リポジトリの URL）。**常に表示する**（`--resume N` / `--only N` のときも。admin ブランチ・同期を行わなかったときは、その理由（途中までの実行 / `--only` の実行 / 状態ファイルに `REPO_DIR` などがない）を出す）。`admin` フォルダは、**削除せず、管理者用として残す**（削除の質問は廃止）。完了画面に、管理者用フォルダ（`REPO_DIR`）のパスと用途（メンテナンス用・日常の開発には使わない）を表示する。
- 後処理の順（a〜e は `END_PHASE` が 10 のときだけ。`--only 10`・`--resume N` を含む。条件は項目ごと）: a. `.sf-init-XXXX.env` から `*TOKEN_VALUE=` の行を念のため消す（通常は Phase 8 の push 後に消えている）→ b. 最初のメタデータの同期 → c. 動作の確認（ステップ 9）→ d. `admin` ブランチ → e. 完了の印を `1` にし、**状態ファイル（`.sf-init-XXXX.env` / `.sf-init-XXXX.progress`）を削除する**（`--only` のないとき。完了後は、読む場所がないため。印を付けられなければ、状態ファイルは残す。完了画面に使う値は、削除の前に読み込み済み）→ f. 完了画面。途中で止まったときは、続きをやるために残る。
- **管理者用のクローンの `admin` ブランチ**: 動作の確認（verify.sh）のあと、完了画面の前に（`REPO_DIR` があるとき）、`ensure_admin_branch REPO_DIR`（`lib/project.sh`）で、クローンを `admin` ブランチにし（`main` から作る。すでにあれば、作り直さず切り替える）、続けて `push_admin_branch REPO_DIR` で GitHub にも作る（`git push --no-verify -u origin admin`。`--no-verify` は、`add_tier.sh` と同じく、管理者による自動の操作のため、pre-push の検証を省く。強制 push はしない: GitHub 側の `admin` と食い違うときは失敗にする）。理由: 管理者の変更は「`main` を取り込む → 変更 → push → PR」で GitHub に反映するため、最初から両方に同じ `admin` を置く。`END_PHASE` が 10 のときだけ。どちらに失敗しても、セットアップは成功のままで、警告と、完了画面の案内（`git switch -c admin` / `git push -u origin admin`）で知らせる。理由: `main` は保護ブランチで、管理者用のクローンが `main` のままだと、その上で作業してしまう（`sf-sync-wf.sh` も、保護ブランチでは実行を断る）。`phases/init/add_tier.sh` は、実行前のブランチを覚え、終わったら、そこへ戻る（以前は `main` で終わっていた）。`sf-metasync.sh` は、元から、終了時に実行前のブランチへ戻る（trap）。`admin` ブランチは、`main` から古くなる（`main` へのマージを取り込まない）。`admin` で、ワークフローの雛形などを見る前には、`main` を取り込むこと（完了画面にも、`git pull origin main` を案内する）。
- 失敗時: `wizard_fail` で、「どこから再開されるか」を、利用者向けの名前（`WIZ_PHASE_TITLES`）で出す（再開の単位は、Phase の先頭。Phase 3 以降は「続きをやる」で再開、Phase 1・2 は最初から。`--only` のときは出さない）。`die` は、事実のみ（従来の規約）。
- テスト: `tests/test_wizard.sh`（部品）、`tests/test_sf-init3.sh` の `test_happy_path_3branches`（開始画面・見出し・完了画面）、`tests/test_sf-init2.sh` の `test_sf_tools_autoupdate`（本物の git で、更新 → 自動で実行しなおし）。

実行フロー（Phase。各 Phase の詳細は、`phases/init/NN_*.sh` の冒頭コメント）:
1. 環境チェック（カレントが `admin` か・`git` / `gh` / `node` / `npm` / `sf` / `code` の有無・`gh auth status`（失敗なら `gh auth login`））。状態ファイルに何も書かない。「続きをやる」では、続きの Phase の前に毎回実行する
2. プロジェクト情報の確認（引数・対話で決めたオーナーと XXXX。`SF_INIT_OWNER` / `SF_INIT_PROJECT` が必須）→ 確認（`ask_yn`）→ sf-tools の版の選択（1 = 配布版 `main` / 2 = 開発版 `development`。GitHub Actions が使う sf-tools のブランチ）→ sf-tools のブランチと最新化の確認（上記。更新したら終了コード 75）→ `.sf-init-XXXX.env` を上書きで作り、7 つのキーを書き出し
3. リポジトリ作成（`gh repo create --private` + `git clone -c core.longpaths=true`。すでにあれば作成・クローンをせずに使う）→ `templates/` の全ファイル（`.github/workflows/` のワークフローを含む）を `cp -r` でコピー（同名は上書き）→ `sfdx-project.json` の `__REPO_NAME__` を置換
4. ファイル生成（`SF_INIT_RUNNING=1` で `sf-install.sh` を実行。`sf-install.sh` が `sf-hook.sh` でフックを設置する。`npm install`・`~/sf-tools` の pull はしない）
5. ブランチ構成（対話選択 → branches.txt を書き直す（コメント行だけを残す）→ `BRANCH_COUNT` を追記。リモートのブランチは Phase 8 が作る）
6. PAT_TOKEN の設定（`phases/init/06_pat_token.sh`。force-* のリポジトリ用の Token であり、sf-tools（公開リポジトリ）とは無関係）。流れ: Token を作るべきアカウント（`REPO_FULL_NAME` のオーナー。組織なら管理者）を表示 → 手順を表示し、`open_browser` で Token の作成ページを開く（Note・Scopes・Expiration は URL のパラメータで入力済み。「発行済みの Token があるか」は聞かない: Token の値は作成直後の 1 回しか表示されないため。保存してある Token を貼ってもよい）→ `read_secret`（画面に表示しない）→ Token を GitHub に問い合わせて検証（`verify_pat_token`。Token は環境変数 `GH_TOKEN` で `gh` に渡し、コマンドの引数に出さない。①`gh api user` でログイン名を取得できるか ②応答に `X-OAuth-Scopes` ヘッダーがあるか〔ない Fine-grained は不可〕 ③スコープに `repo`・`workflow` があるか ④`repos/<REPO_FULL_NAME>` の `permissions.admin` が `true` か〔個人ならオーナー、組織なら組織の管理者〕。NG なら理由を表示し、貼り直し（合計 3 回まで。3 回とも NG なら die））→ `gh secret set PAT_TOKEN`（標準入力で渡す）→ `.sf-init-XXXX.env` に `PAT_TOKEN_VALUE` を追記（Phase 8 の push で使用）
7. Slack 連携の設定（App の作成手順を表示 → SLACK_BOT_TOKEN（`xoxb-` で始まる形式でなければ入力し直し）を Secret に / SLACK_CHANNEL_ID を Variable に登録。チャンネル ID は `^[CG][A-Z0-9]{8,}$` かを検証し、それ以外（D=DM、U=ユーザーなど）は警告して拒否し、入力し直させる。通知先は全員が参加する共有チャンネルのため。Bot の招待（`/invite`）は利用者が行い、確認もしない）
8. 初回コミット＆プッシュ（`git add -A` → 差分があればコミット（pre-commit フックが動く）→ `main` と、branches.txt の main 以外で origin にないブランチを push。PAT は GIT_ASKPASS で渡しコマンドのログに残さない。push 後に .sf-init-XXXX.env から PAT の行を削除する（残ったら die）→ `sf-hook.sh` でフックを入れなおす）
9. GitHub リポジトリ設定・Ruleset の適用（`gh repo edit` の基本設定 → Ruleset `protect-main` / `protect-staging`（ブランチ構成に関係なく両方）を、同名を削除してから作成。必須のステータスチェックは 3 つで、名前は**ワークフローのジョブ名だけ**（`対象ファイル確認`・`デプロイ検証`・`順序チェック`。正本は `required_status_check_names`: `lib/project.sh`。「`validate / 対象ファイル確認`」の形では永久に満たされず、PR がマージできなくなる。2026-10-24 に実際の GitHub で確認）→ 開発版のときだけ Variable `SF_TOOLS_BRANCH=development`。どれが失敗しても WARNING で、終了コードは 0（無料プランの Private リポジトリなど、Ruleset が使えない場合があるため）。既存 Ruleset の一覧を取得できない・数字以外の ID があるときは、削除しない）
10. JWT 認証情報の設定（SF_PRIVATE_KEY / SF_CONSUMER_KEY_* を Secret / SF_USERNAME_* / SF_INSTANCE_URL_*・`SF_ORG_*`（組織の情報を読み取れたときだけ）を Variable に登録）。秘密鍵・証明書（`~/.sf-jwt/<REPO_NAME>/`）が両方あれば、再利用するかを `ask_yn` で聞く（N なら作り直し、この実行では段階のスキップをしない）。アプリ種別（`APP_TYPE`）は利用者に聞かず、保存済みの値、なければ `--legacy-connected-app` の有無で決める。段階は PROD（常に）・STG（`BRANCH_COUNT` が 2 以上）・DEV（3 以上）。ログイン先は URL の 3 択（Enter = `test.salesforce.com`）。本番組織・種類を判定できない組織は main にしかつなげない（`org_guard`）。アプリ種別が外部クライアントアプリ（2）のときは、組織ごとに `register_jwt_secret_eca`（`init-common.sh`）が自動作成する（`sf org login web` → ユーザー名・プロファイル名（表示名）を取得 → `generate_eca_metadata` で 5 ファイルを生成して `sf project deploy` → `sf project retrieve` でコンシューマー鍵を取得 → JWT 接続テスト（反映待ちのためリトライ。`SF_INIT_JWT_RETRIES` / `SF_INIT_JWT_INTERVAL`）→ 登録）。ログイン用の一時エイリアス（`sf-tools-PROD` / `sf-tools-STG` / `sf-tools-DEV`。ユーザーが運用中のエイリアスと重ならないよう `sf-tools-` を付ける）は、ログイン前に `sf alias unset` で外し（前回の古い認証による誤判定の防止）、終了後にも `sf alias unset` で消す（`sf org logout` は同じユーザー名の全エイリアスの認証を消すため使わない）。`sf` は npm 版が前提（Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）。ログイン（`sf org login web`）、接続情報の取得（`sf org display --json`。ユーザー名はその出力から取り出す）、プロファイル名の取得（`sf data query`）、JWT 接続テストの成否は、すべて終了コードで判定し、0 以外なら中断する（JWT 接続テストはリトライ後、スキップの確認）。接続アプリ（1）は従来の手動案内

- **最初のメタデータの同期（`initial_metadata_sync`: `phases/init/init-common.sh`）**: Phase 10 のあと（動作の確認・`admin` ブランチの作成より前）に、`wf-metasync` を実行して、管理者用のクローンに取り込む。初期コミットの `force-app` は空のひな型で、何もしないと、メタデータは次の定期実行（平日 UTC 0・3・6・9 時。`wf-metasync.yml` の cron `0 0-10/3 * * 1-5`）まで入らない。クローン（Phase 3）は初期コミットの push に必要なため、同期（Phase 10 の接続情報が必要）より先になる。そこで、同期のあとに `git pull` する（作り直したクローンと同じ結果）。動作: `verify_dispatch_workflow`（`lib/verify-common.sh`）で main を対象に手動起動 → `SF_INIT_SYNC_TIMEOUT` 秒（既定 1200）まで、30 秒おきに経過を表示して待つ（時間切れなら `gh run cancel` で取り消す: 実行が続いたままだと、あとの `wf-metasync`（動作の確認など）と同時に動き、組織への取得が重なって失敗するため）→ `verify_run_conclusion` が success → クローンを `main` にして `core.longpaths=true` を設定し、`git pull --ff-only origin main`。実行は `END_PHASE` が 10 で、`--only` がなく、状態ファイルに `REPO_DIR`・`REPO_FULL_NAME` があるときだけ。失敗（起動できない・時間切れ・同期の失敗・pull の失敗）しても、`SYNC_RESULT=failed` として警告にとどめ、完了画面に「すぐ同期するには: `gh workflow run wf-metasync.yml -R …`（終わったら `git pull origin main`）」を出す。成功なら `SYNC_RESULT=done`（完了画面: 「同期済みです」）。動作の確認（`verify.sh`）を実行したときは（成功・失敗とも）、`admin` ブランチを作る直前に、クローンが `main` なら、もう一度 `git pull --ff-only origin main`（Hello World のリリースと削除が `main` に入るため。失敗は警告のみ）。Phase 3 の `git clone` には `-c core.longpaths=true` を付ける（Windows のパス長の上限対策。`sf-job.sh` と同じ）。テスト: 成功は `tests/test_sf-init3.sh` の `test_flex_layout_with_args`、起動失敗・同期失敗・時間切れは `tests/test_sf-init2.sh`（`test_initial_sync_failure_is_not_fatal`・`test_initial_sync_timeout_cancels`）。モックの gh（`tests/init-test-lib.sh`）が `workflow run` / `run list`（`--event workflow_dispatch`）/ `run view` に答える。`VERIFY_POLL_SEC=0`。
- **実行場所と、別のリポジトリのクローンの確認（2026-10-17 のレビューで追加）**: `admin` や `force-*` の中、Git の作業ツリー（先頭が `force-` のもの）の中では、実行できない（`resolve_init_identity` の前に die。中に `admin/` ができて、別のクローンに書き込む経路になるため）。`admin` に cd したあと、`admin/force-XXXX` が、`${GITHUB_OWNER}/force-XXXX` のクローンでなければ（`clone_matches_repo`: origin を、大文字と小文字を区別せずに比べる）、状態ファイルに触れる前に die する。プロジェクトは「オーナーと XXXX」で決まるが、フォルダと状態ファイルは XXXX だけで決まるため、同じ XXXX で別のオーナーのプロジェクトを、別のリポジトリのクローンに書き込んで push してしまうのを防ぐ。Phase 3 も、すでにあるクローンについて、同じ確認をし（不一致なら die）、`main` に切り替え、リモートに `main` があれば `git pull --ff-only` する（`admin` ブランチのまま、Phase 8 が `git add -A` / `commit` すると、`main` に入らないため。「最初から、やり直す」の経路）。
- **続きから・完了の直前の記録と、実際の GitHub の食い違い（`_require_origin_main`: `bin/sf-init.sh`。結合テスト X3-6・X3-7 で見つかった）**: 状態ファイルが「Phase 8（初回コミットの push）まで完了」と記録しているのに、origin に `main` ブランチがないときは、「続きをやる」を選んでも、続けずに拒否する（`main` のないまま、「完了」と表示しないため）。完了の直前（進捗 10）で状態ファイルが残っているときも、同じ確認をして、なければ完了にしない（`gh api repos/R/branches/main` で確認。通信の失敗なども、確認できないため拒否）。
- **同時実行の排他（`.sf-init-XXXX.lock`: `bin/sf-init.sh`。結合テスト X4-1 で見つかった）**: 同じ admin フォルダ・同じ XXXX の sf-init を、同時に 2 つ動かすと、状態ファイルの取り合いで、Ruleset が重複することがあった（Windows で確認）。そのため、`.sf-init-XXXX.lock`（フォルダ。`mkdir` は原子的。中に PID を書く）で排他する。2 つ目は「すでに実行中です」で拒否する。PID のプロセスが、もういなければ（強制終了・SIGTERM で残った）、古いロックとして、引き継ぐ。終了時に、EXIT トラップで削除する。ロックを取るのは、警告・確認と、admin への移動・別のリポジトリのクローンの確認のあと（続き・完了済みの選択の前）。保守用のモードは、ロックを取らない。Phase 2 の終了コード 75 で実行しなおすときは、`exec` の前に解放する。
- **完了の印（`mark_setup_complete` / `clear_setup_mark` / `clone_setup_completed`: `lib/project.sh`）**: クローンの `git config sf-tools.setup-complete`（`.git/config` にあり、GitHub には送られない）。値は 3 状態: `1` = 完了 / `0` = やり直し中 / 未設定。セットアップの完了時（`END_PHASE` が 10 で `--only` なし）に、`1` を付けてから、状態ファイルを削除する。「最初から、やり直す」を選んだときは、状態ファイルを消す前に、印を **`0`** にする（消さない）。完了済みの判定（`_project_completed` → `clone_setup_completed`）は、状態ファイルがないとき、「`admin/force-XXXX` の origin が同じリポジトリ」で、かつ、印が `1` なら完了、`0` なら未完了（やり直し中）、**未設定なら、ローカルに `admin` ブランチがあれば完了とみなし、印を `1` にする**（印を導入する前の版（99d420d〜ff690db）で完了したプロジェクトは、完了時に `admin` ブランチを作り、状態ファイルを消すだけで、印を付けなかったため。「印がない = 未完了」と読むと、運用中のリポジトリを新規セットアップとして上書きしてしまう）。`admin` ブランチもなければ、未完了。（「クローンがある」だけで完了とすると、やり直しの途中（Phase 1・2）で止まったとき、未完了を完了と誤判定するため、印を 0 にして、未設定と区別する）。状態ファイルが残っている（進捗 10。以前の版、または完了の直前の中断）ときは、完了済みの案内の前に、後片付け（`_finish_unfinished_setup`: クローンを `admin` ブランチにして GitHub にも push → 完了の印 `1` → 状態ファイルの削除。何度実行しても同じ結果。クローンがない、または、状態ファイルの `REPO_DIR` が指すクローンの origin が、このプロジェクトのものでないときは、何もしない（別のクローンに push しない））を済ませる。印が `0` のまま止まっているとき（やり直しの途中で中断）に、再実行すると、「前回の「最初から、やり直す」が、途中で止まっています。最初から、やり直します」と表示して、最初から始める。状態ファイルのリポジトリ名の比較（続きをやる・完了済み）は、`state_matches_repo`（大文字と小文字を区別しない）。エラーの文言に origin の URL を出すときは、`git_origin_redacted` で、認証情報（`user:TOKEN@`）を伏せる。
- **XXXX の検証（`normalize_project_name`）**: 先頭の `force-`（大文字・小文字を問わない）は除いて扱う。英数字と、区切り（`-` `_` `.`）。区切りは、英数字の間に 1 つだけ（連続・先頭・末尾は不可）、50 文字まで、末尾の `.git` は不可。Phase 10 の外部クライアントアプリの名前（`SF_TOOLS_` + `force-XXXX` の区切りを `_` にしたもの + `_glbloauth`）が、Salesforce の API 名の制約（連続した `_`・末尾の `_` は不可。80 文字まで）を満たすため。守らないと、セットアップの終盤で失敗する。対話での、すでにあるプロジェクト名の比較は、大文字と小文字を区別しない。すでにある名前は、断って再入力させる。ただし、`admin/force-XXXX` がそのリポジトリのクローン（`clone_matches_repo`）か、途中の状態（`admin/.sf-init-XXXX.env` の `REPO_FULL_NAME` が一致: `state_matches_repo`）がある名前は、確認の画面を出さずに受け付ける（続きをやる・完了済みの案内を選ぶため。Phase 3 で、リポジトリを作れたがクローンに失敗した場合など）。`--project` で指定したときは、ここでは既存かどうかを確認しない。
- `sf-job.sh --owner X`（`--project` なし）: そのオーナーのクローンだけを対象にする（大文字と小文字は区別しない）。

**進捗の記録と「続きから」の選択（`bin/sf-init.sh`）:**
- フェーズループで、Phase 2 以降が成功するたびに、**`admin/.sf-init-XXXX.progress`**（入力内容を保存する `.sf-init-XXXX.env` とは別のファイル）を、`SF_INIT_DONE_PHASE=N` と `SF_INIT_DONE_AT="日時"` の 2 行で書き直す（外部コマンドを使わない）。Phase 1 は状態を持たないため記録しない。`--only` のとき・`.sf-init-XXXX.env` がないときは記録しない。失敗した Phase は記録されない。Phase 10 の実行中は、段階ごとの完了（`SF_INIT_DONE_TIER_*`）が、追記される。
- `--resume N`（2 以上）/ `--only` の指定なしで起動し（`--owner` / `--project` などは、あってよい）、`.sf-init-XXXX.env` と `.sf-init-XXXX.progress` があり、`SF_INIT_DONE_PHASE` が 2〜9 で、`REPO_FULL_NAME` が `OWNER/force-XXXX`（大文字と小文字を区別しない: `state_matches_repo`）のとき、管理者警告・確認・`check_gh_owner`・admin フォルダへの移動・ロックのあとに、`read_key` で `[1] 続き / [2] 最初から / [q] 中断` を選ばせる（既定値なし。表示は Phase の番号ではなく、`WIZ_PHASE_TITLES`）。
  - `1`: `START_PHASE=N+1`、`RESUMED=1`。`.sf-init-XXXX.env` は消さない。Phase 1（環境チェック）を、先頭に付け足して、毎回実行する。進捗が 8 以上なのに origin の `main` を確認できないときは、拒否する（`_require_origin_main`。下記）。
  - `2`: 完了の印を `0` にし、`.sf-init-XXXX.env` / `.progress` を削除して Phase 1 から。リポジトリ・admin フォルダは削除しない（Phase 3 が冪等のため）。
  - `q`: `die`（終了コード 1）。
- 続きの対象でなく、完了済み（`_project_completed`。下記）のとき: 続きの選択肢の代わりに「セットアップが、すでに完了しています」を表示し（状態ファイルが 1 つでも残っていれば、先に `_require_origin_main` と後片付け `_finish_unfinished_setup`）、`[1]` 管理者用フォルダ（`REPO_DIR`）で `phases/init/status.sh` を実行して終了（何も変更しない。不足があっても終了コード 0）／`[2]` 管理者用フォルダで `phases/init/verify.sh` を実行し、その終了コードで終了（確認は phases/init/verify.sh の中で聞く）／`[3]` 最初からやり直す（上の `2` と同じ）／`[q]` 終了（終了コード 0）、を選ばせる。`[1]`・`[2]` は、フォルダがなければ die。
- **ステップ 9（動作の確認）**: **通しの実行（`FULL_START`）と、中断後の「続きをやる」のときだけ**、最後（`END_PHASE` が 10）まで実行し、`GITHUB_ACTIONS` でなく、端末（`-t 0`。テストは `SF_INIT_VERIFY_ASK=1`）のとき、後処理の a（Token の値の行の掃除）・b（最初のメタデータの同期）のあと、`admin` ブランチ・完了画面の前に、`read_input` で「Enter = 確認する / s = あとで」を聞く（Enter / Y で確認。s / n / q と EOF は「あとで」。ほかは再入力）。目安の時間は `BRANCH_COUNT × 6 + 3` 分と表示する。`--resume N` / `--only N` の明示では、聞かない。確認するなら、`(cd "${REPO_DIR:-.}" && SF_VERIFY_CONFIRMED=1 bash phases/init/verify.sh)`（`REPO_DIR` が空なら現在のフォルダ。Bash 5.3 は `cd ""` をエラーにするため）。結果（`VERIFY_RESULT`: done / failed / skipped）は、完了画面の 4 番目の項目に表示する。確認の失敗は、sf-init の終了コードに影響しない。進捗（`.sf-init-XXXX.progress`）には、記録しない（Phase ではないため）。
- **完了済みで `--resume N` / `--only N`**: 完了済み（`_project_completed`）のとき、`--resume N`（N > 1）と `--only N` は、`die`（終了コード 1。接続処理などを、確認なしで、やり直さないため。以前は `--only` を拒否しなかった）。案内: `--reconnect` / `--resume`・`--only` なしの実行（[1] 接続を見る・[2] 動作を確認・[3] 最初から）。`--only N` は、開始時に「進捗は、更新しない」を表示する。
- **Phase 10 の段階ごとの再開**（`10_sf_auth.sh` の `_register_org` / `_tier_done`）: 段階（PROD / STG / DEV）が完了するたびに、`.sf-init-XXXX.progress` に `SF_INIT_DONE_TIER_<接尾辞>=1` を追記する（`SF_INIT_TIER_RESUME=1` のとき。`--only` では、設定されず、記録も、スキップも、しない）。再実行では、その記録があり、かつ、`gh secret list` に `SF_CONSUMER_KEY_<接尾辞>` が、いまもあるときだけ、その段階をスキップする（記録だけを信じない。一覧を取得できなければ、スキップしない）。秘密鍵・証明書の再利用で N（作り直し）を選んだ実行では、`SF_INIT_TIER_RESUME=0` にして、完了済みの段階も設定しなおす（`SF_PRIVATE_KEY` が新しい鍵に置き換わり、古い証明書が残る組織が JWT 接続できなくなるため）。Phase 10 が成功したとき、`sf-init.sh` が進捗ファイルを書き直すため、段階の記録は、消える。「最初から」では、進捗ファイルごと消えるため、すべての段階を、実行する。外部クライアントアプリは、名前が決まっている（`SF_TOOLS_<REPO_NAME の英数字以外を _>`）ため、やり直しても、重複しない。
- **完了済みのプロジェクトの判定（`_project_completed`）**: 完了時に状態ファイルを消すため、通常は、**クローンで判定する**。状態ファイルが 2 つともあるときは、進捗が 10 で、リポジトリが一致すること（完了の直前で止まった・完了の印を付けられなかった・以前の版が残した状態。クローンの場所は `REPO_DIR`、なければ `admin/force-XXXX`）。そろっていないときは、`clone_setup_completed`（`admin/force-XXXX` の origin が同じリポジトリで、完了の印が `1`。印の 3 状態は、上の「完了の印」）。進捗が 2〜9 は、完了済みではない（続きをやる、の対象）。完了済みのときの案内（`[1]` 接続を見る / `[2]` 動作を確認 / `[3]` 最初から）と、`--resume N` / `--only N` の拒否は、この判定を使う。
- 質問しない場合: 状態なし（完了済みのクローンもなし）・別のリポジトリの状態（`.sf-init-XXXX.env` を削除して最初から）、`--resume N`（2 以上）/ `--only N` の指定あり。
- Phase が失敗したときは、`die`（事実のみ）の前に、`wizard_fail` で再開の方法を表示する（Phase 3 以降:「もう一度 sf-init.sh を実行し、「続きをやる」を選ぶと、「<Phase の名前>」の最初から、再開します」／ Phase 1・2: 最初から始まる旨。`--only` のときは表示しない）。
- `sf-init.sh` は、フェーズループの前の判定では、状態ファイルを `source` せず、`_kv_value KEY FILE`（grep + sed）で値を取り出す。後処理（同期・動作の確認・admin ブランチ・完了画面）の前に、`.sf-init-XXXX.env` を `source` する。
- テスト: `tests/test_sf-init.sh` の `test_resume_choice`（[1]・[2]・q・質問が出ない条件・`--resume`・`--only`）。happy path（`tests/test_sf-init3.sh`）と Phase 10 失敗（`tests/test_sf-init2.sh` の `test_sf_login_failure`）のテストにも、記録の確認がある。

オプション（正本は `bin/sf-init.sh` の冒頭コメントの【オプション】）:
- `--owner OWNER` / `--project XXXX`: オーナー・XXXX の指定（上記。不正なら終了）
- `--resume N`: Phase N〜10 を、続きの質問・完了済みの選択画面なしで実行（N = 1 は指定なしと同じ。完了済みのプロジェクトでは拒否）
- `--only N`: Phase N のみ実行（デバッグ用。進捗は記録しない。完了済みのプロジェクトでは拒否。Phase 3 以降は `.sf-init-XXXX.env` が必要）
- `--add-tier staging|develop`: 既存プロジェクトへの tier 追加（後述）。初回のセットアップ（GitHub 側 → Salesforce の接続）とは、順序が逆: 先に Salesforce に接続し、成功してから、ブランチ・PR を作る（接続に失敗したときに、GitHub 側を、変更しないため）。値は `-` で始まらないもの（値なしは終了）
- `--reconnect main|staging|develop`: 1 つの段階の接続先（Salesforce 組織）の付け替え（`phases/init/reconnect.sh`。force-* 内で実行。値は `-` で始まるものも受け取り、段階の名前かどうかは reconnect.sh が確認する。`prod` も main として扱う。staging / develop は branches.txt にあること。現在の接続を表示 → 管理者向けの警告・`check_gh_owner`・確認 → 鍵・証明書の確認 → ログイン先の選択 → ログイン → 種類の読み取り → 本番は main のみのガード → 外部クライアントアプリの自動作成 → JWT 接続テスト → Secrets / Variables の更新。古い組織が別の組織なら、以前の接続に使ったアプリ（外部クライアントアプリ・手動の接続アプリケーションの両方）と片付け方を表示する（自動では削除しない）。登録は 1 つずつ行うため、途中で止まると新旧の値が混在する（もう一度 `--reconnect` でそろえる））
- `--status`: セットアップの診断と、段階ごとの接続の一覧（`phases/init/status.sh`。読み取りのみ。警告・確認は出さない。終了コード: 診断で不足がある、または、本番が main 以外にあれば 1）。
- `--verify`: 動作の確認（`phases/init/verify.sh`。`--plan` / `--cleanup` / `--no-metasync` / `--components` / `--validate-only` / `--with-objects` は、そのまま渡す。`--verify` なしの指定は `die`（`--add-tier` と一緒のときは、無視））。詳細は 4.15.1
  - 診断（`lib/diag.sh` の `diag_run REPO 段階...`）: リポジトリ・渡した段階のブランチ・ワークフロー 5 本（`gh api` / `gh repo view`）、Secrets（`gh secret list`）、Variables（`gh variable list`）、ブランチ保護（Ruleset `protect-main` / `protect-staging` の必須チェックの名前が、ジョブ名（`required_status_check_names`）と合っているか。以前の sf-init が「`validate / 対象ファイル確認`」の形で登録したプロジェクトを、ここで見つける）、直近の実行（wf-metasync / wf-release / wf-validate / wf-propagate。`gh run list --workflow`）を、✓ / ✗ / ！ / ？ で表示する。不足（✗）には、直し方（`--only N` / `--reconnect` / `--add-tier` / `sf-sync-wf.sh`）を表示し、件数を `DIAG_NG` に入れる。一覧を取得できなかったものは「？」とし、不足に数えない（通信エラー・権限不足を、不足と誤認しない。Ruleset が無い（無料プランの非公開リポジトリなど）・読めないときも「？」）。組織の種類の記録（`SF_ORG_ID_*`）がないものは「！」（不足に数えない。古いバージョンで作ったプロジェクトのため）。直近の実行は、成功以外の完了が「！」、未実行・実行中・確認できないときは「？」（セットアップの不足ではないため）。 `SF_TOOLS_BRANCH` は、検証環境（開発版）だけが登録する任意の Variable（未設定ならワークフローは main を使う）のため、診断は、なくても、不足にしない（結合テスト X3-9 で見つかった。以前は、配布版のプロジェクトで、必ず「不足」と表示した）。
  - Salesforce 側（外部クライアントアプリ・JWT 接続）は、ログインが必要なため確認しない。直近の wf-metasync / wf-release の成功で、接続できていることが分かる。
  - 接続の一覧: GitHub Variables を読むだけ。同じ組織が複数の段階にあれば警告、本番が main 以外にあればエラー表示。
- `--legacy-connected-app`（環境変数 `SF_INIT_LEGACY_CONNECTED_APP=1`）: 従来の接続アプリケーション（手動の入力）を使う。既定は外部クライアントアプリ。保存済みの `APP_TYPE` が 1 以外（2 など）なら中断する。`APP_TYPE=1` が保存済みなら、指定がなくても 1 のまま使う
- `-h` / `--help`: 冒頭コメントの第 2 ブロックを表示して終了（終了コード 0）。知らないオプションは、使い方を表示して終了（終了コード 1）
- 終了コード: 0 = 成功（完了済みの選択画面の `[1]` / `[q]` を含む）/ 1 = エラー（die）/ `--verify`・`--status`・完了済みの `[2]` は、verify.sh・status.sh の終了コードをそのまま返す

#### 4.13.1 `--add-tier` による tier 追加

既存 `force-*` プロジェクトに staging または develop 階層を追加する。`phases/init/add_tier.sh` を呼び出す。

実行場所: **`force-*` ディレクトリ内**（`sf-init.sh` の通常実行とは異なる点に注意）

```bash
cd {作業フォルダ}/{作業単位}/force-xxx    # 例: admin/force-acme
sf-init.sh --add-tier staging    # main → main+staging
sf-init.sh --add-tier develop    # main+staging → main+staging+develop
```

`add_tier.sh` の処理フロー（正本は `phases/init/add_tier.sh` の冒頭コメント。状態ファイルは読まない）:
1. `ADD_TIER`（sf-init.sh が export）が空・カレントのフォルダ名が `force-` で始まらなければ die
2. origin の URL から `REPO_FULL_NAME`・`REPO_NAME` を求める（`parse_github_remote`。GitHub 以外は die）
3. バリデーション（`git fetch origin main` のあと、**origin/main の** `branches.txt` を `git show` で読んで確認する。作業ツリー（admin など）の branches.txt は origin/main と食い違うことがあり、それで確認すると重複がすり抜けるため）:
   - staging / develop 以外はエラー
   - 対象 tier がすでに `branches.txt` に存在する場合はエラー
   - `develop` を追加しようとしたとき `staging` が未登録の場合はエラー（`main → develop` のスキップは禁止）
4. 管理者向けの警告（`print_admin_warning`）→ `check_gh_owner` → `ask_yn || die`（`GITHUB_ACTIONS=true` でも省略しない）→ 未コミットの変更があれば die
5. **Salesforce 組織に接続する（先に行う）**: `~/.sf-jwt/<REPO_NAME>/server.key`（既定では `server.crt` も）がなければ die → ログイン先の選択 → ログイン → 種類の読み取り → 本番は main のみのガード → 外部クライアントアプリの自動作成（`--legacy-connected-app` のときは手動の入力）→ JWT 認証情報（`SF_CONSUMER_KEY_*` を Secret / `SF_USERNAME_*` / `SF_INSTANCE_URL_*` / `SF_ORG_*` を Variable）を登録。接続できなければ、ブランチ・branches.txt は変更しない（ただし、外部クライアントアプリは JWT 接続テストの前に deploy するため、組織に残る。自動では元に戻さない）
6. 実行前のブランチを記録し、`main` に切り替える。origin に tier のブランチがなければ、**origin/main から**作って `push --no-verify -u`（既存ならスキップ。以前は手元の main から作っていたため、古い内容から派生した）
7. 作業用ブランチ（`system-add-tier-<tier>-<YYYYMMDDHHMMSS>`）を origin/main から作り、手順 3 で読んだ `branches.txt` の末尾に tier を追記・コミット・push し、**PR を作成する**（`main` への直接 push はしない。PR のマージで、`branches.txt` が main に反映される。マージ前に再実行すると、重複の確認では止まらず PR が 2 本できる）
8. 実行前のブランチ（管理者用のクローンでは `admin`）に戻る。手順 6〜8 の失敗は die（作ったブランチ・カレントのブランチは、そのまま残る。再実行では、リモートの tier ブランチがあれば作らずに進む）

スケールアップのみ対応・スケールダウンは対象外:
- tier の削除（スケールダウン）は自動化していない
- スケールダウンは影響範囲が大きく（ブランチ削除・WF 停止・Secrets 削除・Ruleset 更新）、誤操作リスクが高いため**手動運用とする**
- 必要な場合は GitHub リポジトリ設定・`branches.txt` 編集・ローカルブランチ削除を手動で実施すること

#### 4.13.2 sf-init の状態（保存ファイルと環境変数）

`sf-init.sh` の Phase 間の受け渡しと、再開（続きをやる）は、管理者用フォルダ（`{作業フォルダ}/admin/`）の 2 つのファイルと、環境変数で行う。
変更するときは、この表と、書く側・読む側の両方を、確認する。

**保存ファイル**

| ファイル | 内容 | 形式 | 備考 |
|---|---|---|---|
| `.sf-init-XXXX.env` | 入力内容（Phase 2 以降が読む。XXXX = プロジェクト名） | `KEY="値"`（各 Phase と、sf-init.sh の後処理は `source` で読み込む。フェーズループの前の判定は `_kv_value`。権限 600。Windows では効果なし） | 完了時に `*TOKEN_VALUE=` の行を消し、完了の印を付けたあと、**ファイルごと削除する**（最後まで終わったとき。途中で止まったとき・印を付けられなかったときは残る）。別のリポジトリの状態なら、残骸として扱い、最初から |
| `.sf-init-XXXX.progress` | 進捗（どこまで成功したか。XXXX = プロジェクト名） | `KEY=値`（書き換えに外部コマンドを使わない） | `--only` では書かない。`.sf-init-XXXX.env` がないときも書かない。Phase 1 は、状態を持たないため、記録しない。完了時に、`.sf-init-XXXX.env` と一緒に削除する |

保守用のモード（`add_tier.sh` / `reconnect.sh` / `status.sh` / `verify.sh`）は、状態ファイルを読まない（origin の URL から、リポジトリを求める: `parse_github_remote`）。Phase のスクリプトは、`SF_INIT_ENV_FILE` が未設定のとき、`${PWD}/.sf-init.env` を使う。

**`.sf-init-XXXX.env` のキー**

| キー | 意味 | 書く | 読む |
|---|---|---|---|
| `GITHUB_OWNER` | リポジトリのオーナー（`SF_INIT_OWNER`。引数か対話で決めたもの） | Phase 2（ファイルを作り直す） | Phase 3（クローンの origin の確認）以降 |
| `PROJECT_NAME` | プロジェクト名 XXXX（`SF_INIT_PROJECT`） | Phase 2 | Phase 6（Token の Note）・Phase 7（Slack App の名前） |
| `REPO_NAME` / `REPO_FULL_NAME` | `force-{PROJECT_NAME}` / `{owner}/force-{PROJECT_NAME}` | Phase 2 | Phase 3 以降。`sf-init.sh` が、前回の状態が、同じリポジトリのものかの判定にも使う |
| `REPO_DIR` | 管理者用フォルダ内の clone 先（`{admin の絶対パス}/force-{PROJECT_NAME}`） | Phase 2 | Phase 3 以降・後処理（同期・admin ブランチ・完了画面の管理者用フォルダの案内）・`verify.sh`（ステップ 9）・完了済みの判定 |
| `ENV_TYPE` | sf-tools の版（`production` / `staging`）。`SF_TOOLS_BRANCH` の決定に使う | Phase 2 | Phase 2（同じ Phase の中） |
| `SF_TOOLS_BRANCH` | Actions が使う sf-tools のブランチ（`main` / `development`） | Phase 2 | Phase 9（`development` のときだけ、GitHub の Variable に登録。未設定なら main として扱う） |
| `BRANCH_COUNT` | 段階の数（1〜3） | Phase 5（追記） | Phase 10（段階。ないときは 1）・ステップ 9（目安の時間）・完了画面（組織の数）。Phase 8・9 は使わない（Phase 8 は branches.txt を読む） |
| `PAT_TOKEN_VALUE` | PAT（**秘密情報。一時的**） | Phase 6（追記） | Phase 8（push に使い、直後に、この行を消す。Phase 8 が途中で失敗したときは、再開のために残る） |
| `APP_TYPE` | Salesforce の接続の種別（`1` = 接続アプリ（従来）/ `2` = 外部クライアントアプリ） | Phase 10（追記） | Phase 10（再開時に再利用。`--legacy-connected-app` の指定で 1 以外なら中断） |

**`.sf-init-XXXX.progress` のキー**

| キー | 意味 | 書く | 読む |
|---|---|---|---|
| `SF_INIT_DONE_PHASE` | 最後に成功した Phase の番号（`2`〜`10`。`10` = 完了済み） | `sf-init.sh`（Phase が成功するたび。ファイルを書き直す） | `sf-init.sh`（続きの選択肢・完了済みの判定・`--resume N` / `--only N` の拒否） |
| `SF_INIT_DONE_AT` | 上の日時（表示用） | 同上 | 続きの選択肢の表示 |
| `SF_INIT_DONE_TIER_PROD` / `_STG` / `_DEV` | Phase 10 で、その段階の接続まで完了した（`1`） | Phase 10（`_register_org` が、追記） | Phase 10（再実行でスキップ。Secret が、いまもあるときだけ）。Phase 10 が成功すると、`sf-init.sh` がファイルを書き直すため、消える |

**環境変数（保存しない）**

| 変数 | 意味 | 設定する | 使う |
|---|---|---|---|
| `SF_INIT_MODE=1` | init の一部として動く（`common.sh` の force-* のチェックを、飛ばす） | `sf-init.sh` と各 Phase | `lib/common.sh`・各 Phase |
| `SF_INIT_OWNER` / `SF_INIT_PROJECT` | オーナー・XXXX（`--owner` / `--project`、または対話で決めた値。sf-tools 更新後の実行しなおしにも引き継ぐ） | 利用者・`sf-init.sh`（`resolve_init_identity`） | `resolve_init_identity`・`02_project_info.sh`（必須） |
| `SF_INIT_ENV_FILE` / `SF_INIT_PROGRESS_FILE` | 上の 2 つのファイルの絶対パス | `sf-init.sh` | 各 Phase・`10_sf_auth.sh` |
| `SF_INIT_TIER_RESUME=1` | Phase 10 の段階ごとの再開を有効にする（`--only` では、設定しない。鍵を作り直した実行では、Phase 10 が 0 にする） | `sf-init.sh` | `10_sf_auth.sh` |
| `SF_INIT_SYNC_TIMEOUT` | 最初のメタデータの同期の待ち時間の上限（秒。既定 1200） | 利用者・テスト | `init-common.sh`（`initial_metadata_sync`） |
| `ADD_TIER` / `RECONNECT_TIER` | `--add-tier` / `--reconnect` の値 | `sf-init.sh` | `add_tier.sh` / `reconnect.sh` |
| `SF_INIT_LEGACY_CONNECTED_APP=1` | `--legacy-connected-app`（従来の接続アプリを使う） | `sf-init.sh` | `10_sf_auth.sh`・`add_tier.sh`・`reconnect.sh` |
| `SF_INIT_RESTARTED` | sf-tools を更新して、同じ引数で、実行しなおした（無限に、実行しなおさないため） | `sf-init.sh` | `sf-init.sh` |
| `SF_INIT_TOOLS_CHECKED_BRANCH` | sf-tools の最新確認を済ませたブランチ（Phase 2 で、二重に確認しない） | `sf-init.sh` | `02_project_info.sh` |
| `SF_INIT_RUNNING=1` | Phase 4 → `sf-install.sh` の初期化モード（`~/sf-tools` の `git pull`・`npm install` を飛ばし、`metadata.txt`・`branches.txt` がなければテンプレートからコピーし、`.gitmessage` を置く。フックの設置は通常どおり行う） | `04_gen_files.sh` | `sf-install.sh` |
| `SF_INIT_PUSH_TOKEN` | Phase 8 の push の PAT（`GIT_ASKPASS` で、git に渡す。URL・引数には、出さない） | `08_initial_commit.sh` | 一時スクリプト（終了時に削除） |
| `SF_INIT_LOGIN_URL_{PROD,STG,DEV,START}` | ログイン先の指定（`login` / `test` / URL）。対話の質問を、省略する（e2e・テスト用） | 利用者・e2e | `lib/org.sh`・`reconnect.sh`・`sf-start.sh` |
| `SF_INIT_JWT_RETRIES` / `SF_INIT_JWT_INTERVAL` | JWT 接続テストの再試行の回数・間隔（テストで短くする） | テスト | `init-common.sh` |
| `SF_INIT_VERIFY_ASK=1` | 端末でなくても、ステップ 9 の質問を出す（テスト用） | テスト | `sf-init.sh` |
| `SF_VERIFY_CONFIRMED=1` | `sf-init.sh` が確認済みのため、`verify.sh` の確認を省略する | `sf-init.sh` | `verify.sh` |

### 4.14 sf-check.sh

> 仕様の正本は、`bin/sf-check.sh` の冒頭コメント（`--help`）。ここは要点と設計の経緯。

ターゲットファイルの構文チェックと、テストクラス不足検出を行う。`sf-release.sh` / `sf-push.sh` / `sf-precommit.sh` / `sf-prepush.sh` / `sf-launcher.sh`（メニューの Check）から呼ばれる。単体でも実行できる。

- 引数: 2 つ以上なら 1 つ目を `deploy-target.txt`、2 つ目を `remove-target.txt`（3 つ目以降は無視）、1 つなら `deploy-target.txt` だけ。引数なしなら、`sf-tools/release/branch_name.txt`（Git の管理外。sf-install.sh が保存）のブランチ名で、`sf-tools/release/<ブランチ名>/` の 2 つを検証する（今の Git のブランチではない。`branch_name.txt` がなければ、WARNING を出して終了コード 0。コミットを止めない）
- `-v` / `--verbose` は受け付けるだけ（run を使わないため）。ほかの `-` で始まる引数（2 つ目以降の `-h` / `--help` を含む）は「不明なオプションです」で中断
- ターゲットファイルがなければ、その検証を飛ばす。何も書かれていなければ、警告だけ
- **速度の設計（2026-10-28）:** 1 行・1 クラスごとに、外部のプログラム（`awk`・`grep`・`basename`・`dirname`）を起動しない。プロセスの起動が遅い Windows の Git Bash では、行数に比例して、極端に遅くなるため（300 行で 2 分 48 秒。WSL では 6 秒）。具体的には、①可否の表（`config/metadata-capability.txt`）は、最初に 1 回だけ読み込み、文字列の操作で引く（`lookup_capability`）、②種類の推定は、変数に入れる（`type_of_path`。`$(…)` のサブシェルを作らない）、③ファイルの本文は、組み込みの `read` で読む（`read_text`）。`@isTest` の判定は `nocasematch`（`text_has_istest`）、④テストクラスの本文検索（Step B）は、`@isTest` を含むファイルの一覧と本文を、最初に 1 回だけ読み込み（`load_test_files`）、単語の判定は正規表現（`text_has_word`。クラス名が英数字と `_` だけのときだけ。それ以外は、従来どおり `grep -w`）、⑤`basename` / `dirname` は、文字列の操作。結果は、旧版と同じ（出力が一致することを、境界の条件の多数のデータで確かめた。`tests/test_sf-check.sh` に回帰テスト）。効果（Windows の Git Bash、100 クラス・別名のテスト）: 376 秒 → 2 秒。300 クラスで 3〜8 秒。1000 クラスは約 54 秒（テストクラスの本文検索が、クラス数 × テストクラス数の二重ループのため）

`check_target_file` の処理（`deploy-target.txt` / `remove-target.txt` 共通。CR と前後の空白を除き、空行と `#` の行は読み飛ばす。最初のマーカーより前の行は `[files]`）:
- `[files]` セクション: リポジトリの外を指すパス（`/`・`C:/`・`C:\` で始まる絶対パス、要素に `..` を含むパス）は、存在してもエラー。ディレクトリは `lwc/<名前>`・`aura/<名前>`・`objects/<名前>` だけ書ける（`classes` や `.` など、ほかのディレクトリは、リリース・削除の対象が広がりすぎるためエラー。remove-target.txt では、組織のメタデータが広範囲に削除される）。ファイルとして存在しなければエラー。エラー・警告は `print_gcc_message` で GCC スタイル（`<ファイル名>:<行番号>: error|warning: <理由>`。ファイル名は渡したパスではなく `deploy-target.txt` / `remove-target.txt`）で標準出力に出す
- `[members]` セクション: `種別名:メンバー名` 書式確認（`:` がない・先頭か末尾が `:` → エラー）
- 種類の可否（`check_capability`）: `config/metadata-capability.txt`（`SF_CHECK_CAPABILITY_FILE` で差し替え可）を `awk` で引く。`[members]` は先頭の種類名、`[files]` は `type_of_path`（flows / classes / triggers / lwc / aura / servicePresenceStatuses / standardValueSets のパス）から種類を決める。`deploy-target.txt` は release 列、`remove-target.txt` は delete 列を見る。`ng` はエラー（`error_count` に加算）、`limited` は警告のみ、`ok` / `unknown` / 表にない種類は何もしない。表のファイルがなければ確認しない。`SF_CHECK_IGNORE_CAPABILITY=1` で省略
- エラー数は `_CHECK_ERRORS` に加算し（`return` の 255 の上限を避ける）、1 件以上なら終了コード 1（不明なオプション・force-* の外での実行も 1。警告のみ・検証を飛ばした場合は 0）

`check_missing_tests` の処理（WARNING のみ・エラーにならない。上のエラーの有無にかかわらず行う）:
- `deploy-target.txt` の `[files]` セクションから `.cls` ファイルを収集
- 各 `.cls` に対して `@isTest`（大文字・小文字を区別しない）があればテストクラス自身と判断してスキップ
- Step A: 同一ディレクトリ内で `MyClassTest.cls` / `MyClass_Test.cls` を探す
- Step B: A で見つからない場合、`grep -rl --null --include="*.cls" "@isTest" .`（大文字・小文字を区別する）の結果を `while read` で 1 つずつ調べ、クラス名を単語として含む最初のファイルを使う（以前の `xargs` は、空白を含むパスを分割して、正しく動かなかった）
- 見つかったテストクラスのパスが、`deployed_files`（deploy-target.txt の `[files]` の行）と、どちらも先頭の `./` を除いて一致しなければ `print_gcc_message` で警告（行番号なし）。テストクラスが見つからないときは、何も出さない
- 設計思想: 本番/Sandbox に既存のテストクラスは含めなくてよい → WARNING 扱い（エラーにはしない）
- ログ: `./sf-tools/logs/sf-check.log`（追記）


#### 4.14.1 sf-typecheck.sh（種類ごとの可否の確認）と config/metadata-capability.txt

> 仕様の正本は、`bin/sf-typecheck.sh` と `lib/typecheck.js` の冒頭コメント（`--help`）。ここは要点と設計の経緯。

管理者・開発者向け。個人用の組織（Developer Edition / Sandbox / Scratch / Trial）で、メタデータの種類ごとに、最小のサンプルを実際にリリース → 削除し、結果を TSV（`種類 / release / delete / 備考`、値は `ok` / `ng` / `limited` / `unknown`）にする。本体は `lib/typecheck.js`（Node 標準ライブラリのみ。シェルから呼ぶ境界は `bin/sf-typecheck.sh` の 1 か所）。一時フォルダ（`${TMPDIR:-/tmp}/sf-typecheck-XXXXXX`。終了時に削除）の使い捨てのプロジェクトで動く。force-* の外でも実行できる。結果の表（`--out`。既定 `./sf-typecheck-result.txt`）は、すべての種類を処理し終えたときだけ書く。

- 安全: 冒頭に赤い警告ボックス + `ask_yn || die`（`-y` で確認だけを省略。`--list`・`--coverage` も同じ）。そのあと、GitHub Actions 上・`--org` なし・予約名のエイリアス（prod / staging / develop / main）・`sf --version` の失敗・組織の情報（Organization）を読めない・本番・種類を判定できない組織は拒否（`--list`・`--coverage` は、この確認より前に終わるため、Actions 上でも動く。ただし確認は省かないので、`-y` を付ける）。作成・削除するのは名前に `SfToolsE2eMin` を含むものだけ（LWC はコンポーネント名の先頭が小文字の決まりのため、`sfToolsE2eMin` も可。認めるのはこの 2 通りの綴りだけ。`lib/typecheck.js` が、作成前に確認する。拒否に当たると、その時点で中断し、それまでの種類の処理は実行済みのまま残る）。許可する sf のコマンドは `project deploy start` / `project deploy validate` のみ（`lib/typecheck.js` の `ALLOWED`。それ以外は例外で中断）
- `--validate-only`: `sf project deploy validate` だけ行い、delete の列は `unknown` のまま。`--only A,B`: 指定した種類だけ（`--list` の名前と完全一致。1 つも一致しなければ 0 種類で正常終了）
- オブジェクト名・メタデータ名は、実行ごとの時刻つき（削除したカスタムオブジェクトの名前は、約 15 日間、予約されるため）
- テストでは `SF_TYPECHECK_CMD` で、sf をモックに差し替える
- 終了コード: `lib/typecheck.js` は 0（すべて ok）/ 3（ng あり）/ 1（実行の失敗）。`sf-typecheck.sh` は、3 を警告にして、0 で終わる（結果の表で判断する）。`sf-typecheck.sh` の 1 は、中断（不明なオプション・値のないオプション・N / q・上の拒否・必要なファイルや node がない・`lib/typecheck.js` の失敗）
- `config/metadata-capability.txt` は、この結果を人が確認して反映する表。`ng`（必ずできない）/ `limited`（権限・使用中・標準のもの・移行済み など、条件による）/ `unknown`（サンプルを作れていない・標準の部品しかない）の区別を守る。`ng` には、備考（理由）を必ず書く（テストで検査）。個別の組織の権限で、できないだけのものは、`ng` にせず `limited` にする
- `--coverage`: 組織に接続せず、`config/changeset-types.txt`（変更セットで扱える種類。公式の Metadata Coverage Report の ChangeSets 列。取得日・出典は、ファイルの冒頭）と `config/metadata-capability.txt` を突き合わせ、確認済み / リリースのみ / 条件つき・NG / 判定できない / 未確認の数と一覧を出す（awk のみ。`SF_TYPECHECK_CHANGESET_FILE`・`SF_CHECK_CAPABILITY_FILE` で、ファイルを差し替え可）。表の種類名と、変更セット側の複数形・単数形が違うもの（CustomLabels など）は、別名で引く
- 確認した環境: Developer Edition（API 64.0）。新しい種類の確認を足すときは、`lib/typecheck.js` の `S`（サンプルの一覧）に追加する
- サンプルの定義（`add(種類, files, del, extra)`）: `del` の中の `null` は、削除の段階の区切り（直前の削除が終わってから、次を実行する）。`extra.covers` は、同じサンプルで一緒に確認できた別の種類（表に同じ結果の行を足す）。共有ルールは、作成直後は、再計算が終わるまで、削除が `sharing operation already in progress` で失敗するため、30 秒おき・最大 8 回、やり直す
- 失敗の理由が、サンプルの書き間違い・組織の機能がない（例: `Not available for deploy for this organization`）場合は、表には、`ng` ではなく `unknown` として書く（`ng` は、サンプルが正しいことを確認してから）

### 4.15 sf-sync-wf.sh

> 仕様の正本は、`bin/sf-sync-wf.sh` の冒頭コメント（`--help`）。ここは要点と設計の経緯。

作成済みの `force-*` の `.github/workflows/` を、sf-tools の雛形（`templates/.github/workflows/`。新規のプロジェクトには、sf-init の Phase 3 がコピーする）に合わせる管理者向けコマンド（設計: `doc/wf-distribution-strategy.md`）。`sf-install.sh` などから自動では実行しない（利用者の意思なく、ワークフローが書き換わるのを防ぐため）。実行フロー（順序変更禁止）:
1. オプション解析（`--check` / `--remove <ファイル名>` / `-v` / `-h`（第 1 引数のときだけ）。不明なオプションは die。`--remove` の値がない・`-` で始まるときも die。`--check` と `--remove` の同時指定は die（`--check` は何も変更しないモードのため））
2. `check_force_dir`（force-* 以外は die）→ 雛形のフォルダ（このスクリプトがある sf-tools の `templates/.github/workflows`）がなければ die → 現在のブランチを取得できない（HEAD がブランチでない）、または `is_protected_branch`（`branches.txt` のブランチ。ファイルがない・空なら main のみ）なら die
3. **sf-tools が最新であること（必須）**: `ensure_sf_tools_latest "$SF_TOOLS_DIR"`（`--check` のときは `--no-update`: 遅れていれば、更新せず die）。最新なら続行。遅れていれば、未コミットの変更・未 push のコミットがあれば die、なければ Y/N/q で確認して（N / q は die）`git pull --ff-only`（失敗は die）。origin に接続できないときは die。Git リポジトリでない・HEAD が分離状態・origin に同じブランチがない（`git ls-remote --exit-code` の 2）ときは、確認できないため WARNING で続行。戻り値 2（更新した）なら、`SF_SYNC_WF_RESTARTED=1` を export して、同じ引数（`ORIG_ARGS`）で `exec` して再実行する（実行中のスクリプトが書き換わるため）。すでに再実行済み（`SF_SYNC_WF_RESTARTED` あり）でまだ 2 なら die（無限ループ防止）。古い雛形で、プロジェクトのワークフローを書き換えないための必須の手順
4. **冒頭の警告ボックス（`print_admin_warning`）+ `ask_yn || die`**（CLAUDE.md 2.4。N / q は die。`GITHUB_ACTIONS=true` でも省略しない）。`--check` は、何も変更しないため、表示しない
5. `--remove`: ファイル名を `^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$` で検証（`/`・`\` を含む名前・英数字以外で始まる名前は拒否。区切りを含まないため、途中に `..` があってもフォルダの外は指せない）→ `.github/workflows/` にあること → **雛形にあるファイルは拒否**（廃止されたものだけが対象）→ 2 回目の `ask_yn`（削除は二重確認）→ `rm` して終了（比較・上書きはしない）。コミットはしない
6. 雛形と比較（`diff -q --strip-trailing-cr`。CRLF だけの違いは無視）: 雛形の `*.yml` のうち、内容が違う `CHANGED`・プロジェクトにない `NEW`、プロジェクトの `*.yml` / `*.yaml` のうち雛形にない `EXTRA`（名前を表示するだけで、変更しない。削除は `--remove`）
7. 新規・差分なし → 「ワークフローは最新です」で終了（0）。差分あり → `diff -u` を表示
8. `--check`: ここで終了（差分あり: 終了コード 1）
9. 差分を見たうえで、2 回目の `ask_yn`（N / q は die。何も変更しない）→ 新規・差分のファイルを `cp`（上書き）。コミット・プッシュはしない

終了コード: 0 = 違いなし・上書きした・削除した / 1 = 中断（N / q を含む）、または `--check` で違いあり（`--check` の 1 は、「違いあり」と「中断」（sf-tools が遅れている・環境ブランチ など）を区別しない）。ログ: `./sf-tools/logs/sf-sync-wf.log`（実行ごとに作り直す）。

**更新の手順（推奨）:** `sf-job.sh` でジョブ名 `system-日付` の作業用ブランチを作る（固定の `system` ブランチは、あらかじめ作らない。`sf-job.sh` は同名のブランチを拒否し、長く残るブランチは古くなるため）→ `sf-sync-wf.sh` → `git diff` → `sf-push.sh` → PR・マージ（複数の環境がある構成では `develop` → `staging` → `main` の順。`sf-next.sh` が案内する）。ワークフローをプッシュするには、`workflow` スコープのある権限が必要。

テスト: `tests/test_sf-sync-wf.sh`（モックの HOME に雛形を置き、ガード・差分・N/q/Y・CRLF・`--check`・`--remove` を確認。実際の雛形のコピーが `--check` で差分なしであることも確認）、`tests/test_common.sh` の `test_ensure_sf_tools_latest`（本物の git で、最新・遅れ・未コミット・未プッシュ・更新を断る・`--no-update` などを確認。bare の origin は `--initial-branch=main` で作る。環境によって既定のブランチ名が違うため）
---

#### 4.15.1 verify.sh（sf-init.sh --verify）

> 仕様の正本は、`phases/init/verify.sh`・`lib/verify-common.sh`・`lib/verify-samples.sh` の冒頭コメント。ここは要点と設計の経緯。

管理者が、実際のリポジトリ・実際の組織で、リリースと削除が動くことを確認する（`phases/init/verify.sh`。部品は `lib/verify-common.sh`）。ログは `~/sf-tools/logs/verify.log`（実行ごとに新しく書く。sf-init.log とは別）。終了コード: 0 = すべての確認が成功（`--plan`・`--help` を含む）/ 1 = 失敗した確認がある・途中で止めた・die。

**オプションの組み合わせ:** `--validate-only`・`--with-objects` は `--components` と一緒でなければ die。`--validate-only` と `--cleanup` は同時に指定できない。ほかの引数は「不明なオプションです」で die。`-h` / `--help` は第 1 引数のときだけ（`sf-init.sh --verify -h` では sf-init.sh のヘルプが出る）。

**フロー:** (1) `GITHUB_ACTIONS` なら中断。force-* の中で実行。origin の URL からリポジトリを求める（`parse_github_remote`。GitHub 以外は die）。`check_gh_owner` (2) 段階の判定: リモートのブランチから（一覧を取得できない・`main` がなければ die。develop + staging があれば 3 層・staging があれば 2 層・それ以外は main のみ。`--components` は develop だけで、develop がなければ die）。リリースの順は develop → staging → main (3) 診断（`diag_run`。対象は (2) で決めた段階だけ）。不足があれば、確認の前に中断 (3b) 検証用と同名のクラスのファイルが、いずれかの段階のブランチに、すでにあれば、中断（`--cleanup` は、対象外）(4) 実行内容の表示（段階ごとの `SF_ORG_NAME_*`・`SF_ORG_KIND_*`・`SF_USERNAME_*`。種類が developer / sandbox / trial 以外は、本番扱いで赤く表示）。`--plan` はここで終了 (5) 確認（`SF_VERIFY_CONFIRMED=1` のときは、聞かない）: 警告ボックスと `wizard_confirm`（Enter / Y で進む。N / q / EOF は中断。入力を最小にするため）。本番扱いの組織があれば、質問の文面で、本番を含むことを明示する（リポジトリ名・`production` の入力は、求めない） (5b) 環境の確認（`--cleanup` では行わない。NG があれば、そこで止める。`wf-metasync` は、手前の 2 つの確認が OK のときだけ起動する）: `SF_TOOLS_BRANCH` が main / development／`~/sf-tools/logs/*.log` に Token・認証 URL（`ghp_` / `github_pat_` / `xoxb-`・`xoxp-` / `force://…`）が残っていない（`_logs_clean`）／`wf-metasync` を `verify_dispatch_workflow` で手動起動 → `verify_wait_run` → `_run_ok`（失敗は 1 回だけ再実行）→ ステップ `Salesforce 組織にログイン`・`自動化ツール（sf-tools）を取得` が success（`--no-metasync` で省略）(6) リリース: main の先頭から `verify-hello-時刻` を API で作り（クラスのファイル 4 つ + `deploy-target.txt` + 空の `remove-target.txt`）、段階ごとに PR → wf-validate → マージ → wf-release（→ main のとき wf-propagate）。各 PR の前に、実行 ID の基準を覚え、より新しい実行だけを、その PR の実行とする。失敗した実行は、1 回だけ再実行する (7) 削除: main の先頭から `verify-hello-delete-時刻`（クラスのファイルを API で削除 + `remove-target.txt`）を作り、同じ順に各段階へ (7b) 後始末（`_delete_job_branches`）: 今回作ったブランチ（`verify-hello-時刻` / `verify-hello-delete-時刻`。`--components` の名前は下記。`--cleanup` では削除用のみ、`--validate-only` ではリリース用のみ）を、API で削除する。名前が `^verify-(hello|comp)(-delete2?)?-[0-9]{6}$` に合うことと、そのブランチを head とする、開いている PR がない（確認できないときも、ない扱いにしない）ことを確認してから削除する。途中で止めたとき（`exit` の前）は、行わない（調査のために、残す）。削除の失敗は、警告のみで、検証の成否に含めない。PR の履歴は、PR の番号で残る (8) 結果。

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

文書は 3 階層（コードの冒頭コメント → 技術者向け → 一般向け）で、情報は上から下へだけ流す（決まりの正本は `doc/doc-style.md`）。スクリプトの実装詳細を変更した場合は以下も確認・更新すること:

| 変更内容 | 確認先 |
|---|---|
| 各スクリプトの冒頭コメント（仕様の正本） | `doc/doc-stamps.txt` に載っている文書。変えたら `bash tests/docs-stamp.sh --diff <文書>` で変更を見て、文書を読み直し、`--update <文書> [<コード>]` で印を付け直す（`tests/test_docs_stamps.sh` が、見直しの漏れを検出する。文書は自動では直さない）。印の対象は、`bin/sf-*.sh`・`phases/init/` の一部・`lib/typecheck.js`。新しい `bin/sf-*.sh` は、どれかの文書の基にしないと `--check` が失敗する |
| `sf-init.sh` のフロー・入力項目 | `site/admin/setup.html`（印あり）、本書 4.13 |
| ファイルパス・ディレクトリ構造 | `site/reference/structure.html`・`site/reference/commands.html`、`README.md` セクション 5（コマンド早見表）、本書 8 |
| PAT の種類・取得方法 | `site/admin/setup.html#in-pat`・`site/admin/secrets.html`、`doc/sf-cicd-strategy.md` セクション 7.1・8 |
| WF ファイル名・ジョブ名 | `site/admin/workflows.html`、`doc/sf-cicd-strategy.md` セクション 4.2 |
| `templates/.github/workflows/` の `name:` | `site/admin/workflows.html` のワークフロー一覧 |
| `templates/.github/workflows/` のジョブ名（`wf-validate`・`wf-sequence`） | `required_status_check_names`（`lib/project.sh`。force-* の Ruleset の必須チェックの名前の正本。9.5）。`tests/test_sf-init.sh` の `test_required_checks_match_workflows` が食い違いを検出する |
| `.github/workflows/test.yml` のジョブ名・matrix の数 | sf-tools の Ruleset `protect-main` の必須チェック（9.5）と、`CLAUDE.md` の個数（11 個） |
| コマンドの使い方・オプション・画面の文言 | `site/`（使い方ガイド・リファレンス。9.8）。README は、概要だけ（詳細は、サイトへ） |
| `site/`・`README.md` に書いたコマンド名・オプション・パス・環境変数 | `tests/test_docs_facts.sh` が、実在を確認する（`doc/` は対象外。実在しないが書いてよいものは `tests/docs-facts-allow.txt`） |
| `*.md` の見出し | `tests/test_docs.sh`（番号・深さ・連番・LF）。`site/` の見出しは `tests/test_site.sh`（番号は手で書かない。9.8） |
| mm / rr の運用・リリース手順 | `CLAUDE.md` 1.2・1.3・4.3、`doc/dev-guide.md`、本書セクション 9 |

> ドキュメントの詳細（フロー・パス等）はコードを確認してから記載すること。推測で書かないこと。
> 「ドキュメントを最新化して」と言われたときの対象は、リポジトリ内のすべての `*.md` と `site/`（`CLAUDE.md` 1.4）。

---

## 6. スクリプト依存関係マップ

変更の波及確認に使うこと。

| 呼び出し元 | 呼び出し先 | 備考 |
|---|---|---|
| `sf-job.sh` | `sf-start.sh` | クローンのあと、そのフォルダで引数なしで実行（対話のため `run` なし） |
| `sf-restart.sh` | `sf-start.sh` | 接続設定を消したあと、`FORCE_RELOGIN=1` を付けて実行 |
| `sf-start.sh` | `sf-install.sh` | `~/sf-tools/bin/sf-install.sh` をバックグラウンドで起動（完了は待たない） |
| `sf-start.sh` | `sf-launcher.sh` | install の起動の直後に起動（完了は待たない）。`SF_LAUNCHER_ACTIVE=1` なら起動しない（二重起動防止） |
| `sf-launcher.sh` | `sf-check` / `sf-push` / `sf-next` / `sf-dryrun` / `sf-deploy` / `sf-start` / `sf-restart`（`.sh`） | メニューから実行（VS Code の中では start / restart を出さない）。`SF_LAUNCHER_ACTIVE=1` を export する |
| `sf-install.sh` | `sf-hook.sh` | フックのインストール（`run`） |
| `sf-install.sh` | `sf-upgrade.sh` | `~/.sf-tools-last-update` から 24 時間以上でバックグラウンド起動 |
| `sf-dryrun.sh` | `sf-release.sh` | `exec`。オプションなし（dry-run） |
| `sf-deploy.sh` | `sf-release.sh` | `exec`。`--release --force` 付き |
| `sf-release.sh` / `sf-push.sh` / `sf-precommit.sh` / `sf-prepush.sh` | `sf-check.sh` | ターゲットファイルの検証 |
| `hooks/pre-commit` | `sf-precommit.sh` | `~/sf-tools/bin/` のものを呼ぶラッパー（`sf-hook.sh` が `.git/hooks/` へコピー） |
| `hooks/pre-push` | `sf-prepush.sh` | 同上。組織への dry-run は行わない |
| `sf-typecheck.sh` | `lib/typecheck.js`（`node`） | 確認の本体 |
| `sf-init.sh` | `phases/init/01〜10_*.sh` | フェーズ順に `bash` で実行。Phase 2 が終了コード 75（sf-tools を更新）を返したら、自分を `exec` で実行しなおす（1 回だけ） |
| `sf-init.sh --add-tier` / `--verify` / `--status` / `--reconnect` | `phases/init/add_tier.sh` / `verify.sh` / `status.sh` / `reconnect.sh` | 保守用のモード。`verify.sh`・`status.sh` は、「前回のセットアップ」の選択肢と、完了後の動作確認（`SF_VERIFY_CONFIRMED=1`）からも呼ぶ |
| `phases/init/04_gen_files.sh` | `sf-install.sh` | Phase 4（`SF_INIT_RUNNING` 付き。`git pull`・`npm install` はしない） |
| `phases/init/08_initial_commit.sh` | `sf-hook.sh` | Phase 8 |
| `sf-sync-wf.sh` | 自分（`exec`） | sf-tools を更新したあと、実行しなおす（1 回だけ） |
| `tests/e2e/lib.sh` | `lib/verify-common.sh` | PR・実行の待ち・Hello World の本文を、`verify.sh`（4.15.1）と共有する |

ライブラリの読み込み（`source`）: `lib/common.sh` が `input.sh`・`platform.sh`・`project.sh` を読み込む（ほぼ全スクリプトが `common.sh` を読む）。`org.sh`・`wizard.sh`・`diag.sh`・`verify-common.sh` は、`common.sh` からは読まず、使うものが個別に読む（`org.sh`: `sf-deploy`・`sf-release`・`sf-start`・`sf-typecheck`・`sf-update-secret`・`verify.sh`。`wizard.sh`: `sf-init`・`verify.sh`。`diag.sh`: `status.sh`・`verify.sh`。`verify-common.sh`: `sf-init`・`verify.sh`・`tests/e2e/lib.sh`。`verify-samples.sh` は `verify-common.sh` が読む）。`phases/init/*.sh` は、`common.sh` と `init-common.sh` を読む。

---

## 7. デバッグコマンド集

### 7.1 テスト

```bash
bash tests/run_tests.sh                           # 全テスト実行（手元では通常は不要。mm 後に CI が全件を実行する）
bash tests/run_tests.sh --changed                 # 変更ファイルに対応するテストのみ（開発中）
bash tests/run_tests.sh --jobs 4                  # 同時に動かすテストファイルの数を指定（既定: CPU の数。環境変数 SF_TEST_JOBS でも指定できる）
bash tests/run_tests.sh --serial                  # 1 つずつ実行（並列で、原因を切り分けにくいときの確認用）
bash tests/run_tests.sh --shard 2/6               # テストファイルを 6 組に分け、2 番目の組だけを実行する（GitHub Actions の Windows が、6 つのジョブに分けて並列に動かす。重いファイルから、いちばん軽い組へ割り当てる。目安は run_tests.sh の _weight）
SF_TEST_TIMES=1 bash tests/run_tests.sh           # 各ファイルの所要時間（[TIME] 行）を、最後に、長い順に表示する（_weight を、実測で直すため）
SF_TEST_LIST_ONLY=1 bash tests/run_tests.sh --shard 2/6   # 実行せずに、その組のファイル名だけを表示する（分け方の確認。tests/test_run-tests.sh が使う）
bash tests/run_tests.sh test_sf-start.sh          # 単体実行
bash tests/test_integration.sh                    # 結合テスト L1 だけ（全件にも含まれる）
SF_TEST_SKIP_INTEGRATION=1 bash tests/run_tests.sh   # 全件から結合テスト L1 を外す（CI の Linux・macOS の全件テスト。結合テストは別のジョブ）
SF_TEST_NO_WSL=1 bash tests/run_tests.sh          # Windows の Git Bash で、WSL に移らずに実行する（CI の Windows）
SF_TEST_PROGRESS=1 bash tests/run_tests.sh        # 起動するテストファイルを、順に表示する（途中で止まったファイルを探すため）
cat logs/run_tests.log | grep '\[FAIL\]'          # 失敗行のみ抽出（sf-tools のルートの logs/）
cat sf-tools/logs/error.log                       # run で失敗したコマンドのログ（force-* の中。sf-init・sf-job・sf-typecheck は ~/sf-tools/logs/）
```

実環境で `sf-init.sh` を通しで検証する e2e は、通常のテストには含まれない（9.6 参照）。

e2e の正は GitHub Actions（`e2e.yml`）の結果で、手元では、原則として動かさない（同じ組織を取り合うため。`CLAUDE.md` 1.2）。下は、Actions を使えないときと、新しい環境の確認用。

```bash
bash tests/e2e/doctor.sh                          # e2e を動かせる環境かの確認（読み取りのみ。新しい環境で、run.sh の前に）
bash tests/e2e/bootstrap.sh                       # 鍵一式の作成（最初の 1 回だけ）
bash tests/e2e/bootstrap.sh --add-orgs            # staging・develop のテスト用組織を、鍵一式に追加（2 層・3 層の確認に必要）
bash tests/e2e/bootstrap.sh --refresh-orgs        # 登録済みの認証 URL の有効性を確認し、無効なものだけを、ブラウザでのログインで取り直す
bash tests/e2e/run.sh --with-args                  # sf-init / sf-job に、引数 --owner / --project を付ける（既定は、引数なしの対話と、クローンからの自動判定）
bash tests/e2e/run.sh --no-add-tier                # 最後の --add-tier の確認（約 4 分）を省略する
bash tests/e2e/run.sh --layout 3                  # 3 層で、段階ごとに、ワークフローを動かして確認（既定は 1 層）
bash tests/e2e/run.sh --resume                    # 前回残したリポジトリで、Hello World の部分だけを再実行する
bash tests/e2e/run.sh --interrupt                 # sf-init を Phase 8 でわざと失敗させ、「続きをやる」で再開してから確認する
bash tests/e2e/run.sh --no-actions                # Actions の実行の確認（wf-metasync・Hello World）を省略する
bash tests/e2e/run.sh                             # 前掃除 → sf-init の通し実行 → 確認 → 終了（既定では、テスト用のものを残す。--cleanup で削除）
bash tests/e2e/scenario.sh --list                 # シナリオの一覧（実環境に接続しない）。名前を並べると、run.sh が残したリポジトリで実行する
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
gh run list --workflow e2e.yml --branch development   # e2e の実行状況（rr の前提の確認。9.3）
git diff --stat origin/main...development -- bin lib phases hooks templates config   # 配布物のパスの差分（空なら e2e は不要。9.3）
gh pr list                                        # オープン PR 一覧
git diff HEAD~1                                   # 直前コミットとの差分
```

---

## 8. force-* ローカル環境ディレクトリ

仕様の正本は `sf-job.sh`・`sf-init.sh`・`sf-install.sh`・`sf-hook.sh`・`phases/init/03_repo_create.sh` の冒頭コメント。ここは要点だけ（利用者向けは `site/reference/structure.html`）。

```
{作業フォルダ}/                     ← 場所は任意（おすすめ: ~/sf）。sf-job.sh・sf-init.sh を実行する場所（admin・force-* の中は不可）
├── admin/                          ← sf-init.sh が作る管理者用フォルダ（完了後も残す。保守に使う）
│   ├── force-XXXX/                 ← 管理者用のクローン（admin ブランチ。完了の印は git config sf-tools.setup-complete）
│   ├── .sf-init-XXXX.env           ← 状態ファイル（Phase 2 が作る。完了したら消える）
│   ├── .sf-init-XXXX.progress      ← 進捗（SF_INIT_DONE_PHASE。完了したら消える）
│   └── .sf-init-XXXX.lock/         ← 実行中の排他（中に PID）
└── {ジョブ名}/                     ← sf-job.sh が作るジョブフォルダ
    └── force-XXXX/                 ← ブランチ {ジョブ名} のクローン（VS Code で開く単位）
        ├── （templates/ の中身）    ← Phase 3 がコピー: .github/workflows/wf-*.yml・force-app/・.vscode/・sfdx-project.json など
        ├── sf-tools/config/        ← metadata.txt・branches.txt
        ├── sf-tools/release/       ← .gitkeep・branch_name.txt（git 対象外）・<ブランチ>/deploy-target.txt・remove-target.txt（main では作らない）
        ├── sf-tools/logs/          ← 各コマンドのログ・error.log（git 対象外）
        ├── .gitmessage             ← コミットメッセージの雛形（sf-init のときだけ設置）
        └── .git/hooks/             ← pre-commit・pre-push（sf-hook.sh が ~/sf-tools/hooks/ からコピー）
```

- プロジェクト（オーナーと XXXX）は、フォルダ名ではなく、引数か、カレントの直下の `*/force-*/` のクローンの git remote から決まる（`sf-job.sh`）
- ホームの下: `~/sf-tools/`（本体。`sf-init`・`sf-job`・`sf-typecheck` のログは `~/sf-tools/logs/`）、`~/.sf-jwt/force-XXXX/`（JWT 用の `server.key`・`server.crt`。Phase 10）、`~/.sf-tools-last-update`（`sf-upgrade.sh` の 24 時間の印）

| 開発用のディレクトリ例 | 作業ブランチ | 用途 |
|---|---|---|
| `C:\home\tama-create\test\system\force-test` | `system` | 開発作業用 |

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
- `sf-init.sh` は、起動時に `~/sf-tools` の現在のブランチが origin より遅れていないかを確認し、Phase 2 で sf-tools の版（1. 配布版 = `main` / 2. 開発版 = `development`）を選んだあと、ブランチ違いを確認する（Y/N/q）。遅れていれば、確認のうえ `git pull --ff-only` し、同じ引数で自動的に実行しなおす（1 回だけ。実行中のスクリプトが書き換わるため。Phase 2 で更新したときは終了コード 75 → `sf-init.sh` が実行しなおす）。ローカルに未コミット・未 push の変更があれば更新せず警告のみ。ブランチの自動切り替えは行わない（仕様の正本は、`sf-init.sh` の冒頭コメント「◆ sf-tools の最新化」と `ensure_sf_tools_branch`（`phases/init/init-common.sh`））

### 9.2 検証環境の作り方

| 対象 | 方法 |
|---|---|
| 新規に作る force-* | `sf-init.sh` の Phase 2 で「2. 開発版（development）」を選ぶ（Phase 9 が、Variable `SF_TOOLS_BRANCH=development` を登録する。配布版では登録しない） |
| 既存の force-* | `gh variable set SF_TOOLS_BRANCH --body "development" -R <owner>/<repo>` |
| ローカル | `~/sf-tools` を `development` にチェックアウトしておく |

- `SF_TOOLS_TOKEN` は不要（`sf-tools` は公開リポジトリのため、Actions は Token なしで clone する。2026-10-05 に廃止。`sf-init.sh` の Phase 11 は無い）。以前のバージョンで作ったプロジェクトのワークフローは、Token 付きで clone しているため、その Token を無効にしないこと

### 9.3 検証チェックリスト（rr の前提）

変更内容に応じて、必要な項目を実施し、Claude が結果を確認して報告する（手動の確認をユーザーに頼むのは、e2e で見えないことだけ。`CLAUDE.md` 1.2）。

**配布物のパス**は、利用者が `git pull` で受け取る実行物の `bin/` `lib/` `phases/` `hooks/` `templates/` `config/`。`tests/` `doc/` `.github/workflows/test.yml` `README.md` などは、実行に使われないため、配布物ではない（同じリポジトリにあるが、利用者の動作には影響しない）。

`git diff --stat origin/main...development -- bin lib phases hooks templates config` が**空**（配布物のパスの変更がない）なら、下の表のうち「テスト」だけを確認する（e2e・ワークフローの手動実行は不要）。**空でなければ**、変更内容に応じて、表の該当する項目を実施する。

| 確認項目 | 方法 |
|---|---|
| テスト | `development` の最新のコミットで、GitHub Actions の全件テスト・shellcheck・結合テスト L1 が、すべて緑（`gh run list --branch development` で確認する。手元で全件を回さない） |
| 配布物のパスを変更した場合（必須） | GitHub Actions の `e2e.yml`（`development` への push で自動。9.6）が成功していること。確認: `gh run list --workflow e2e.yml --branch development` で、配布物を変えた最新のコミット以降の実行が success（手元の `bash tests/e2e/run.sh` は、Actions を使えないときだけ）。e2e は、新規の force-* の `sf-init.sh`（Phase 1〜10・`--add-tier`）、`wf-metasync` の手動起動、Hello World の PR（`wf-validate` → マージ → `wf-release` → 削除）、シナリオ（9.6）を通すため、下の 2 行の確認も兼ねる |
| ワークフロー・`sf-metasync.sh` を変更した場合 | `wf-metasync` を `workflow_dispatch` で起動して成功すること（e2e の `run.sh` が行う。シナリオ `metasync-diff` は、組織の差分が main に入ることまで確認する） |
| `sf-release.sh` / `wf-validate` / `wf-release` を変更した場合 | デプロイ対象を含む PR で、`wf-validate` が通ること（e2e の Hello World。シナリオ `validate-fail` は、失敗の検出と再検証。手で確かめるときは、動作確認のみの PR はマージせずに閉じる。マージすると `wf-release` が実際にデプロイする） |

> `templates/` の変更は配布済みの force-* に自動反映されない。既存の force-* の `wf-*.yml` は、管理者用のクローンで `sf-sync-wf.sh` を実行して `templates/` と一致させる（4.15）。

### 9.4 リリース（rr）

1. 9.3 の確認が完了している（配布物のパスの変更がないときは、全件テストと CI の成功だけでよい。配布物のパスの変更があるときは、`e2e.yml` の成功も必要）
2. 「rr」の指示で、`development` → `main` の PR を作成してマージする（手順は `CLAUDE.md` 1.3.2）
3. マージ後、`main` の内容を検証環境の force-* でもう一度確認する（配布版のワークフローが sf-tools の `main` を使うことは、e2e のシナリオ `dist-main` で確認できる。rr の直後だけ動く）

### 9.5 ガードレール

- **force-* の Ruleset（`protect-main` / `protect-staging`。`phases/init/09_repo_rules.sh`）の必須チェックの名前は、ワークフローの「ジョブ名」だけ**（`required_status_check_names`（`lib/project.sh`）が正本: `対象ファイル確認`・`デプロイ検証`・`順序チェック`）。**`ワークフロー名 / ジョブ名` の形で登録すると、永久に満たされず、PR が BLOCKED になる**（2026-10-24 に、使い捨ての公開リポジトリで確認: ジョブ名だけ → CLEAN、`validate / 対象ファイル確認` と `WF / ジョブ名` の形 → BLOCKED。ワークフローの `name:` の有無は、関係ない）。ワークフローが reusable（呼び出し形式）からインライン形式に変わった（c632154。2026-03-28）とき、名前が更新されず、7 か月残っていた。ジョブ名を変えるときは、`required_status_check_names` も直す（`tests/test_sf-init.sh` の `test_required_checks_match_workflows` と、結合テスト X4-1 が、食い違いを検出する）。既存のプロジェクトは、`sf-init.sh --status`（`lib/diag.sh` の `_diag_rulesets`）が検出して、GitHub の画面での直し方を表示する（`site/admin/troubleshooting.html`）。無料プランの非公開リポジトリでは、Ruleset が効かないため、e2e では見えない。
- `main` のブランチ保護・Ruleset: `sf-tools` 自身は公開リポジトリのため、無料プランでも設定でき、**設定済み**（Ruleset `protect-main`: `deletion` / `non_fast_forward` / `pull_request`（承認者 0 人）。バイパスなし。2026-10-05。**2026-10-21 に、必須のステータスチェック `required_status_checks` を追加**。下の「必須チェック」を参照）。force-* のような Private リポジトリでは、`Upgrade to GitHub Pro or make this repository public` で設定できない。Actions は実行のたびに `sf-tools` の `main`（検証環境は `development`）を取得してコードを実行するため、`main` の書き換え権限の管理が重要。rr は PR 経由（`gh pr merge`）なので、削除禁止・強制 push 禁止・PR 必須の影響は受けない。ただし、必須チェックの影響は受ける（下記）
- そのため、`CLAUDE.md` 1.1 の運用ルール（mm / rr は明示された場合のみ、rr は検証報告が前提）で守る
- **必須チェック（2026-10-21・`protect-main` の `required_status_checks`。11 個）:** `shellcheck（警告以上）`・`全件テスト`・`全件テスト（macOS）`・`全件テスト（Windows・Git Bash 1/6）`〜`6/6`（6 個）・`結合テスト L1（ubuntu-latest）`・`結合テスト L1（macos-latest）`。値は、ワークフロー（`.github/workflows/test.yml`）の**ジョブ名**。1 つでも赤、または、まだ動いている間は、`main` にマージできない。`strict`（最新の `main` を取り込んでいない PR を止める）は、付けていない。
  - **e2e は、必須にしない**: e2e は、配布物が変わったときだけ動くため、必須にすると、動かない PR（文書だけの変更など）が永久に止まる。e2e は、「rr の前に、Claude が確認する」ルール（`CLAUDE.md` 1.2）で守る。
  - **rr の流れ**: PR 作成 → `gh pr checks <PR番号> --watch` で CI の完了を待つ（目安 約 11 分。実績 7〜20 分）→ マージ。
  - **ジョブ名・matrix の数（`test.yml`）を変えるときは、Ruleset も更新する**（必須チェックの名前が「存在しない」状態になり、マージが止まる）。確認: `gh api repos/tama-create/sf-tools/rulesets/24482827 --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'`
  - **取り消し**: Ruleset の設定（Settings → Rules → protect-main）から、「Require status checks to pass」を外す。変更前の内容は、2026-10-21 の作業ログにある（ruleset-before.json）。
- プランの変更、またはリポジトリを公開にできるようになった場合は、`main` に Required reviewers を設定すること

### 9.6 e2e（sf-init の通し検証の自動化）

実際の GitHub / Salesforce で `sf-init.sh` を Phase 1〜10 まで自動実行し、検証する（作ったものは、既定では残し、次回の前掃除で削除する）。`tests/e2e/` に置き、通常の `bash tests/run_tests.sh` には含めない（実環境を使うため）。安全ガードと部品は `tests/test_e2e.sh`（モック）で確認する。

**方式:** `sf-init.sh` 本体は変えず、外から標準入力と PATH の差し替えで操作する（本番のコードに近道を入れない）。

| 部品 | 役割 |
|---|---|
| `tests/e2e/lib.sh` | 共通関数。名前の判定、ガード、鍵一式の読み込み、削除、エイリアスの保存・復元、`e2e_make_input`（標準入力の台本） |
| `tests/e2e/run.sh` | 前掃除 → `sf-init.sh` の実行 → 確認 → 終了。既定では、終了時にテスト用のリポジトリなどを削除せず残す（あとから見返せる。次回の前掃除で削除）。`--cleanup`（終了時に削除）、`--resume`（前回残したリポジトリで、Hello World の部分だけを再実行。前掃除・sf-init・wf-metasync は行わない。ジョブ名は時刻付き。前回の残りの Hello World の Apex は、最初に削除する）、`--no-actions`（Actions の確認を省略）。`--keep` は、以前の名残り（何もしない） |
| `tests/e2e/cleanup.sh` | 削除。既定は一覧のみ、`--yes` で削除（確認で `delete` の入力が必要。`--no-confirm` で省略） |
| `tests/e2e/scenario.sh` | シナリオ方式（L2。設計は `doc/integration-test-plan.md` 11。**仕様の正本は `scenario.sh` の冒頭コメント。ここは要点だけ**）。`run.sh` が前回残したテスト用リポジトリ（最新の 1 つ。`e2e_find_latest_project`）、または `--repo force-e2e-日時`（手元に作業フォルダがない OS で、別の OS が作ったリポジトリを使う。名前の形式とオーナーの確認は同じ）に対して、名前で選んだシナリオだけを実行する（`--list`・`-y`）。実行の前後で、`main` の SHA・ブランチ・開いている PR の数を比べ、変わっていたら、後続を実行しない。結果は、成功 / 失敗 / 実行できない（成功に数えない）。書き込むシナリオは、開始の警告に書き込む内容を出し（`_scn_writes`）、終了時（中断を含む）に必ず戻す（`_scn_restore`）。シナリオ: `log-secrets`（Actions のログ・PR に秘密が出ていない。読み取りのみ）・`manual-delete`（Secret `SLACK_BOT_TOKEN`・Variable `SLACK_CHANNEL_ID` を消し、`sf-init.sh --status` が不足を示す → 戻す）・`update-secret`（B2。`sf-update-secret.sh` の「1) 秘密鍵」を同じ鍵で実行 → `SF_PRIVATE_KEY` の更新日時が進む。後のシナリオのワークフローが、上書きした鍵で JWT ログインできることも確かめる）・`sync-wf`（B4。管理者用のクローンの中だけで、`sf-sync-wf.sh --check` / 上書き / `--remove`）・`cross-os`（C2。GitHub から `{E2E_HOME_ROOT}/{E2E_OWNER}/e2e-xos.XXXXXX` に clone し、CRLF がない・フックが `~/sf-tools/hooks/` と同じで CR なし・`sf-sync-wf.sh --check` が成功。読み取りのみ）・`validate-fail`（壊れた Apex の PR → `wf-validate` が失敗・コメント → 直して成功。ブランチ `e2e-vf-時刻`。PR はマージせずに閉じる）・`dist-main`（Variable `SF_TOOLS_BRANCH` を一時的に消し、`wf-validate` のログに `git clone -b main`。rr の直後（配布物に差がないとき）だけ。ブランチ `e2e-dm-時刻`）・`metasync-diff`（B3。組織にだけ Hello World を作り、`wf-metasync` で main に入る）・`propagate-fail`（X4-5。main と staging に `e2e-propagate-conflict.txt` の違う内容 → `wf-propagate` が失敗・Slack 通知・staging は変わらない。2 層以上）・`restart-org`（A8。`sf-restart.sh` で staging の組織（エイリアス `sf-tools-e2e-restart-STG`）に切り替え、`sf-dryrun.sh` が新しい組織を使う → 戻す）。実行するスクリプトは、テスト用の環境変数（`E2E_SF_HOOK` / `E2E_SF_HOOKS_DIR` / `E2E_SF_SYNC_WF` / `E2E_SF_RESTART` / `E2E_SF_DRYRUN` / `E2E_SF_INIT` / `E2E_SF_UPDATE_SECRET`）で差し替えられる（`dist-main` が配布物の差を比べる sf-tools は `E2E_SF_TOOLS_GIT_DIR`）。**`push-guard`（`main` への直接 push の拒否）は、作れなかった**: テスト用の組織が無料プランの非公開リポジトリで、Ruleset が使えず（`sf-init` が「無料プランでは利用不可」と警告する）、使えたとしても、`protect-main` の迂回の許可（`bypass_actors`）に Admin が入っていて、e2e を実行する管理者は、拒否されない。Ruleset の効きは、公開リポジトリか有料プランでしか確認できない |
| `tests/e2e/bootstrap.sh` | 鍵一式（`~/.sf-tools-e2e/fixture.env`）の作成。最初の 1 回だけ。雛形は `fixture.example.env`。`--add-orgs`: 既存の鍵一式に、staging・develop の組織の認証 URL（`E2E_SFDX_AUTH_URL_STG` / `_DEV`）だけを追加する（ほかの段階と同じ組織は拒否）。`--refresh-orgs`: 登録済みの認証 URL（main・staging・develop）で、実際にログイン（`sf org login sfdx-url`）して有効性を確認し、**無効なものだけ**を、確認のうえ、ブラウザでログインし直して取り直す（Token などは変えない。取り直した組織が、ほかの段階と同じなら中断し、保存は、すべての確認の後にまとめて行う。無効なまま残したときは、非ゼロで終了）。リフレッシュトークンは、同じユーザーで、ログインを繰り返すと、古いものから失効する（e2e が `RefreshTokenAuthError` で失敗する） |
| `tests/e2e/doctor.sh` | e2e を動かせる環境かの確認（読み取りのみ。Windows・macOS・Linux・WSL 共通）。OS・Bash・openssl、コマンド（`git` / `gh` / `sf`（npm 版）/ `node` / `openssl`）、`gh` のログイン・`delete_repo`・`E2E_GH_USER` との一致、git の `credential helper`（無いと、https のクローンがパスワードを待って止まる。WSL・Linux）、git のユーザー名・メールアドレス（無いと、初回のコミットが `Author identity unknown` で失敗する）、鍵一式（有無・権限 600・必須の項目・認証 URL の形式・`E2E_HOME_ROOT`。**値は出さない**）、`generate_jwt_cert`（`sf-init` と同じ関数）で鍵（PKCS#1）と証明書（発行先が空でない）を作れるか、手元の sf-tools が `origin/development` と一致しているか。要対応があれば戻り値 1。新しい環境（Mac など）で `run.sh` の前に実行する |
| `lib.sh` の `e2e_record_line` / `e2e_os_label` / `e2e_openssl_label` | 検証の記録（9.7）の表の 1 行を作る。`run.sh` が、終わりに表示する（列: OS / Bash / openssl / コミット / 日付 / 結果。未コミットの変更があれば、コミットの欄に付記する。`--no-actions` などで確認を省いたときは、結果の欄に書く） |
| （層数対応: `run.sh` / `lib.sh`） | `--layout 1\|2\|3`: `e2e_make_input N`（Phase 5 の番号は、3 層 = 1・2 層 = 2・1 層 = 3。ログイン先の答えは段階の数だけ）。リポジトリの構成は、ブランチから判定（`TIERS`: develop → staging → main）し、`_hello_flow` が、段階の数だけ、`_hello_pr_flow`（同じブランチから、段階ごとの PR）を繰り返す。実行の取り違え防止: PR を作る前の最新の実行 ID（`e2e_latest_run_id`）を覚え、それより新しい実行だけを、その PR の実行とする（`e2e_wait_pr_run` の 4 番目の引数）。段階の指定: 環境変数 `E2E_TIER`（`e2e_sf_admin_login` / `e2e_apex_count` / `e2e_list_target_apex` / `e2e_delete_apex` などが、その段階の組織・エイリアス（`sf-tools-e2e-admin[-stg\|-dev]`）を使う）。`sf` の差し替えは、`--alias` の末尾（STG / DEV）で、段階の認証 URL を選ぶ。確認: 各段階のリリースで、その段階の組織にだけクラスができる（先の段階にはない）・`wf-propagate` で staging / develop に main が入る（`compare` の `ahead_by` = 0）・main の削除は、ほかの段階に及ばない。 |
| `tests/e2e/ci-notify.sh` | GitHub Actions 上だけで動く。`e2e.yml` の `notify` ジョブ（Windows・macOS のどちらかが失敗したときだけ動く）が、Slack（`chat.postMessage`。e2e がテスト用リポジトリの通知に使うものと同じ Bot Token・チャンネル）に、実行の URL・イベント・ブランチ・コミットだけを通知する。入力は、JSON を壊さないよう形式を確認し、不正なら通知しない。失敗の理由は、Slack の error コードだけ表示する |
| `tests/e2e/ci-mask.sh` | GitHub Actions 上だけで動く。e2e の実行の前に、組織の ID・ユーザー名・アクセストークン・My Domain の URL を調べ、`::add-mask::` で、公開ログに出ないようにする（3 つの組織にログイン → 値を登録 → ログアウト）。ログインできない組織は、表示して飛ばす（失敗にしない） |
| `tests/e2e/ci-fixture.sh` | GitHub Actions 上だけで動く。Secrets / Variables（環境変数）から、鍵一式（`~/.sf-tools-e2e/fixture.env`）を作る（`%q` で、記号・空白を含む値も、そのまま。権限 600）。必須の値が空なら、変数名だけを表示して失敗する（値は出さない） |
| `tests/e2e/shims/sf` | `sf org login web` だけを `sf org login sfdx-url`（認証 URL）に差し替える。他のコマンドは本物の `sf` に渡す |
| `tests/e2e/shims/code` | VS Code を開かない。`code .`（`sf-start.sh`）は何もせず、`--wait <ファイル>`（`sf-push.sh` のコミットメッセージ）は、`E2E_COMMIT_MSG`（既定 `e2e`）を書き込んで終わる |
| `tests/e2e/shims/git` | `run.sh --interrupt` の 1 回目だけ PATH の先頭に置く。`git push` で、引数に `main` を含むものを、1 回だけ（印のファイル `E2E_GIT_FAIL_MARK` ができるまで）終了コード 128 で失敗させ、あとは本物の git（`E2E_REAL_GIT`）に渡す。Phase 8 の初回コミットの push の失敗を、実環境で起こす |
| `tests/e2e/shims/browser` | `start` / `xdg-open` / `open` / `powershell.exe` / `wslview` の名前でコピーされ、ブラウザを開かない（WSL の `open_browser` は `powershell.exe` を使うため、WSL で e2e を動かすときに要る） |

**GitHub Actions での実行（`.github/workflows/e2e.yml`。設計は `doc/integration-test-plan.md` 12.5）:**
- Windows（Git Bash）で全部（`run.sh` は既定のまま。リポジトリを残し、シナリオに使う）、続けて macOS（標準の Bash 3.2）でクライアント側だけ（`--no-actions --no-add-tier --cleanup`）。同じ 3 つのテスト用組織を使うため、`needs` と `concurrency`（`group: e2e`・実行中は止めない）で、一列に動かす。どちらかが失敗したら、`notify` ジョブが Slack に通知する（`ci-notify.sh`）。
- 準備: `~/sf-tools` にリポジトリをコピーし、git の名前・`gh auth setup-git`・`npm install -g @salesforce/cli`、更新済みの印 `~/.sf-tools-last-update` を先に置く（使い捨てのサーバーは毎回「初回」になり、`sf-install.sh` が背景で起動する `sf-upgrade.sh` が、e2e の実行中に sf を入れ替えるため）。
- **ガード（`lib.sh` の `e2e_actions_allowed`）:** `e2e_guard_env` は、Actions 上では、①`E2E_ALLOW_ACTIONS=1`、②`GITHUB_WORKFLOW_REF` が `tama-create/sf-tools/.github/workflows/e2e.yml@refs/heads/(development|main)`、③`GITHUB_EVENT_NAME` が push・workflow_dispatch・schedule、のすべてがそろうときだけ通す（`GITHUB_*` は、ワークフローの書き手が上書きできない）。名前の形式・オーナーの一致・gh ユーザーの一致・削除の対象は、Actions 上でも同じ。ガードを通ったあと、`GITHUB_ACTIONS` と `CI` を外す（sf-tools の各スクリプトが、警告・確認を飛ばし、クライアント PC と違う動きにならないように。`run_tests.sh` と同じ）。
- **Secrets（Environment `e2e`。Deployment branches は development と main だけ。すべて Secrets。Variables は使わない）:** `E2E_GH_TOKEN`（Classic PAT: repo / workflow / admin:org / delete_repo）・`E2E_PAT_TOKEN`・`E2E_SLACK_BOT_TOKEN`・`E2E_SFDX_AUTH_URL`・`E2E_SFDX_AUTH_URL_STG`・`E2E_SFDX_AUTH_URL_DEV`・`E2E_OWNER`・`E2E_GH_USER`・`E2E_SLACK_CHANNEL_ID`。sf-tools は公開リポジトリで、ログが公開されるため、秘密ではない値（組織名・ユーザー名・チャンネル ID）も、Secrets にして、ログで伏せる。`E2E_OWNER`・`E2E_GH_USER`・`E2E_SLACK_CHANNEL_ID` も Secrets（2026-10-21 に Variables から移行済み。`e2e.yml` に `vars.` は無い）。
- **ログの公開対策（`tests/e2e/ci-mask.sh`）:** sf のログイン時の表示などに、組織のユーザー名・組織 ID・My Domain の URL が出る。これは、Secret に登録した値ではないため、GitHub は伏せない。e2e の実行の前に、`ci-mask.sh` が、3 つの組織（main・staging・develop）に一度ログインし、`sf org display --json` から ID（18 桁と 15 桁）・ユーザー名・アクセストークン・URL・ホスト名を調べて、`::add-mask::` で、以降のログで伏せる（調べたあとは、ログインを外す。値は表示しない）。画面に出す処理を足すときは、これが効くか確認すること。手元で e2e を動かすと、Actions の実行と、同じ組織を取り合うため、Actions に移したあとは、手元では動かさない。
- **シナリオ（L2）の自動実行:** Windows のジョブの最後に、`run.sh` が残したテスト用リポジトリ（`--add-tier` で staging まである）に対して、`scenario.sh -y log-secrets manual-delete update-secret sync-wf cross-os validate-fail metasync-diff propagate-fail restart-org` を動かす（`dist-main` は、「rr の直後だけ」の条件があるため、除く）。macOS のジョブは、続けて、Windows が残したリポジトリの名前（Windows のジョブの `outputs.repo`）で、`scenario.sh -y --repo <名前> cross-os` を、自分の `run.sh`（開始時に、残っているテスト用リポジトリをすべて削除する）より前に動かす（OS 混在の確認）。`update-secret` を `validate-fail` などの前に置くのは、上書きした秘密鍵で、あとのワークフローが JWT ログインできること（形式が壊れていないこと）を、確かめるため。
- **起動:** 配布物（`bin/` `lib/` `phases/` `hooks/` `templates/` `config/`）・`tests/e2e/`・`e2e.yml` が変わった `development` への push。**週 1 回（月曜 03:00 日本時間・`schedule`）、`main` に対して**（コードを変えていない間の、外側の変化の見張り。schedule は既定のブランチのワークフローで動く。公開リポジトリは、60 日間活動がないと、定期実行が止まる）。手動（`workflow_dispatch`）も使える（手動実行のワークフローは、既定のブランチ（`main`）にあるものしか起動できない。`e2e.yml` は `main` に入っている。push の起動は、どのブランチでも使える）。

**中断→再開の確認（`run.sh --interrupt`）:** `sf-init` を、わざと Phase 8 で失敗させ、「続きをやる」で再開してから、いつもの確認（Secret・Variable・ブランチ・ワークフロー・Actions・Hello World）を行う。1 回目: `_interrupt_first_run`。git の shim（`shims/git`）で、main への push を 1 回だけ失敗させ、止まった時点の状態（リポジトリ・main・進捗）を `MID_*` に記録する（再開すると変わるため）。2 回目の入力: [オーナーの選択・XXXX・確認] → 管理者向けの警告の確認 `Y` → 「続きをやる」`1` → Phase 10 のログイン先（段階の数だけ `1`）。確認: 1 回目が失敗した・shim が push を止めた・失敗の画面が「続きをやる」を案内した・リポジトリはある・main はない・進捗は 7・PAT / Slack Token / 認証 URL が出ていない・再開の画面に「前回のセットアップは」が出た・初回コミットが 1 つ。`--resume` とは同時に指定できない。共通の確認は `read_key` が 1 文字ずつ読むことに注意（改行も 1 回の読み取りで、空なら再入力になる）。

**テスト用の名前:** プロジェクト `e2e-YYYYMMDD-HHMMSS` → リポジトリ `force-e2e-YYYYMMDD-HHMMSS` → 外部クライアントアプリ `SF_TOOLS_force_e2e_YYYYMMDD_HHMMSS`。毎回別の名前なので、前回の削除を待たずに実行できる。

**確認する内容:** Secret / Variable / ブランチ / ワークフローの存在、`SF_TOOLS_BRANCH=development`、`SLACK_CHANNEL_ID` の一致、トークンが出力・ログに出ていないこと、`wf-metasync` の成功（`workflow_dispatch` で起動し、完了を待ってから Hello World の流れに進む。並行すると、組織からの取得（retrieve）と Hello World のデプロイが重なり、`MetadataTransferError` で失敗した（2026-10-05 の実機））、Hello World のリリース・削除（下記）。

**Hello World のリリース・削除（`_hello_flow`）:** 実際の PR の流れで、`wf-validate` → マージ → `wf-release` を通す（`wf-release` の途中のステップ（JWT ログイン・公開 `sf-tools` の clone）と Slack 通知（`"ok":true`）、成功の通知）。
- 部品は `tests/e2e/lib.sh`: `e2e_gh_pr_create` / `e2e_gh_pr_merge` / `e2e_wait_pr_run`（`gh run list --workflow … --branch … --event pull_request` で実行を探し、完了まで `E2E_POLL_SEC` 秒（既定 5）おきに確認。起動待ちは `E2E_RUN_FIND_TRIES` 回（既定 24）、完了待ちは `E2E_WF_TIMEOUT` 秒（既定 1200）。本体は `lib/verify-common.sh` の `verify_wait_pr_run` で、`VERIFY_*` の名前でも指定できる）。これらは `_e2e_check_repo` で、オーナー（`E2E_OWNER`）とテスト用リポジトリの名前の形式が一致しないと動かない
- リリース（通常の運用と同じ道。`_hello_local_job` に `_hello_write_release` を渡す）: `e2e_run_sf_cmd` で、`sf-job.sh`（ブランチ `e2e-hello-時刻`（`JOB_RELEASE`。`--resume` でもぶつからないよう、毎回別の名前）の作成・clone・`sf-start.sh`。標準入力は `ジョブ名 / Y / エイリアス（E2E_JOB_ALIAS） / ログイン先 2`）→ `e2e_wait_sf_install`（`sf-start.sh` が背景で動かす `sf-install.sh` の完了を、`sf-tools/logs/sf-install.log` の完了メッセージで待つ。`E2E_INSTALL_TIMEOUT` 秒、既定 600。`npm install` も、通常の運用と同じく動く）→ Hello World の 4 ファイル（`lib/verify-common.sh` の `verify_hello_paths` / `verify_hello_content_for`。`verify.sh` と共有）と `deploy-target.txt`（`[files]` と `[members]`）を書く（開発者の手作業にあたる部分。`remove-target.txt` は、`sf-install.sh` が作った雛形のまま）→ `sf-dryrun.sh`（`@isTest` の検出と `--tests` を確認）→ `sf-push.sh`（commit・push。`pre-push` フックが動く）。`e2e_run_sf_cmd` は、テスト用の作業フォルダ（`{E2E_HOME_ROOT}/{E2E_OWNER}/e2e-…`）の中だけで動き、出力を `${E2E_TMP}/{ラベル}.out` に残し、失敗したら末尾を表示する。差し替え（`tests/e2e/shims/`）は、`sf`（`org login web` を認証 URL に）、`code`（`code .` は何もしない。`--wait <ファイル>` は、`E2E_COMMIT_MSG` を書き込む）、ブラウザ。`sf-launcher.sh`（対話のメニュー）は、`SF_LAUNCHER_ACTIVE=1` で起動しない。そのあと、`gh` で PR を作り、`wf-validate` → マージ → `wf-release`
- どちらのジョブも、`deploy-target.txt` と `remove-target.txt` の両方が、クローンにある（`sf-install.sh` が雛形から作る。書き換えるのは、使う側だけ）（`sf-release.sh` は、どちらかが無いと止まる。通常は `sf-install.sh` が雛形から作る）。使わない側は、`sf-install.sh` が作った空の雛形（`[files]` と `[members]` のみ）のまま。`wf-validate` の「対象ファイル確認」は、実質の中身がある側だけを見る（2026-10-05 の初回の実機で、`remove-target.txt` が無く検証が失敗した）
- 削除（リリースと同じ道。`_hello_cycle` に、`_hello_write_remove` を渡す）: `sf-job.sh`（ブランチ `e2e-hello-delete-時刻`（`JOB_DELETE`）。新しいクローン）→ `sf-tools/release/<そのブランチ>/remove-target.txt`（`ApexClass:SfToolsE2eHelloTest` / `ApexClass:SfToolsE2eHello`）を書く（`deploy-target.txt` は雛形のまま）→ `sf-dryrun.sh` → `sf-push.sh` → PR → マージ。`@isTest` の検出の確認は、リリースだけ
- そのほかの sf-tools のコマンド: リリース後に、リリースしたジョブのクローンで、`sf-next.sh`（出力に「マージ済み」。質問には N で答える。`_hello_sf_next`）と、`sf-deploy.sh -t main --no-open`（予約名 `main` の組織への、ローカルからの強制リリースの拒否。開発者の本物の `prod` などを避けるため `main` を使う。終了コード 0 以外・「共有環境のため」の文言・`project deploy start` が出ないこと。`e2e_run_sf_cmd_refused`・`_hello_deploy_refused`）を確認する
- ワークフローの結果（`conclusion`）とステップの結果の読み取り（`e2e_run_conclusion` / `e2e_step_conclusion`）は、空のときだけ、`E2E_POLL_SEC` 秒（既定 5）おきに、最大 `E2E_CONCLUSION_TRIES` 回（既定 6）やり直す。完了した直後に、API の反映の遅れや `gh` の一時的な失敗で空になり、成功した実行が FAIL になった（2026-10-05 の実機）。`failure` などの値は、やり直さず、そのまま使う（本当の失敗を、成功にしない）
- ワークフロー（`wf-validate` / `wf-release` / `wf-propagate` / `wf-metasync`）が失敗したら、ログを表示したあと、**1 回だけ** `gh run rerun --failed` で再実行する（`_run_ok`・`e2e_rerun_and_wait`。開発者が GitHub の画面で「Re-run」を押す操作と同じ。再実行の前後の試行番号（attempt）を見て、完了を待つ）。再実行で成功したら PASS にするが、警告を表示し、結果にも「再実行で成功したワークフローが N 件」と出す（一時的な失敗の頻度が、あとから分かるように）。再実行でも失敗したら FAIL。Salesforce や通信側の一時的なエラー（`MetadataTransferError` など。2026-10-05 の実機で、wf-metasync と wf-validate で各 1 回）で、e2e 全体が失敗するのを防ぐ。`sf-release.sh` 本体には、再試行を入れていない（成否は終了コードだけで判定する方針。検証が失敗するたびに再実行すると、本当の失敗でも時間が倍になるため）
- **コードレビュー（2026-10-06）で直したもの:** (1) sf のエイリアスの保存（`e2e_alias_snapshot`）は、`sf alias list` が失敗したら、空の一覧を保存せず中断する。復元は、保存成功の目印（`.ok`）がないとき、`sf alias list` が失敗したときは、何も外さない（空の保存のまま復元すると、開発者の本物の `prod` などを、すべて外してしまうため）。 (2) 掃除（`e2e_cleanup_all`）は、管理用ログインに失敗しても、ローカルの掃除を続け、失敗として終わる（Salesforce 側は `_e2e_cleanup_salesforce` に分けた）。 (3) `_dispatch_workflow` は、起動の前の最新の実行 ID を覚え、それより新しい実行だけを、起動した実行とみなす（古い実行の取り違えを防ぐ）。起動に失敗したら、実行を探さない。 (4) run.sh の `gh` は、すべて `_e2e_gh`（時間の上限付き）を通す。 (5) push の一致（`_pushed_to_remote`）は、どちらかが空（読めない）なら、一致とみなさない。 (6) `e2e_run_sf_cmd_refused` は、終了コード 125〜127（実行そのものの失敗）を、拒否とみなさない。拒否の確認は、予約名 `main` で行う。 (7) 使わなくなった `e2e_gh_branch_create` / `e2e_gh_file_put` / `e2e_empty_target_text` と、そのテストを削除した。 (8) 秘密の伏せ字は、`_e2e_mask_line` に一本化した。 (9) `e2e_apex_count` のエラー出力の一時ファイルの名前を、掃除の対象の形（`e2e-run.XXXXXX`）にした。 (10) 直接実行するコマンド（mkdir / cp / rm）に、`run` 不使用の理由のコメントを付けた（CLAUDE.md 2.1）
- **止まったのか、動いているのか分かるように:** `e2e_run_sf_cmd` は、`E2E_HEARTBEAT_SEC` 秒（既定 30）おきに、経過時間を表示し、`E2E_CMD_TIMEOUT` 秒（既定 1200）を超えたら、打ち切る（終了コード 124、「時間切れ」と表示）。run.sh は、各段階の終わりに、`経過時間: N 分 M 秒` を表示する
- **管理者用フォルダ・対話・`--add-tier` の確認（2026-10-16 追加。手動の検証を、e2e に置き換えた）:**
  - `sf-init.sh` は、既定では**引数なしの対話**で実行する。先頭に、オーナーの選択 → XXXX の入力 → 確認の入力を足す（`e2e_make_identity_input OWNER XXXX`。オーナーの候補は `gh_owner_candidates admin` と同じ。複数なら位置の番号、1 つなら番号なし、なしならオーナーを入力）。`--with-args` で、引数 `--owner` / `--project` に切り替える。`sf-job.sh` も、既定は引数なし（作業フォルダの下のクローンの git remote から決まる。出力の「このフォルダの下のクローンから取得」で確認する）。
  - `sf-init` のあとの確認（新しく作ったときだけ。`--resume` の前回分は、古い形のことがある）: `admin/force-XXXX` ができた / 完了後に、状態ファイル（`.sf-init-XXXX.env` / `.progress`）が消えている / 完了の印（クローンの `git config sf-tools.setup-complete`）がある / 古い形のフォルダ（`init` / `init-*`）がない / クローンが `admin` ブランチ（ローカル）/ GitHub に `admin` がある / `origin/admin` を追跡 / 完了画面の案内（「ローカルと GitHub の両方」「`main` から古くなる」。対話のときは、XXXX だけ入力の案内も）/ `sf-sync-wf.sh --check` が `admin` で実行でき、`main`（保護ブランチ）では断られる（確認のため一時的に `main` に切り替え、`admin` に戻す）。
  - **最初のメタデータの同期の確認**（`sf-init` のあと）: 完了直後のクローン（`admin` ブランチ）に、メタデータのファイル（`.gitkeep` 以外）が入っている / `main` に「定期更新」のコミットがある / ローカルの `main` が `origin/main` と一致 / 完了画面に「同期済みです」。
  - `--add-tier`（`_add_tier_check`）: 新しく作った**1 層**のリポジトリで、鍵一式に staging の組織があるとき、**Hello World の確認のあと**（先に行うとリポジトリが 2 層になり、リリースの確認の対象が変わるため）に、管理者用のクローン（`admin` ブランチ）で `sf-init.sh --add-tier staging`（入力: `Y` → ログイン先 `1`）を実行する。確認: コマンドの成功 / 終わったあとも `admin` ブランチ / `staging` ブランチ / Secret・Variable（`*_STG`）/ `branches.txt` を更新する PR / `main` へ直接 push していない（`main` の SHA が変わらない）。約 4 分。`--no-add-tier` で省略できる。
  - **起動のしかた（Windows）:** 標準の Git Bash（`C:\Git\bin\bash.exe -l`。`MSYSTEM=UCRT64`）で起動する。`C:\Git\usr\bin\bash.exe`（`MSYSTEM=MSYS` / `MINGW64` にしても）は、`openssl` が MSYS 版になり、`sf-init` の `-subj "//CN=…"`（Git Bash の Windows 版 `openssl` 向けの書き方）が読み飛ばされて、Phase 10 の証明書の生成で失敗する（コードの不具合ではない）。`gh` は、鍵一式の `E2E_GH_USER`（テスト用の組織の管理者）のトークンを、`GH_TOKEN` に設定して実行する（gh のアクティブなアカウントは書き換えない）。確認の質問には `Y` を渡す。所要時間は約 30 分。
  - **e2e の確認のコメントの書き方:** `chk "説明" \` の次の行に、コメントを書かない（行の継続の途中のコメントは、後ろのコマンドごと消える。以前、`sf-job.sh` の確認が、常に PASS になっていた）。
- 組織側の確認は `e2e_apex_count`（SOQL `SELECT COUNT() FROM ApexClass WHERE Name = '…'`。`totalSize` を読む）。前後で 0 → 1 → 0 になること
- 件数の確認の前に、管理用ログイン（`e2e_sf_admin_login`）を、やり直す（リリース後・削除後）。2 回目の `sf-job.sh`（`sf-start.sh`）が、同じ組織の接続を `sf org logout` してログインし直し、同じユーザーの認証は、エイリアスが違っても共通の保存先を使うため、問い合わせ用の接続が、使えなくなったと見ている（2026-10-06 の実機で、削除は成功したのに、削除後の件数の確認が失敗した。原因は推定）。`e2e_apex_count` は、失敗したとき、`sf` のエラーの要点を警告として表示する（次回から、原因が分かる）
- 後掃除（`e2e_cleanup_all`。前掃除、`--cleanup`、`cleanup.sh` で動く）は、組織に残った `SfToolsE2eHello` / `SfToolsE2eHelloTest` も、一覧（`e2e_list_target_apex`。名前の完全一致のみ）→ 削除（`e2e_delete_apex`。削除用のデプロイ）→ 再取得で確認する。一覧の取得失敗は、ECA と同様に「対象なし」とせず、失敗として記録する
- `gh` の呼び出し（`_e2e_gh`）は、`timeout`（`E2E_GH_TIMEOUT` 秒。既定 120）と標準入力の遮断付き。応答しない `gh` で、e2e が止まり続けないようにする（Git Bash で、`gh` の起動前に止まる現象が一度あったが、その場合は、この上限では防げない）
- ワークフロー（`wf-validate` / `wf-release` / `wf-metasync`）が失敗したら、後掃除の前に、失敗したステップのログの末尾（`E2E_FAIL_LOG_LINES` 行。既定 40）を表示する（`e2e_show_run_failure`。鍵一式の値は `***` に置き換える）。リポジトリは既定で残る（`--cleanup` のときは消える）が、その場で原因を追えるようにするため
- マージ時には `wf-propagate`（main へのマージ）も動く。1 層（既定）の e2e のリポジトリは `main` のみで `staging` / `develop` がないため、スキップして成功になること（`wf-propagate.yml` は、ブランチがなければスキップする。以前は `git checkout staging` が失敗して、赤い ✗ になっていた）を確認する。`wf-sequence` は、PR を開いたときに動き、成功する

**削除の安全ガード:**

- 削除対象は、名前の形式（上記のタイムスタンプ付き）が一致するものだけ。`SF_TOOLS`、`force-test-win` などは対象外（`e2e_is_target_*`）
- オーナーは、鍵一式の `E2E_OWNER` のみ。gh のログインユーザーが `E2E_GH_USER` と一致しないと動かない
- `e2e_guard_env` を通らないと、削除系の関数は動かない（`E2E_GUARD_OK=1`）。GitHub Actions 上では、専用ワークフロー（e2e.yml）以外からは動かない（上の `e2e_actions_allowed`）
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

**wf-sequence の確認（2 層以上のとき。`run.sh` の `_hello_flow` / `_sequence_pr_check` / `_hello_pr_flow`）:** 1 層では、前の段階がなく、順序チェックが成り立たないため、行わない。①リリースの PR（staging・main へ）は、順序どおり: 実行が成功し、PR に警告のコメント（目印 `sf-tools:sequence`）が付かない（削除の PR は、main へ直接出す仕様で、順序外の警告が付くのが正しい動きのため、対象外）。②リリース用のブランチを、前の段階にマージしないまま main へ PR（順序外）: 実行は成功（警告のみで、止めない）し、PR に「にまだマージされていません」のコメントが付き、Slack の通知（`"ok":true`）が成功する。③最初の段階（develop など）をリリースしたあと、その環境ブランチから main へ直接 PR: 実行が失敗し、「環境ブランチからの PR は、許可されていません」のコメントと Slack の通知が付く（この時点で、環境ブランチは main より進んでいるため、PR を作れる）。②③の PR は、**マージせずに閉じ**、走り出した検証（`wf-validate`）を `e2e_cancel_pr_runs` で取り消す（push のイベントで起動したものは、対象外）。部品（`lib.sh` の `e2e_gh_pr_close` / `e2e_pr_comment_has` / `e2e_pr_comment_absent` / `e2e_cancel_pr_runs`）は、モックの単体テストがある。

**前提と限界:**

- 台本（`e2e_make_input`）は、`sf-init` の質問の順番に依存する。質問を変えたら、台本も直す。`tests/test_sf-init.sh` の `test_e2e_input_sequence`（モック）が、ずれを検知する
- Token の作成と、テスト用組織への最初のログインは自動化できない（`bootstrap.sh` で 1 回だけ手動）
- **クライアント PC としての通しの検証が済んでいるのは、Windows（Git Bash）・macOS・WSL（Ubuntu）**（9.7）。Linux は、サーバー（GitHub Actions）としてだけ使う想定で、ワークフローは e2e で確認している。動かす前に `doctor.sh` で環境を確認する。macOS は、`openssl`（LibreSSL）・`stat`・`base64`・`sed` などの差に注意する（`-subj` / `-traditional` は対応済み）。`sf` は npm 版が前提（`sf-init.sh` の `check_sf_cli` が確認する）。`run.sh` / `cleanup.sh` / `bootstrap.sh` も、冒頭の `check_sf_cli` で、終了コードが 0 でなければ中断する。e2e の `sf` の成否も、すべて終了コードで判定する（回避用の `E2E_SF_REDIRECTED` は廃止）
- テスト用組織は、本番または Developer Edition（Sandbox ではない）
- リポジトリの削除には、`gh` の `delete_repo` の権限が要る（`gh auth refresh -h github.com -s delete_repo`）

### 9.7 検証済み環境の記録

**原則: 「検証済み」と書くのは、実際に動かした環境だけ。** README（3.1 動作環境）と文書サイト（`site/guide/install.html`）の「動作環境」の表は、ここの記録と一致させる。動かしていない環境は「未検証」と書く（目標は、すべての OS で動くこと。未検証の環境は、検証して、この表に足していく）。

**記録のしかた:** e2e（`tests/e2e/run.sh`）は、終わりに、表の 1 行（`e2e_record_line`）を表示する。**成功したら**、その行を、下の表に追記し、README と `site/guide/install.html` の表を更新する。新しい環境（Mac など）では、先に `bash tests/e2e/doctor.sh` で環境を確認する。単体テストの結果は、GitHub Actions（`test.yml`）の実行結果が、e2e は `e2e.yml` の実行結果が根拠になる（`gh run list --workflow test.yml` / `--workflow e2e.yml`）。

| 環境 | Bash | openssl | コミット | 日付 | 確認の種類と結果 |
|---|---|---|---|---|---|
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.x | OpenSSL 3.5（`/ucrt64/bin/openssl`） | 5344f40 | 2026-10-18 | e2e: 119 件成功 / 0 件失敗（1 層・既定。`--add-tier` の確認を含む） |
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.3.15 | OpenSSL 3.5.9 | 1aa67b3 | 2026-10-19 | e2e: 119 件成功 / 0 件失敗（1 層。`sf-push` の変更後の確認。`--add-tier` の確認を含む） |
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.3.15 | OpenSSL 3.5.9 | fed6180 | 2026-10-19 | e2e: 119 件成功 / 0 件失敗（1 層。結合テスト L1 の追加分と、見つかった不具合 4 件の修正後の確認。`--add-tier` の確認を含む。43 分 41 秒） |
| Windows（GitHub Actions の `windows-latest`。`e2e.yml`） | 5.3.15 | OpenSSL 3.5.9 | 4ec3c92 | 2026-10-21 | e2e: 119 件成功 / 0 件失敗（1 層。`--add-tier` の確認と、サーバー側のワークフローの確認を含む。21 分 23 秒） |
| macOS（GitHub Actions の `macos-latest`・arm64。`e2e.yml`） | 3.2.57 | OpenSSL 3.6.5 | 4ec3c92 | 2026-10-21 | e2e: 56 件成功 / 0 件失敗（1 層。`--no-actions --no-add-tier`。クライアント側のみ。4 分 39 秒） |
| Windows・macOS・Linux（GitHub Actions の `windows-latest` / `macos-latest` / `ubuntu-latest`） | 5.x / 3.2 / 5.x | — | 86670c8 | 2026-10-20 | 全件テスト・shellcheck・結合テスト L1 が、すべて成功（全 11 ジョブ）。Windows は `--shard` の 6 ジョブに分け、全体 11 分 24 秒（分ける前は約 21 分） |
| Windows・macOS・Linux（GitHub Actions の `windows-latest` / `macos-latest` / `ubuntu-latest`） | 5.x / 3.2 / 5.x | — | 1aa67b3 | 2026-10-19 | 全件テスト・shellcheck・結合テスト L1（`tests/test_integration.sh`）が、3 つの OS ですべて成功 |
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.3.15 | OpenSSL 3.5.9 | a22fe4c | 2026-10-20 | e2e シナリオ（`tests/e2e/scenario.sh`）: `log-secrets` 13 件・`manual-delete` 15 件・`validate-fail` 13 件・`metasync-diff` 18 件が成功。`dist-main` 10 件は、rr の直後（`origin/main` と `origin/development` の配布物に差がない）の `a22fe4c` で成功（配布版で sf-tools の `main` が使われる）。すべて実環境（テスト用の組織・リポジトリ）で、終了時に元の状態へ戻したことを確認 |
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.3.15 | OpenSSL 3.5.9 | 33acf54 | 2026-10-20 | e2e: 119 件成功 / 0 件失敗（1 層。`sf-push` が、detached HEAD・保護ブランチの上では、コミットする前に止める変更の後の確認。`--add-tier` の確認を含む。37 分 54 秒）。あわせて、`run.sh --interrupt --no-add-tier`（`sf-init` を Phase 8 の push でわざと失敗させ、「続きをやる」で再開）: 121 件成功 / 0 件失敗（29 分 24 秒。`sf-push` の変更の前の実行） |
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.3.15 | OpenSSL 3.5.9 | b0eb76a | 2026-10-20 | e2e シナリオ `dist-main`: 10 件成功（rr の直後。配布版で sf-tools の `main` が使われる。128 秒） |
| Windows 11（Git Bash。`C:\Git\bin\bash.exe -l`） | 5.3.15 | OpenSSL 3.5.9 | b0eb76a | 2026-10-20 | e2e シナリオ: `propagate-fail` 11 件（46 秒）・`restart-org` 10 件（221 秒）が成功（`propagate-fail` は main・staging にファイルを置いて削除、`restart-org` は接続先を staging の組織に切り替えて元に戻す。sf のエイリアスは、実行前の一覧に戻ったことを確認） |
| Windows・macOS・Linux（GitHub Actions の `windows-latest` / `macos-latest` / `ubuntu-latest`） | 5.x / 3.2 / 5.x | — | fed6180 | 2026-10-19 | 全件テスト・shellcheck・結合テスト L1（残りの追加分を含む）が、3 つの OS ですべて成功（全 7 ジョブ） |
| Windows（`windows-latest` の Git Bash） | 5.x | — | 1fe7ed7 | 2026-10-18 | 単体テスト全件成功（GitHub Actions） |
| macOS（`macos-latest`） | 3.2（標準の `/bin/bash`） | — | 1fe7ed7 | 2026-10-18 | 単体テスト全件成功（GitHub Actions） |
| Linux（`ubuntu-latest`） | 5.x | — | 1fe7ed7 | 2026-10-18 | 単体テスト・shellcheck 全件成功（GitHub Actions） |
| WSL（Ubuntu・WSL2） | 5.2 | — | da9622b | 2026-10-18 | 単体テスト 2237 件成功（手元の `run_tests.sh`。Git Bash から WSL に自動で移る） |
| macOS 27.0.1（Apple silicon。Mac mini の実機） | 3.2.57（標準の `/bin/bash`） | LibreSSL 3.3.6 | f60a79a | 2026-10-18 | e2e: 119 件成功 / 0 件失敗（1 層・既定。`--add-tier` の確認を含む。12 分 31 秒） |
| WSL（Ubuntu 24.04.1 LTS） | 5.2.21 | OpenSSL 3.0.13 | c594ebd（＋ `doctor.sh` の確認項目と `powershell.exe` の差し替えの変更） | 2026-10-18 | e2e: 119 件成功 / 0 件失敗（1 層・既定。`--add-tier` の確認を含む。17 分 5 秒）。WSL 用の `gh`・`sf`（npm 版 2.154.4）を、ホームに導入。`git` の認証と作者は、環境変数で渡した |
| WSL（Ubuntu 24.04.1 LTS） | 5.2.21 | OpenSSL 3.0.13 | 850bf23（＋ wf-sequence の確認の追加ほか） | 2026-10-19 | e2e: 181 件成功 / 0 件失敗（**3 層**: main + staging + develop。25 分 51 秒）。develop → staging → main の段階別リリース（各段階の組織にだけクラスができ、先の段階の組織には入らないこと）、main へのリリース後に `wf-propagate` が develop・staging に main の最新を反映したこと、**`wf-sequence` の 3 つの動き**（①順序どおりの PR は成功し、警告が付かない ②順序外の PR は、警告のコメントと Slack 通知で、止めない ③環境ブランチからの直接の PR は、失敗し、⛔ のコメントと Slack 通知）を確認。②③の PR は、マージせずに閉じた。（同日の 1 回前の 3 層の実行は、`wf-sequence` の確認を含まず、161 件成功） |
| Linux（GitHub Actions の `ubuntu-latest`。サーバー） | 5.x | — | 5344f40 / f60a79a / c594ebd 時点の development | 2026-10-18 | ワークフロー wf-validate（検証）・wf-release（リリース）・wf-metasync（メタデータ同期）が、上の 3 回の e2e の中で、実際の Salesforce に対して成功。wf-propagate は、1 層では実行・完了（反映先なし）、3 層（WSL の行）では、develop・staging への反映まで確認。wf-sequence は、3 層（WSL の行）で、順序どおり・順序外・環境ブランチからの PR の 3 つの動きを確認 |
| Linux をクライアント PC として使う | — | — | — | — | 想定しない（対象外。WSL の Ubuntu は、上のとおり確認済み） |

> **WSL（Ubuntu）の検証で分かったこと（初回の 3 回は失敗。4 回目に全件成功）:** ①`git` に GitHub の認証の仕組み（credential helper）が無く、https のクローンが、パスワードを待って 22 分止まった（→ `doctor.sh` が検出。e2e には `GIT_CONFIG_*` の環境変数で渡す。`GIT_TERMINAL_PROMPT=0` で、待たずに失敗させる）。②`git` のユーザー名・メールアドレスが無く、初回のコミットが失敗した（→ `doctor.sh` が検出。e2e には `GIT_AUTHOR_*` / `GIT_COMMITTER_*` で渡す）。③WSL の `open_browser` は `powershell.exe` を使うため、e2e の差し替えに加えた（`shims/browser`）。④1 回だけ、Hello World の `sf-dryrun.sh` が、メッセージなしの `Error (1)` で失敗したが、同じ条件で手動で 3 回実行して、すべて成功し、4 回目の通しも成功した（原因は特定できていない。Salesforce 側の一時的な失敗の可能性）。WSL では、`sf` と `gh` が Windows 側のものを使えないため、WSL 用を、`sudo` なしで、ホームに入れた（`gh` は、チェックサムを確認して `~/.local/gh`、`sf` は nvm の `npm -g`）。

> Windows の Git Bash は、標準の Git Bash（`C:\Git\bin\bash.exe`。`openssl` が `/ucrt64/bin`）で動かす。`C:\Git\usr\bin\bash.exe`（MSYS 版の `openssl`）では、証明書の発行先が空になり、Phase 10 が失敗する（`doctor.sh` が検出する）。

### 9.8 文書サイト（`site/`）

利用者向けの文書（使い方・管理者向けの手順・リファレンス・設計）は、HTML の文書サイトに置く。`README.md` は、概要と、サイトへの入口だけにする（以前の README の 9 章、sf-tools の開発者向けの手順は、`doc/dev-guide.md`）。AI 向け（`CLAUDE.md`・本書）と、テストが読み込む文書（`doc/integration-test-plan.md`）は、Markdown のまま。**実装・AI への指示に使う設計書（`doc/` の `jwt-auth-spec.md`・`wf-distribution-strategy.md`・`wizard-ux-design.md`・`sf-logwatch-design.md`・`sf-cicd-strategy.md`）も、Markdown のまま**（無理に HTML にしない。公開して価値のあるものだけを、サイトに載せる）。`sf-cicd-strategy.md` の要点は、読み物として `site/design/cicd.html` にある（設計を変えたときは、両方を直す）。

- **構成**: `site/index.html`（トップ）・`site/guide/`（使い方ガイド・用語集: `install`・`basics`・`daily`・`glossary`）・`site/admin/`（管理者ガイド: `setup`・`maintenance`・`secrets`・`workflows`・`verify`・`troubleshooting`）・`site/reference/`（リファレンス: `commands`・`commands-dev`・`commands-auto`・`target-files`・`structure`）・`site/design/`（設計と背景: `cicd`）。ページの一覧の正本は、`site/assets/site.js` の `NAV`。共通の部分は、`site/assets/style.css`（スタイル。ダークモード・スマホ対応）と `site/assets/site.js`。ビルドの手順は、ない（手書きの静的な HTML）。
- **ページの足し方**: ① `<head>` と骨組み（`<header id="top">`・`<nav id="side">`・`<main id="doc" class="doc">`・`<aside id="toc">`・`<footer id="foot">`・`site.js` の読み込み）を、既存のページと同じにする。② `<body data-root="...">` は、`site/` からの深さに合わせる（直下は `""`・1 階層下は `"../"`）。③ **`assets/site.js` の `NAV` に 1 行足す**（左の目次・前後のリンクは、ここだけで決まる。`h` がない項目は「準備中」と表示される）。コード中の `<` は、`&lt;` にする。④ **見出しの番号（大項目 `1.`・中項目 `1.1`・小項目 `1.1.1`）は、手で書かない**（`site.js` が h2・h3・h4 に自動で付ける）。階層は飛ばさない（h2 の次は h3、h3 の次は h4）。 ⑤ **囲み**（`<div class="box 種類">` + `<div class="title">題</div>`）は、種類で、アイコンが自動で付く（通常 = 💡、`warn` = ⚠️、`danger` = 🛑、`ok` = ✅、`next` = 👉、`admin` = 🔑 管理者専用）。題は、必ず付ける（`tests/test_site.sh` が確認する）。小さな印は `<span class="badge safe">🔍 読み取りのみ</span>`。言葉は、`site/guide/glossary.html`（用語集）にそろえる（管理者 = プロジェクト管理者・リリース = デプロイ・段階 = 環境）。
- **図の足し方**: 図は、基本は、HTML と CSS だけで描く（ダークモード・スマホ幅に合う）。**例外として、作者が用意した画像（`site/assets/*.png`。ロゴ入りの全体図 `system-overview.png` など）を、`<figure class="photo">` の中に、`<img>`（代替文字 `alt` 必須）と `<figcaption>` つきで載せてよい**。画像は、ダークモード・スマホ幅・文字のコピーに弱いので、同じ内容の HTML/CSS の版を、折りたたみ（`<details>`）で併記する。画像は、PIL などで 256 色に減らして、500KB ほどに収める。`<figure class="diagram">` の中に、①流れ図 `.flow`（`.node` と `.arrow` を交互に並べる。箱の色は `admin`・`dev`・`auto`・`ok`・`warn`。スマホ幅では縦に並ぶ）、②扇形 `.fan`（1 つの元から複数の行き先）、③区分け `.phases`（`.phase.p1`〜`p3`。人の操作がある手順は `li.you`）、④入れ子の箱 `.nest`（フォルダの構成）、⑤ターミナルの画面の見本 `.term` を置く。**`<figcaption>` で、何の図かを必ず書く**。定義は `site/assets/style.css`。`tests/test_site.sh` が、説明文の有無と、箱の色の種類を確認する。**開発者向けのページは、ランチャー（`sf-launcher.sh`）を中心に書く**（コマンドは、直接打つ場合として併記する）。
- **テスト**: `bash tests/run_tests.sh test_site.sh`（`--changed` は、`site/*`・`pages.yml` の変更で選ぶ）。確認するのは、決まった書き出し（doctype・title・`data-root` と深さの一致など）・リンク切れ・`NAV` への登録漏れ（孤立したページ）・LF・コードの中のエスケープしていない `<`・`pages.yml`・囲みの題・見出し（番号を手で書かない・階層を飛ばさない）。
- **食い違いの検出（`doc/doc-style.md` の 3 階層。コード → 技術文書 → 一般向け文書の順に正しさを伝える）**: ① `tests/test_docs_facts.sh` が、`site/**/*.html` と `README.md` の中のコマンド名・オプション（コード片では、一緒に書いたコマンドの冒頭コメントにあるか）・パス・環境変数（`SF_…`）が、実在するかを調べる（`doc/` は対象外。仕様どおりに存在しない例の書き方は、`tests/docs-facts-allow.txt`）。② `tests/test_docs_stamps.sh` が、冒頭コメントが変わったのに文書が見直されていないものを検出する（`doc/doc-stamps.txt`。新しい `bin/sf-*.sh` は、どれかの文書の基にしないと失敗する）。CI は検出だけで、文書を自動では書き換えない。
- **公開**: `.github/workflows/pages.yml` が、`main` に `site/` の変更が入ったとき、`site/` を GitHub Pages に公開する（`development` の途中経過は出ない）。リポジトリの Settings → Pages → Source を「GitHub Actions」にする設定（最初の 1 回だけ）は、済んでいる（`gh api repos/tama-create/sf-tools/pages` の `build_type` が `workflow`。2026-10-23 の rr の公開は成功）。公開先は、`https://tama-create.github.io/sf-tools/`。
- **手元で見る**: `site/index.html` を、ブラウザで直接開く（サーバーは不要）。

