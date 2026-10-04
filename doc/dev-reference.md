# sf-tools 開発リファレンス

> **本書の位置づけ:** CLAUDE.md のルール・判断基準を補完する詳細リファレンス。
> コーディング中に「どう書くか」を調べるときに参照すること。

---

## 1. クロスプラットフォーム詳細

### 1.1 Bash バージョン要件

- **Bash 4.3 以上を必須とする**（`local -n` nameref 等を使用するため）
- `lib/common.sh` 冒頭で `BASH_VERSINFO` をチェックし、4.3 未満は起動不可としてアップグレードを促す
- 互換ハックで古い環境に対応するよりも、**環境アップグレードを促すことを優先する**（コードの質・メンテナンス性を守るため）
- macOS デフォルト Bash は 3.2 のため、`brew install bash` を案内すること

### 1.2 OS 検出の統一ルール

| 目的 | 使う方法 | 理由 |
|---|---|---|
| GitBash 検出 | `[[ "$OSTYPE" == "msys"* \|\| "$OSTYPE" == "mingw"* ]]` | Bash 組み込み・サブプロセス不要 |
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
| `test_common.sh` | lib/common.sh |
| `test_init-common.sh` | phases/init/init-common.sh（`ensure_sf_tools_branch`。実際の Git と一時 bare リポジトリを使用） |
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
| `test_sf-job.sh` | sf-job.sh |
| `test_sf-next.sh` | sf-next.sh |
| `test_sf-check.sh` | sf-check.sh |
| `test_sf-prepush.sh` | hooks/pre-push |
| `test_sf-push.sh` | sf-push.sh |
| `test_sf-update-secret.sh` | sf-update-secret.sh |

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
| `get_target_org` | `get_target_org [ALIAS]` | 対象組織エイリアスを解決して出力 |
| `check_force_dir` | `check_force_dir` | `force-*` ディレクトリか検証 |
| `check_home_dir` | `check_home_dir` | `~/home/{owner}/{company}/` の階層を検証し `GITHUB_OWNER` / `COMPANY_NAME` をセット |
| `check_gh_owner` | `check_gh_owner OWNER` | gh 認証ユーザーがリポジトリオーナーと一致するか確認（不一致は die。オーナーが組織で、ユーザーがその有効な admin なら通過。gh が空を返す場合はスキップ） |
| `open_browser` | `open_browser URL` | OS 判定してブラウザを開く（WSL/GitBash/macOS/Linux 対応） |
| `read_input` | `read_input VAR [PROMPT]` | readline 対応テキスト入力（矢印キー・BS 有効） |
| `read_key` | `read_key VAR [PROMPT] [VALID]` | 1文字即時入力（Enter 不要・空 Enter 無視・EOF 対応） |
| `press_enter` | `press_enter [MSG]` | Enter 待ち（q で中断） |
| `read_or_quit` | `read_or_quit VAR PROMPT` | テキスト入力（空 Enter 無視・q で中断・EOF 対応） |
| `read_secret` | `read_secret VAR PROMPT` | 秘密情報の入力（画面に表示しない・空 Enter 無視・q で中断・末尾の CR を除去）。Token の入力に使う |
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

### 3.4 安全ガードパターン

管理者向けコマンドには2種類の安全ガードを組み合わせて使う。

#### 3.4.1 警告ボックス + `ask_yn || die`（管理者向けコマンドの冒頭）

意図しない実行を防ぐための視覚的警告と確認プロンプト。`GITHUB_ACTIONS=true` の場合はスキップして自動続行する。

```bash
# 管理者向けコマンドの冒頭パターン（sf-init / sf-metasync / sf-update-secret 等）
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  !!  このコマンドは管理者専用です                    ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      管理者以外は絶対に実行しないでください          ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
    ask_yn "続行しますか？" || die "中断しました。"
fi
```

> `CLR_ERR` は赤色（`\033[0;31m`）。ボックス罫線は `╔ ═ ╗ ║ ╚ ╝`（U+2554 等）を使用。

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
check_home_dir               # GITHUB_OWNER / COMPANY_NAME をセット
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

- ターゲットファイルをもとに `package.xml` を生成
- `sf project deploy start` で検証または本番実行

主なオプション: `--release` / `--no-open` / `--force` / `--target`

**安全ガード（セクション 3.4）:**
ローカル実行 + `--release` + `SF_DEPLOY_CONFIRMED!=1` の条件をすべて満たす場合のみ警告ボックス + `ask_yn` を実行する。`GITHUB_ACTIONS=true` / validate モード / `SF_DEPLOY_CONFIRMED=1`（sf-deploy.sh 経由）の場合はスキップ。

`@isTest` 自動検出フロー:
1. `phase_generate_manifest` 内で `deploy_args` を走査し、`--source-dir` に続く `.cls` ファイルを `grep -qi "@isTest"` で検査
2. 検出されたクラス名をスクリプトレベル変数 `RUN_TESTS=()` に追加
3. `phase_release` で `${#RUN_TESTS[@]} -gt 0` の場合、`--test-level RunSpecifiedTests --run-tests <CSV>` を `deploy_cmd` に追加して実行
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
1. `~/sf-tools` を `git pull` で更新
2. `config/*.txt` を不足時のみ補充
3. `sf-hook.sh` で Git Hook をインストール
4. `release/<branch>/` と `branch_name.txt` を準備
5. `package.json` がある場合は `npm install`
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
- `--release` を転送した場合は sf-release.sh の安全ガード（セクション 5.2）が働く

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
- **安全ガード:** `log "WARNING"` で `--force` の意味を表示 → `ask_yn || die` で続行確認（**赤い警告ボックスなし**。赤いボックスは sf-init / sf-metasync / sf-update-secret / sf-release 直接実行のみ）
- `export SF_DEPLOY_CONFIRMED=1` で sf-release.sh 側の二重確認を抑制

### 4.9 sf-upgrade.sh

- npm / Salesforce CLI / Git を更新
- `sf-install.sh` から 24 時間間隔でバックグラウンド起動される
- Git の更新は GitBash（`$OSTYPE == "msys"*` / `"mingw"*`）のみ実行（他環境はパッケージマネージャーを案内）

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

> `SF_TOOLS_TOKEN`（Secret）は `sf-update-secret.sh` では登録しない。`sf-init.sh` の Phase 11 が登録する（スキップ時・作り直しは手動登録）。wf-metasync / wf-validate / wf-release が Private の `tama-create/sf-tools` を clone するための Fine-grained PAT（Contents: Read-only・Resource owner は sf-tools の所有者）。`SF_TOOLS_BRANCH`（Variable）は、sf-init.sh を環境変数 `SF_TOOLS_BRANCH=development` 付きで実行した場合のみ `phases/init/09_repo_rules.sh` が `development` を登録する（検証環境用）。未設定なら Actions は `main` を clone する。手順は `doc/setup-guide.md` 3.2 を参照。

**SF_PRIVATE_KEY の base64 エンコーディング:**
GitHub Actions のワークフローは Secret から取得した値を `base64 -d` でデコードして使用する。そのため `SF_PRIVATE_KEY` は **base64 エンコード済みの文字列** として登録しなければならない。`sf-update-secret.sh` の `_update_private_key` は以下のパイプで登録する:

```bash
tr -d '\r' < "$key_file" | base64 -w 0 | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME"
```

> `tr -d '\r'` は Windows 改行コード（CRLF）を除去するため。`-w 0` は base64 の折り返しなし（1行）。

**JWT 接続テスト（内部処理）:**
`sf org login jwt` は終了コードが不安定なため、終了コードではなく stdout の `Successfully authorized` 文字列で成功を判定する。実行コマンドと出力はログに記録する。

### 4.12 sf-hook.sh / sf-unhook.sh

- `sf-hook.sh`: `.git/hooks/pre-push` と `.git/hooks/pre-commit` を上書き生成し、`~/sf-tools/hooks/` からコピーする
- `sf-unhook.sh`: `.git/hooks/pre-push` を削除する

### 4.13 sf-init.sh

新規 Salesforce プロジェクトの初期セットアップ。`phases/init/` 配下のフェーズスクリプトを順次実行する。

実行フロー:
1. 環境チェック（ツール確認・GitHub CLI 認証確認）
2. プロジェクト情報の確認（フォルダ構成から自動導出）→ `.sf-init.env` に書き出し
3. リポジトリ作成（gh repo create + git clone）
4. ファイル生成（sf-install.sh / sf-hook.sh）
5. ブランチ構成（対話選択 → branches.txt 更新）
6. PAT_TOKEN の設定
7. Slack 連携の設定（SLACK_BOT_TOKEN を Secret / SLACK_CHANNEL_ID を Variable に登録。チャンネル ID は C または G で始まる形式かを検証し、それ以外（D=DM、U=ユーザーなど）は警告して拒否し、入力し直させる。通知先は全員が参加する共有チャンネルのため）
8. 初回コミット＆プッシュ（PAT は GIT_ASKPASS で渡しコマンドのログに残さない。push 後に .sf-init.env から PAT を削除する）
9. GitHub リポジトリ設定・Ruleset の適用（既存 Ruleset の ID は数字のときだけ削除対象にする）
10. JWT 認証情報の設定（SF_PRIVATE_KEY / SF_CONSUMER_KEY_* を Secret / SF_USERNAME_* / SF_INSTANCE_URL_* を Variable に登録）。アプリ種別が外部クライアントアプリ（2）のときは、組織ごとに `register_jwt_secret_eca`（`init-common.sh`）が自動作成する（`sf org login web` → ユーザー名・プロファイル名（表示名）を取得 → `generate_eca_metadata` で 5 ファイルを生成して `sf project deploy` → `sf project retrieve` でコンシューマー鍵を取得 → JWT 接続テスト（反映待ちのためリトライ。`SF_INIT_JWT_RETRIES` / `SF_INIT_JWT_INTERVAL`）→ 登録）。ログイン用の一時エイリアス（`sf-tools-PROD` / `sf-tools-STG` / `sf-tools-DEV`。ユーザーが運用中のエイリアスと重ならないよう `sf-tools-` を付ける）は、ログイン前に `sf alias unset` で外し（前回の古い認証による誤判定の防止）、終了後にも `sf alias unset` で消す（`sf org logout` は同じユーザー名の全エイリアスの認証を消すため使わない）。`sf` は、Windows の Git Bash で、公式インストーラー版 + 自動更新版の組み合わせのとき、成功しても終了コード 1 を返すことがある（`sf org login web` / `sf org display` ほか。`SF_REDIRECTED=1` で回避できる）。そのためログインの成否は、終了コードを一切見ず、一時エイリアスの接続情報（`sf org display --json` の出力の `username`）が取れるかで判定する。接続アプリ（1）は従来の手動案内
11. SF_TOOLS_TOKEN の設定（`11_sf_tools_token.sh`。Fine-grained PAT の作成画面を事前入力 URL で開く → `read_secret` で Token を入力（画面に表示しない）→ `GH_TOKEN` 環境変数で `gh api repos/<sf-tools>` を実行して読み取りを確認（コマンドの文字列・ログに Token を含めない）→ `printf '%s' "$TOKEN" | run gh secret set SF_TOOLS_TOKEN`。確認に失敗した場合は再入力かスキップを選ぶ。Token は `.sf-init.env` に書き出さない。sf-tools の OWNER/REPO は `init-common.sh` の `SF_TOOLS_REPO_FULL_NAME`）

オプション:
- `--resume N`: Phase N から再開（エラー後の再試行）
- `--only N`: Phase N のみ実行（デバッグ用）
- `--add-tier staging|develop`: 既存プロジェクトへの tier 追加（後述）

#### 4.13.1 `--add-tier` による tier 追加

既存 `force-*` プロジェクトに staging または develop 階層を追加する。`phases/init/add_tier.sh` を呼び出す。

実行場所: **`force-*` ディレクトリ内**（`sf-init.sh` の通常実行とは異なる点に注意）

```bash
cd ~/home/{owner}/{company}/system/force-xxx
sf-init.sh --add-tier staging    # main → main+staging
sf-init.sh --add-tier develop    # main+staging → main+staging+develop
```

`add_tier.sh` の処理フロー:
1. `check_force_dir` で `force-*` ディレクトリか確認
2. `.sf-init.env` を読み込み（なければ git remote から `REPO_FULL_NAME` を導出）
3. バリデーション:
   - 対象 tier がすでに `branches.txt` に存在する場合はエラー
   - `develop` を追加しようとしたとき `staging` が未登録の場合はエラー（`main → develop` のスキップは禁止）
4. `branches.txt` に tier を追記
5. `git push` でリモートにブランチを作成（既存ならスキップ）
6. JWT 認証情報（`SF_CONSUMER_KEY_*` を Secret / `SF_USERNAME_*` / `SF_INSTANCE_URL_*` を Variable）を登録
7. `branches.txt` をコミット＆プッシュ（main ブランチに）

スケールアップのみ対応・スケールダウンは対象外:
- tier の削除（スケールダウン）は自動化していない
- スケールダウンは影響範囲が大きく（ブランチ削除・WF 停止・Secrets 削除・Ruleset 更新）、誤操作リスクが高いため**手動運用とする**
- 必要な場合は GitHub リポジトリ設定・`branches.txt` 編集・ローカルブランチ削除を手動で実施すること

### 4.14 sf-check.sh

ターゲットファイルの構文チェックと、テストクラス不足検出を行う。`sf-release.sh` / `sf-prepush.sh` / `sf-push.sh` から自動呼び出しされる。

`check_target_file` の処理（`deploy-target.txt` / `remove-target.txt` 共通）:
- `[files]` セクション: ファイルパスの存在確認（`[[ ! -e "$clean" ]]`）→ エラー時は `print_gcc_error` で GCC スタイル出力
- `[members]` セクション: `種別名:メンバー名` 書式確認（コロンなし → `print_gcc_error`）
- `error_count > 0` の場合のみ終了コード 1

`check_missing_tests` の処理（WARNING のみ・エラーにならない）:
- `deploy-target.txt` の `[files]` セクションから `.cls` ファイルを収集
- 各 `.cls` に対して `@isTest` があればテストクラス自身と判断してスキップ
- Step A: 同一ディレクトリ内で `MyClassTest.cls` / `MyClass_Test.cls` を探す
- Step B: A で見つからない場合、`grep -rl --include="*.cls" "@isTest" .` → `xargs grep -lw "$classname"` でコンテンツ検索
- 見つかったテストクラスが `deployed_files` に含まれていなければ `print_gcc_warning` を出力
- 設計思想: 本番/Sandbox に既存のテストクラスは含めなくてよい → WARNING 扱い（エラーにはしない）

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
| `templates/.github/workflows/` の内容 | `phases/init/08_repo_rules.sh` の `required_status_checks.context` との整合 |
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
bash tests/run_tests.sh test_sf-start.sh          # 単体実行
cat logs/run_tests.log | grep '\[FAIL\]'          # 失敗行のみ抽出
cat logs/error.log                                # run 失敗コマンドのログ
```

実環境で `sf-init.sh` を通しで検証する e2e は、通常のテストには含まれない（9.6 参照）。

```bash
bash tests/e2e/bootstrap.sh                       # 鍵一式の作成（最初の 1 回だけ）
bash tests/e2e/run.sh                             # 前掃除 → sf-init の通し実行 → 確認 → 後掃除
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

- `SF_TOOLS_TOKEN`（Secret）は `sf-init.sh` の Phase 11 が登録する（スキップした場合のみ手動登録が必要。`doc/setup-guide.md` 3.2）

### 9.3 検証チェックリスト（rr の前提）

変更内容に応じて、必要な項目を実施し、結果をユーザーが報告する。

| 確認項目 | 方法 |
|---|---|
| テスト | `bash tests/run_tests.sh` が全件 PASS |
| `sf-init.sh` を変更した場合 | 検証環境の新規 force-* を作成し、最後まで通ること（Phase 11 の `SF_TOOLS_TOKEN` の登録を含む）。`bash tests/e2e/run.sh` で自動化できる（9.6） |
| ワークフロー・`sf-metasync.sh` を変更した場合 | `wf-metasync` を `workflow_dispatch` で手動実行して成功すること |
| `sf-release.sh` / `wf-validate` / `wf-release` を変更した場合 | デプロイ対象を含む PR を作り、`wf-validate` が通ること（動作確認のみの PR はマージせずに閉じる。マージすると `wf-release` が実際にデプロイする） |

> `templates/` の変更は配布済みの force-* に自動反映されない。検証環境の force-* の `wf-*.yml` は、手動で `templates/` と一致させること。

### 9.4 リリース（rr）

1. 9.3 の確認が完了し、ユーザーが結果を報告している
2. 「rr」の指示で、`development` → `main` の PR を作成してマージする（手順は `CLAUDE.md` 1.3.2）
3. マージ後、`main` の内容を検証環境の force-* でもう一度確認する

### 9.5 ガードレール

- `main` のブランチ保護・Ruleset は、GitHub 無料プラン（Private リポジトリ）では設定できない（`Upgrade to GitHub Pro or make this repository public`）
- そのため、`CLAUDE.md` 1.1 の運用ルール（mm / rr は明示された場合のみ、rr は検証報告が前提）で守る
- プランの変更、またはリポジトリを公開にできるようになった場合は、`main` に Required reviewers を設定すること

### 9.6 e2e（sf-init の通し検証の自動化）

実際の GitHub / Salesforce で `sf-init.sh` を Phase 1〜11 まで自動実行し、検証し、削除する。`tests/e2e/` に置き、通常の `bash tests/run_tests.sh` には含めない（実環境を使うため）。安全ガードと部品は `tests/test_e2e.sh`（モック）で確認する。

**方式:** `sf-init.sh` 本体は変えず、外から標準入力と PATH の差し替えで操作する（本番のコードに近道を入れない）。

| 部品 | 役割 |
|---|---|
| `tests/e2e/lib.sh` | 共通関数。名前の判定、ガード、鍵一式の読み込み、削除、エイリアスの保存・復元、`e2e_make_input`（標準入力の台本） |
| `tests/e2e/run.sh` | 前掃除 → `sf-init.sh` の実行 → 確認 → 後掃除。`--keep`（後掃除なし）、`--no-actions`（Actions の確認を省略） |
| `tests/e2e/cleanup.sh` | 削除。既定は一覧のみ、`--yes` で削除（確認で `delete` の入力が必要。`--no-confirm` で省略） |
| `tests/e2e/bootstrap.sh` | 鍵一式（`~/.sf-tools-e2e/fixture.env`）の作成。最初の 1 回だけ。雛形は `fixture.example.env` |
| `tests/e2e/shims/sf` | `sf org login web` だけを `sf org login sfdx-url`（認証 URL）に差し替える。他のコマンドは本物の `sf` に渡す |
| `tests/e2e/shims/browser` | `start` / `xdg-open` / `open` の名前でコピーされ、ブラウザを開かない |

**テスト用の名前:** プロジェクト `e2e-YYYYMMDD-HHMMSS` → リポジトリ `force-e2e-YYYYMMDD-HHMMSS` → 外部クライアントアプリ `SF_TOOLS_force_e2e_YYYYMMDD_HHMMSS`。毎回別の名前なので、前回の削除を待たずに実行できる。

**確認する内容:** Secret / Variable / ブランチ / ワークフローの存在、`SF_TOOLS_BRANCH=development`、`SLACK_CHANNEL_ID` の一致、トークンが出力・ログに出ていないこと、`wf-metasync` の成功、`wf-release` の途中のステップ（JWT ログイン・Private の `sf-tools` の取得）と Slack 通知（`"ok":true`）。`wf-release` は `main` に release 用のファイルが無く、最終的に失敗するのが正常。

**削除の安全ガード:**

- 削除対象は、名前の形式（上記のタイムスタンプ付き）が一致するものだけ。`SF_TOOLS`、`force-test-win` などは対象外（`e2e_is_target_*`）
- オーナーは、鍵一式の `E2E_OWNER` のみ。gh のログインユーザーが `E2E_GH_USER` と一致しないと動かない
- `e2e_guard_env` を通らないと、削除系の関数は動かない（`E2E_GUARD_OK=1`）。GitHub Actions 上では動かない
- `cleanup.sh` は既定で何も消さない。`--yes` でも、一覧を見せたうえで `delete` の入力を求める

**Salesforce の外部クライアントアプリの削除:** 削除用のデプロイ（`sf project deploy start --manifest package.xml --post-destructive-changes destructiveChanges.xml`）で、5 つの構成要素を消す（`ExternalClientApplication` / `ExtlClntAppGlobalOauthSettings` / `ExtlClntAppOauthSettings` / `ExtlClntAppOauthConfigurablePolicies` / `ExtlClntAppConfigurablePolicies`）。ローカルのソースは要らない。アプリを消すと、そのアプリでの JWT のセッションも無効になるため、削除の前に、認証 URL（`sfdxAuthUrl`）で管理用にログインし直す。これで、テスト後の `sf` の認証は、健全な状態に戻る。

**sf のエイリアス:** `sf-init` は `prod` / `staging` / `develop` を付けるため、実行前の状態を保存し、終了時に復元する（増えたものは外し、変わったものは戻す）。

**前提と限界:**

- 台本（`e2e_make_input`）は、`sf-init` の質問の順番に依存する。質問を変えたら、台本も直す。`tests/test_sf-init.sh` の `test_e2e_input_sequence`（モック）が、ずれを検知する
- Token の作成と、テスト用組織への最初のログインは自動化できない（`bootstrap.sh` で 1 回だけ手動）
- 実機の Windows（Git Bash）で動かす前提。`sf` が成功しても終了コード 1 を返す環境では、`E2E_SF_REDIRECTED=1`（`bootstrap.sh` が判定して設定）
- テスト用組織は、本番または Developer Edition（Sandbox ではない）
- リポジトリの削除には、`gh` の `delete_repo` の権限が要る（`gh auth refresh -h github.com -s delete_repo`）
