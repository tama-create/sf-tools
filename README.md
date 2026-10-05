# sf-tools — Salesforce 開発自動化ツールキット

> **本ドキュメントの範囲:** sf-tools の機能概要・使い方・スクリプト一覧。実装の詳細（フロー・ファイルパス等）はコードのヘッダーコメントを正とします。

Salesforce 開発で毎回発生する環境構築、デプロイ、事前チェック、メタデータ同期をまとめて自動化するシェルスクリプト集です。
`~/sf-tools` に配置し、各 Salesforce プロジェクト (`force-*` ディレクトリ) から呼び出して使います。

---

## 1. 前提条件

> ⚠️ **検証済み動作環境:**
> - **ローカル:** Windows + Git Bash
> - **サーバー:** Linux（GitHub Actions / Ubuntu ランナー）
>
> macOS / WSL でも動作するようクロスプラットフォームを意識して実装していますが、動作検証は行っていません。

以下のコマンドが使えること。

| ツール | 確認コマンド | 用途 | 取得先 | Windows インストール方法 |
|---|---|---|---|---|
| Git (Git Bash) | `git --version` | Git Bash / フック / バージョン管理 | https://git-scm.com/download/win | インストーラ実行 |
| Salesforce CLI（**npm 版**） | `sf --version` | 組織接続、デプロイ、retrieve | https://developer.salesforce.com/tools/salesforcecli | `npm install -g @salesforce/cli`（Node.js が必要。**公式インストーラー版は非対応**。1.1 参照） |
| GitHub CLI | `gh --version` | PR 作成・Secrets 登録・リポジトリ操作 | https://cli.github.com/ | `winget install --id GitHub.cli` |
| Visual Studio Code | `code --version` | エディタ起動 | https://code.visualstudio.com/ | `winget install --id Microsoft.VisualStudioCode` |
| Slack | — | デプロイ通知の受信 | https://slack.com/downloads/windows | インストーラ実行 |

> Bash 4.3 以上が必須です（Git for Windows 2.x 以降の Git Bash に含まれています）。`bash --version` で確認してください。

補足:
- Git Bash で実行してください（PowerShell / コマンドプロンプトは非対応）
- `sf-init.sh` を除くすべてのスクリプトは `force-*` ディレクトリ内から実行してください
- `sf-init.sh` のみ `force-*` の**外**（親ディレクトリ）から実行します

### 1.1 Salesforce CLI は npm 版を使う

sf-tools は、**Salesforce CLI（`sf`）の npm 版**（`npm install -g @salesforce/cli`）を前提としています。npm 版も、Salesforce が案内しているインストール方法の一つです。

**理由:** Windows の Git Bash で、Salesforce CLI の**公式インストーラー版**（`winget` 版を含む可能性があります）を使い、自動更新が入った状態になると、`sf` が**成功しても、終了コード 1 を返し続ける**ことがあります（同じバージョンの npm 版は、正しく返します。Salesforce の起動用ファイルの問題と考えられます）。sf-tools は、コマンドの成否を終了コードで判定するため、この環境では、成功した処理も失敗扱いになります。

**確認方法:** 次のコマンドで、`終了コード=0` と表示されれば問題ありません。

```bash
command -v sf; sf --version; echo "終了コード=$?"
```

`sf-init.sh` は、起動時にこれを確認し、0 以外なら案内を表示して中断します。`sf-install.sh` は、警告を表示するだけで続行します（中断すると、sf-tools 自身の最新化が止まってしまうためです）。日常のコマンド（`sf-start.sh`、`sf-release.sh`、`sf-metasync.sh`、`sf-update-secret.sh`）も、起動時に確認し、問題があれば案内を表示して**中断**します（`sf` の成否は、すべて終了コードで判定するため、終了コードが正しくない `sf` では、途中で中途半端に止まるより、最初に止めるほうが安全だからです）。確認に成功した場合は、24 時間は、確認を省略します（`~/.sf-tools-sf-check`）。

**インストーラー版から npm 版への入れ替え（Windows）:**

1. npm 版を入れます（`C:\Program Files\nodejs` に書き込むため、管理者権限の Git Bash が必要な場合があります）。
   ```bash
   npm install -g @salesforce/cli
   ```
2. 公式インストーラー版をアンインストールします（「設定 → アプリ」の「Salesforce CLI」、または `C:\sf\Uninstall.exe`）。
3. 自動更新で増えた `%LOCALAPPDATA%\sf\client` を削除します。
4. **新しい** Git Bash を開いて、上の確認コマンドを実行します。あわせて `sf org list` で、既存の組織が表示されることを確認してください。

> ⚠️ `~/.sf` と `~/.sfdx` は、組織のログイン情報が入っているため、**削除しないでください**。入れ替えても、ログイン情報は残ります。VS Code を使っている場合は、入れ替え後に VS Code を再起動してください。

**更新:** `sf-upgrade.sh` が、npm 版は `npm install -g @salesforce/cli@latest` で更新します（手動で行う場合も同じコマンドです）。

**macOS / Linux:** 同じく npm 版をおすすめします。ほかの方法（pkg・Homebrew など）で入れた場合も、上の確認コマンドで終了コード 0 になれば、そのまま使えます。

---

## 2. インストール

### 2.1 sf-tools の配置

```bash
git clone https://github.com/tama-create/sf-tools.git ~/sf-tools
```

### 2.2 PATH の設定（推奨）

`~/.bashrc` に以下を追加すると、どこからでもスクリプト名だけで呼び出せます。

```bash
# sf-tools
export PATH="$HOME/sf-tools/bin:$PATH"
```

追加後に `source ~/.bashrc` で反映します。

---

## 3. 使い方

ドキュメント内で使用する `~/home/{owner}/{company}/` の意味:

| プレースホルダー | 内容 | 例 |
|---|---|---|
| `{owner}` | GitHub 組織名（固定）| `my-org` |
| `{company}` | Salesforce 使用者の会社名または部署名（自由）| `acme` / `sales-dept` |

例: `~/home/my-org/acme/`

---

### 3.1 ヘルプを表示する

すべての `sf-*.sh` スクリプトは `--help` / `-h` オプションに対応しています。

```bash
sf-release.sh --help
sf-check.sh -h
```

各スクリプトの概要・オプション・処理フローが表示されます。

---

### 3.2 新規プロジェクトを作成する（管理者）

`~/home/{owner}/{company}/` ディレクトリで実行します。

```bash
sf-init.sh
```

以下を自動実行します。

1. 環境チェック（ツール・GitHub CLI 認証）
2. プロジェクト情報の確認（フォルダ構成から自動導出）と環境種別の選択（通常は「1. 本番環境」。「2. 検証環境」は sf-tools の開発者専用で、選択すると確認が出ます。あわせて `~/sf-tools` が最新かを確認し、遅れていれば更新して中断します）
3. GitHub リポジトリ作成・clone
4. ワークフロー・設定ファイル生成
5. ブランチ構成
6. PAT_TOKEN の設定
7. Slack 連携の設定（通知先は、全員が参加する共有チャンネルを Slack で事前に作成しておく。DM は使えません）
8. 初回コミット＆プッシュ
9. GitHub リポジトリ設定・Ruleset 適用
10. JWT 認証情報（Salesforce → GitHub Secrets / Variables）の設定（外部クライアントアプリは、ブラウザでログインするだけで自動作成）

> リポジトリ名は必ず `force-` で始めてください。

生成されるディレクトリ構成は [7.1 force-* プロジェクト構成](#71-force--プロジェクト構成標準との比較) を参照してください。

#### 3.2.1 既存プロジェクトに tier を追加する（スケールアップ）

セットアップ完了後に、`main` のみの構成を `staging` や `develop` 階層に拡張できます。

```bash
# force-* ディレクトリ内で実行
sf-init.sh --add-tier staging    # main のみ → main + staging
sf-init.sh --add-tier develop    # main + staging → main + staging + develop
```

> `main → develop` のスキップ（staging をとばした develop 追加）はエラーになります。

スケールダウン（tier の削除）については自動化していません。影響範囲が大きく誤操作リスクが高いため、ブランチ削除・Secrets / Variables 削除・Ruleset 更新はすべて手動で実施してください。

### 3.3 新規作業を始める（sf-job）

`~/home/{owner}/{company}/` で実行します。

```bash
sf-job.sh
```

ブランチ名の入力だけで、以下をすべて自動実行します。

1. ジョブ名（例: `JOB-20260323`）でブランチを作成
2. 作業ディレクトリを準備（worktree または clone）
3. `sf-start.sh` を自動起動（ログイン・フック設定・VS Code 起動）

### 3.4 作業を再開する（sf-start）

前日の続きなど既存ブランチで再開するときは `force-*` ディレクトリ内で実行します。

```bash
sf-start.sh
```

| | sf-job | sf-start |
|---|---|---|
| 実行場所 | `~/home/{owner}/{company}/` | `force-*` ディレクトリ内 |
| ブランチ作成 | ✅ 自動 | ❌（既存ブランチを使用）|
| VS Code 起動 | ✅ | ✅ |
| 使うタイミング | 新規作業開始時 | 2回目以降の作業再開時 |

### 3.5 日常の開発フロー

#### 3.5.1 ターゲットファイルを記述する

ターゲットファイルとは、デプロイ対象・削除対象のメタデータを列挙するファイルです。

| ファイル | 役割 |
|---|---|
| `deploy-target.txt` | デプロイするメタデータを列挙 |
| `remove-target.txt` | 削除するメタデータを列挙 |

`release/<branch>/` 配下に置きます。書き方は [5. ターゲットファイルの書き方](#5-ターゲットファイルの書き方) を参照。

#### 3.5.2 dry-run で検証する

```bash
sf-release.sh
```

#### 3.5.3 デプロイを実行する

```bash
sf-deploy.sh
```

#### 3.5.4 変更をコミット＆プッシュする（sf-push）

```bash
sf-push.sh
```

カレントディレクトリ配下の変更をまとめてコミット＆プッシュします。コミットメッセージは VS Code で入力します。main との差分も自動で取り込みます。

#### 3.5.5 PR の状況を確認する（sf-next）

```bash
sf-next.sh
```

現在のブランチが `develop` / `staging` / `main` にどこまでマージ済みかを一覧表示し、次に出すべき PR 先を案内します。

#### 3.5.6 git フックによる自動チェック

- **pre-commit フック**: `git commit` 時にターゲットファイルの構文チェックを自動実行します。エラーがあればコミットを中止します。
- **pre-push フック**: `git push` 時に main 同期チェックを自動実行します。main / staging / develop への直接 push はブロックされます。

#### 3.5.7 ランチャーから実行する

上記のコマンドはすべて `sfl`（`sf-launcher.sh`）からメニュー形式で実行できます。
`sf-job` / `sf-start` 実行時は自動で起動するため、個別に呼び出す必要はありません。

```bash
sfl
```

```
  ──────────────────────────────────────────────────
  >> Launcher <<
  ──────────────────────────────────────────────────
  [1] Check      ターゲットファイルの構文チェック
  [2] Push       変更をコミット & プッシュ
  [3] Next       次の PR 先ブランチを確認
  [4] Dryrun     現在接続中の組織へリリース検証
  [5] Deploy     現在接続中の組織へリリース
  [6] Start      開発環境を起動（Salesforce ログイン・VSCode 起動）
  [7] Restart    接続組織を切り替えて Start 実行
  ──────────────────────────────────────────────────
  番号を入力 (1-7 / q で終了):
```

---

## 4. スクリプトリファレンス

### 4.0 管理者制限について

⚠️ のついたスクリプトは**管理者専用**です。実行すると赤い警告ボックスが表示され、続行確認（Y/N/q）を求められます。一般の開発者が誤って実行した場合は `N` または `q` で中断できます。

- `GITHUB_ACTIONS=true` の環境変数が設定されている場合（GitHub Actions 上）は確認プロンプトをスキップして自動実行します
- `gh` コマンドを使うスクリプトは起動時に gh 認証ユーザーとリポジトリオーナーの一致を確認します。不一致の場合は中断します。ただし、オーナーが GitHub 組織（例: `tamashimon-org`）で、認証ユーザーがその組織の有効な管理者（admin）であれば、そのまま続行します。組織の一般メンバーや、組織情報を取得できない場合は中断します（`gh auth switch` で正しいアカウントに切り替えてから再実行してください）

### 4.1 一覧

| 対象者 | スクリプト | 用途 | 種別 |
|---|---|---|---|
| 開発者 | `sf-job.sh` | 新規作業開始（ブランチ作成〜VS Code）| ランチャー外 |
| 開発者 | `sf-launcher.sh` | ランチャー本体（`sfl`）| ランチャー外 |
| 開発者 | `sf-dryrun.sh` | dry-run 検証 | ランチャー |
| 開発者 | `sf-check.sh` | ターゲットファイルの構文確認 | ランチャー |
| 開発者 | `sf-next.sh` | 次の PR 先確認・PR 作成 | ランチャー |
| 開発者 | `sf-push.sh` | カレント配下をコミット＆プッシュ | ランチャー |
| 開発者 | `sf-start.sh` | 開発環境を起動 | ランチャー |
| 開発者 | `sf-restart.sh` | 接続先 Sandbox の切り替え | ランチャー |
| 開発者 | `sf-deploy.sh` | ⚠️ 接続中の組織への強制リリース（確認あり） | ランチャー |
| 管理者 | `sf-init.sh` | 新規プロジェクト初期セットアップ | ランチャー外 |
| 管理者 | `sf-hook.sh` / `sf-unhook.sh` | フックの有効化 / 削除 | ランチャー外 |
| 管理者 | `sf-update-secret.sh` | ⚠️ GitHub Secrets の再登録（管理者のみ） | ランチャー外 |
| — | `sf-install.sh` | sf-start から自動実行 | 自動実行 |
| — | `sf-upgrade.sh` | sf-install から自動実行 | 自動実行 |
| — | `sf-prepush.sh` | git pre-push フックから自動実行 | 自動実行 |
| — | `sf-precommit.sh` | git pre-commit フックから自動実行 | 自動実行 |
| — | `sf-metasync.sh` | ⚠️ GitHub Actions から自動実行（ローカル実行時は管理者のみ） | 自動実行 |

### 4.2 `sf-job.sh`

```bash
sf-job.sh
```

新しい作業（ブランチ）を始めるときのオールインワンスクリプトです。`~/home/{owner}/{company}/` 階層で実行します。

主な処理:
- ジョブ名（例: `JOB-20260323`）を入力してブランチを生成
- `git worktree` または `git clone` で作業ディレクトリを作成
- `sf-start.sh` を自動起動（ログイン・フック設定・VS Code 起動）

補足:
- ブランチ作成から VS Code 起動まですべて自動のため、**新規作業は必ずここから始める**
- `force-*` ディレクトリの内側では実行できません

### 4.3 `sf-start.sh`

```bash
sf-start.sh
```

既存ブランチで開発環境を再起動します。`force-*` ディレクトリ内で実行します。

役割:
- 組織接続確認・必要時のみログイン
- `.sf/config.json` / `.sfdx/sfdx-config.json` 更新
- `code .` 実行
- `sf-install.sh` のバックグラウンド実行

補足:
- `sf-job.sh` が内部で自動呼び出すため、**新規作業時は直接実行不要**
- 前日の続きなど、既存ブランチに戻るときに使用

### 4.4 `sf-init.sh`

```bash
sf-init.sh [--resume N] [--only N]
sf-init.sh --add-tier staging    # 既存プロジェクトに staging を追加
sf-init.sh --add-tier develop    # 既存プロジェクトに develop を追加
```

新規 `force-*` プロジェクトの作成をまとめて行うセットアップスクリプトです。

主な処理:
- GitHub リポジトリ作成とクローン
- `sf-install.sh` による初期ファイル生成
- 対話式メニューによるブランチ構成設定（branches.txt 更新）
- GitHub Secrets / Variables の登録支援（詳細は下記）
- 初回コミット、push、Ruleset 設定

オプション:

| オプション | 内容 |
|---|---|
| `--resume N` | Phase N から再開（エラー後の再試行） |
| `--only N` | Phase N のみ実行（デバッグ用） |
| `--add-tier staging` | 既存プロジェクトに staging 階層を追加 |
| `--add-tier develop` | 既存プロジェクトに develop 階層を追加 |

補足:
- 通常の初期セットアップは `force-*` ディレクトリの外で実行します
- `--add-tier` は **`force-*` ディレクトリ内**で実行します
- Salesforce ログイン、PAT 作成、Slack 設定など一部は対話操作が必要です

#### 4.4.1 GitHub Secrets と Variables の使い分け

sf-init.sh が登録する認証情報は、機密性に応じて **Secret（暗号化）** と **Variable（平文）** に分けて管理します。

| 項目 | 種別 | 説明 |
|---|---|---|
| `SF_PRIVATE_KEY` | Secret | JWT 署名用 RSA 秘密鍵 |
| `SF_CONSUMER_KEY_*` | Secret | Connected App のコンシューマキー |
| `PAT_TOKEN` | Secret | GitHub Personal Access Token |
| `SLACK_BOT_TOKEN` | Secret | Slack Bot のアクセストークン |
| `SF_USERNAME_*` | Variable | Salesforce ユーザー名（平文で問題なし） |
| `SF_INSTANCE_URL_*` | Variable | Salesforce インスタンス URL（平文で問題なし） |
| `SLACK_CHANNEL_ID` | Variable | 通知先 Slack チャンネル ID（平文で問題なし） |
| `SF_TOOLS_BRANCH` | Variable | Actions が clone する sf-tools のブランチ（検証環境で sf-init.sh を環境変数 `SF_TOOLS_BRANCH=development` 付きで実行した場合のみ `development` を登録。未設定なら `main`） |

> `*` は組織ごとのサフィックス（`PROD` / `STG` / `DEV`）。

> ℹ️ `sf-tools` は**公開リポジトリ**のため、`wf-metasync` / `wf-validate` / `wf-release` は、Token なしで `sf-tools` を clone します（`SF_TOOLS_TOKEN` は不要です）。以前のバージョンで作ったプロジェクトに `SF_TOOLS_TOKEN` が登録されていても、そのままで構いません。ただし、そのプロジェクトのワークフローが Token 付きで clone している間は、その Token を無効にしないでください（無効な Token では、公開リポジトリでも clone に失敗します）。

#### 4.4.2 ブランチ tier のスケールアップ

初期セットアップ後に、`--add-tier` オプションで段階的に tier を追加できます。

```text
[初期]    main のみ
    ↓  sf-init.sh --add-tier staging
[2段階]   main + staging
    ↓  sf-init.sh --add-tier develop
[3段階]   main + staging + develop
```

追加時に自動で実行される内容:
- `branches.txt` の更新
- リモートブランチの作成（GitHub）
- 追加 tier の JWT 認証情報（Secret / Variable）の登録
- `branches.txt` のコミット＆プッシュ

#### 4.4.3 スケールダウン（tier 削除）について

**tier の削除（スケールダウン）は自動化していません。手動で対応してください。**

理由:
- ブランチ削除・Ruleset 変更・Secrets / Variables 削除など影響範囲が広い
- 誤って削除すると元に戻せないリスクがある
- 需要が少なく、1回の作業で済む手動操作と判断

手動で必要な作業:
1. GitHub でブランチを削除（`staging` / `develop`）
2. `branches.txt` から該当 tier を削除してコミット＆プッシュ
3. GitHub Secrets / Variables から `SF_CONSUMER_KEY_*` / `SF_USERNAME_*` / `SF_INSTANCE_URL_*` を削除
4. GitHub Repository Ruleset を更新（削除した tier のブランチを対象から外す）

### 4.5 `sf-next.sh`

```bash
sf-next.sh
```

現在の feature ブランチが `develop` / `staging` / `main` のどこまでマージ済みかを確認し、次に出すべき PR 先ブランチを案内します。

#### 4.6.1 表示ステータス一覧

| 記号 | ステータス | 説明 |
|---|---|---|
| `✓` | マージ済み | 直接 PR をマージ済み（デプロイ WF 実行済み） |
| `✓` | マージ済み（ブランチ同期） | 直接 PR はないが上位ブランチ経由でコード伝播済み。**デプロイ WF は未実行** |
| `⚠` | マージ済み（順序外） | 前のブランチの直接 PR が完了する前にマージ済み。**前のブランチのデプロイは未実行** |
| `→` | PR発行中 | PR を発行済み（マージ待ち） |
| `▶` | 次のPR先 | 次に PR を出すべきブランチ |
| `✗` | 未着手 | まだ PR を出していない |

#### 4.6.2 判定方法

1. `gh pr list --state merged` で現在ブランチ → 対象ブランチへの**直接 PR** を確認 → `マージ済み`
2. `git merge-base --is-ancestor` で間接伝播（上位ブランチ経由）を確認 → `マージ済み（ブランチ同期）`
3. `gh pr list --state open` で PR 発行中を確認 → `PR発行中`
4. いずれも該当なし → `次のPR先` / `未着手`

#### 4.6.3 順序外マージの制約

`develop → staging → main` の順番を守らずにマージした場合、スキップしたブランチへのデプロイは**永久にできません**。

- 上位ブランチ（例: main）にマージすると、コードが下位ブランチ（例: staging）に伝播する
- 伝播後は「差分なし」となり、feature → staging の直接 PR が作成できなくなる
- GitHub Actions のデプロイ WF は直接 PR のマージイベントで起動するため、伝播では WF が動かない

**スキップしたブランチにデプロイしたい場合は、新しいブランチを切って改めて順序通りに PR を出し直す必要があります。**

#### 4.6.4 補足

- 保護ブランチ（`main` / `staging` / `develop`）上では実行できません
- 案内先ブランチの PR 作成画面をブラウザで開くことができます

### 4.6 `sf-release.sh`

```bash
sf-release.sh [オプション]
```

主なオプション:

| オプション | 内容 |
|---|---|
| `--release`, `-r` | デプロイ実行（dry-run 解除）|
| `--no-open`, `-n` | ブラウザを開かない |
| `--force`, `-f` | `--ignore-conflicts` を付与 |
| `--target`, `-t` | 対象組織エイリアス指定 |

デフォルトは dry-run です。

補足:
- `--json`, `-j` で `sf` コマンド出力を JSON 形式で表示できます
- `--verbose`, `-v` でコマンド出力をコンソールにも表示できます
- `deploy-target.txt` に記述した `.cls` ファイルに `@isTest` アノテーションがあれば自動検出し、`--test-level RunSpecifiedTests --run-tests` を自動設定します（ユーザーが手動で指定する必要はありません）

### 4.7 `sf-deploy.sh`

```bash
sf-deploy.sh [オプション]
```

`sf-release.sh --release --force` を簡単に呼ぶラッパーです。Sandbox の乗り換え時などに、現在の開発物を接続中の組織へ強制リリースする用途で使用します。

> ⚠️ **個人用の Sandbox / Developer Edition / Scratch Org 専用です。** 共有環境（本番・staging・develop）には、ローカルの PC からリリースできません。GitHub にコミットし、レビューを通して、GitHub Actions で行います。
>
> sf-tools は、組織のエイリアスの名前 **`prod` / `staging` / `develop`**（と、互換のための `main`）を、共有環境として予約しています。この名前の組織を接続先にすると、確認（Y/N/q）の前に、拒否されます。`sf-init` は、この名前で組織を登録します（`sf-start.sh` も、`prod` を本番として扱います）。
>
> **予約名以外の名前に付け替えた場合は、動作を保証しません。** 名前で判断しているため、共有環境の組織を、別の名前で接続すると、この保護は働きません。共有環境の組織は、予約名のまま使ってください。

> ⚠️ 実行前に `--force` の WARNING 表示と確認プロンプト（Y/N/q）が表示されます。`N` または `q` で中断できます。

追加で使えるオプション:
- `--no-open`, `-n`
- `--target`, `-t`
- `--verbose`, `-v`

### 4.8 `sf-dryrun.sh`

```bash
sf-dryrun.sh
```

`sf-release.sh` のラッパーです。dry-run（検証のみ）専用コマンドとして、ランチャーの `[4] Dryrun` から呼ばれます。

補足:
- `sf-release.sh` のデフォルトが dry-run のため、オプションなしで呼び出すだけで検証が実行されます
- 直接実行する場合は `sf-release.sh` でも同じ動作になります

### 4.9 `sf-install.sh`

```bash
sf-install.sh
```

`sf-tools` 自体の更新と、プロジェクト側の初期ファイル整備を行います。通常は `sf-start.sh` から自動実行されます。

主な処理（順序）:
1. `~/sf-tools` の最新化
2. 設定ファイル雛形の生成
3. pre-push フックのインストール
4. `release/<branch>/` の準備
5. `npm install`（package.json がある場合）
6. 必要に応じた `sf-upgrade.sh` のバックグラウンド実行（24 時間間隔）

### 4.10 `sf-check.sh`

```bash
sf-check.sh [deploy-target.txt] [remove-target.txt]
```

ターゲットファイルの構文をチェックします。通常は `sf-release.sh` や `sf-prepush.sh` から自動実行されます。

チェック内容:
- `[files]` セクション: 記述したパスがリポジトリ内に存在するか
- `[members]` セクション: `種別名:メンバー名` の書式になっているか
- **テストクラス不足検出**: Apex クラス（通常クラス）に対応するテストクラスがローカルに存在するのに `deploy-target.txt` に含まれていない場合に WARNING を表示します（エラーにはならない）
  - Step A: 命名規則（`MyClassTest.cls` / `MyClass_Test.cls`）で同一ディレクトリを検索
  - Step B: A で見つからない場合、`@isTest` を含む `.cls` ファイルをコンテンツ検索
  - ※ 本番/Sandbox に既存のテストクラスは含めなくてよいため WARNING 扱い

補足:
- 引数省略時は現在ブランチの `release/<branch>/` 配下を自動解決します
- 終了コードは `0` が正常（WARNING あり含む）、`1` が構文エラーです

### 4.11 `sf-metasync.sh`

```bash
sf-metasync.sh
```

役割:
- 組織の最新メタデータを取得
- Git へ反映
- 変更がある場合のみ commit / push

主に GitHub Actions からの定期実行を想定しています。

> ⚠️ **管理者専用**: 実行前に赤い警告ボックスと確認プロンプトが表示されます。`GITHUB_ACTIONS=true` の場合はスキップして自動実行します。

### 4.12 `sf-restart.sh`

```bash
sf-restart.sh
```

接続先組織を切り替えたいときに使います。

### 4.13 `sf-hook.sh` / `sf-unhook.sh`

```bash
sf-hook.sh
sf-unhook.sh
```

役割:
- `sf-hook.sh`: `.git/hooks/pre-commit` と `.git/hooks/pre-push` にフックをインストール（強制上書き）
- `sf-unhook.sh`: `.git/hooks/pre-push` を削除

### 4.14 `sf-prepush.sh`

`git push` 前に自動で実行されるチェックスクリプトです。

主な処理:
- `main` への直接 push を禁止
- 自分のブランチのリモート差分を先に同期
- `main` の未取り込み更新を確認し、必要なら自動 rebase
- `sf-check.sh` でターゲットファイル構文を検証

### 4.15 `sf-upgrade.sh`

```bash
sf-upgrade.sh
```

npm / Salesforce CLI / Git を更新します。

### 4.16 `sf-launcher.sh`

```bash
sfl          # メニュー形式で選択
sflf         # fzf でインクリメンタル検索
sfl 4        # 番号を直接指定して即実行
```

sf-tools の全コマンドをメニューから選んで実行できるランチャーです。`force-*` ディレクトリ内で使います。

```
  ──────────────────────────────────────────────────
  >> Launcher <<
  ──────────────────────────────────────────────────
  [1] Check      ターゲットファイルの構文チェック
  [2] Push       変更をコミット & プッシュ
  [3] Next       次の PR 先ブランチを確認
  [4] Dryrun     現在接続中の組織へリリース検証
  [5] Deploy     現在接続中の組織へリリース
  [6] Start      開発環境を起動（Salesforce ログイン・VSCode 起動）
  [7] Restart    接続組織を切り替えて Start 実行
  ──────────────────────────────────────────────────
  番号を入力 (1-7 / q で終了):
```

補足:
- VS Code 内では `start` / `restart` が非表示になります（二重起動防止）

### 4.17 `sf-push.sh`

```bash
sf-push.sh
```

カレントディレクトリ配下の変更をコミット＆プッシュします。

主な処理:
1. `origin/main` を fetch して現在ブランチにマージ（コンフリクト時はエラー中止）
2. カレント配下を `git add --all`
3. `sf-check.sh` で構文検証
4. VS Code を別ウィンドウで開いてコミットメッセージを入力
5. `git commit` → `git push`

補足:
- コミットメッセージ未入力の場合は何もせず終了

### 4.18 `sf-precommit.sh`

`git commit` 時に自動実行される pre-commit フックの本体です。直接実行することはありません。

主な処理:
- `sf-check.sh` でターゲットファイルの構文チェック
- エラーがあればコミットを中止

### 4.19 `sf-update-secret.sh`

```bash
sf-update-secret.sh
```

GitHub の JWT 認証情報を一括再登録します。JWT 秘密鍵の更新時などに使用します。

> ⚠️ **管理者専用**: 実行前に赤い警告ボックスと確認プロンプトが表示されます。

機密情報（Secret）と平文設定値（Variable）をそれぞれ適切な方法で登録します:
- **Secret**: `SF_PRIVATE_KEY` / `SF_CONSUMER_KEY_*`（`gh secret set`）
- **Variable**: `SF_USERNAME_*` / `SF_INSTANCE_URL_*`（`gh variable set`）

主な処理:
1. git remote から対象リポジトリ（OWNER/REPO）を自動取得
2. gh 認証ユーザーとリポジトリオーナーの一致を確認
3. メインメニューで操作を選択（秘密鍵更新 / コンシューマキー更新 / ユーザー名更新 / すべて更新）
4. 組織選択は `branches.txt` の構成（PROD / STG / DEV）に応じて動的に変化
5. `gh secret set` / `gh variable set` でそれぞれ更新

補足:
- `force-*` ディレクトリ内で実行してください
- ユーザー名（`SF_USERNAME_*`）は現在の登録値を自動取得して表示します
- JWT の接続テストは、**一時的なホームフォルダの中**で実行します。あなたの `sf` に、エイリアス（`prod` など）が増えたり、同じユーザーの既存のログインが置き換わったりすることはありません（`sf-init.sh` の接続テストも同じです）

---

## 5. ターゲットファイルの書き方

`release/<branch>/` の下に 2 ファイルを置きます。

- `deploy-target.txt`
- `remove-target.txt`

### 5.1 `deploy-target.txt`

```text
[files]
# ファイルパスで指定
force-app/main/default/classes/MyController.cls
force-app/main/default/classes/MyControllerTest.cls
force-app/main/default/lwc/myComponent

[members]
# メタデータ種別:メンバー名
# CustomLabel:MyLabel
# Profile:Admin
```

ルール:
- `[files]` と `[members]` の 2 セクション構成
- 行頭 `#` はコメント
- 空行は無視
- `@isTest` アノテーションを持つ `.cls` ファイルを記述すると、`sf-release.sh` が `--test-level RunSpecifiedTests --run-tests <クラス名>` を自動設定します
- テストクラスを記述するかどうかはユーザーの責任です。`sf-check.sh` がローカルに存在するテストクラスの記述漏れを WARNING で通知します

### 5.2 `remove-target.txt`

```text
# 削除対象のパスを列挙
force-app/main/default/classes/OldClass.cls
```

---

## 6. ログの確認

- `sf-init.sh` のログは `~/sf-tools/logs/sf-init.log`（sf-tools 側）
- それ以外のスクリプトのログは、実行した `force-*` ディレクトリ内に `sf-tools/logs/<スクリプト名>.log` として出力されます

---

## 7. リポジトリ構成

### 7.1 force-* プロジェクト構成（標準との比較）

`sf project generate` が生成する標準ファイルと、`sf-init.sh` が追加するものを区別して表示します。

```text
force-xxx/
├── .forceignore
├── .gitattributes                       ★ sf-tools 追加
├── .gitignore
├── .prettierrc / .prettierignore
├── .github/
│   └── workflows/                       ★ sf-tools 追加（CI/CD 5種）
│       ├── wf-release.yml               ★   デプロイ
│       ├── wf-validate.yml              ★   デプロイ前検証
│       ├── wf-sequence.yml              ★   マージ順序チェック
│       ├── wf-propagate.yml             ★   ブランチ伝播
│       └── wf-metasync.yml              ★   メタデータ自動同期
├── .vscode/                             ★ sf-tools 追加（推奨設定・拡張機能）
├── config/
│   └── project-scratch-def.json
├── eslint.config.js
├── force-app/                           ← Salesforce メタデータ本体
├── package.json
├── scripts/
├── sfdx-project.json
├── sf-start.sh / sf-restart.sh         ★ sf-tools 追加（呼び出しラッパー）
└── sf-tools/                            ★ sf-tools 追加
    ├── config/
    │   ├── branches.txt                 ★   ブランチ↔組織エイリアスのマッピング
    │   └── metadata.txt                 ★   メタデータ同期対象の定義
    └── release/<branch>/
        ├── deploy-target.txt            ★   デプロイ対象メタデータ一覧
        └── remove-target.txt            ★   削除対象メタデータ一覧
```

### 7.2 sf-tools リポジトリ構成

```text
sf-tools/
├── bin/                        ← スクリプト本体
│   ├── sf-job.sh
│   ├── sf-start.sh
│   ├── sf-launcher.sh
│   ├── sf-push.sh
│   ├── sf-next.sh
│   ├── sf-release.sh
│   ├── sf-deploy.sh
│   ├── sf-check.sh
│   ├── sf-restart.sh
│   ├── sf-init.sh
│   ├── sf-hook.sh
│   ├── sf-unhook.sh
│   ├── sf-update-secret.sh
│   ├── sf-install.sh
│   ├── sf-upgrade.sh
│   ├── sf-prepush.sh
│   ├── sf-precommit.sh
│   └── sf-metasync.sh
├── lib/
│   └── common.sh               ← 全スクリプト共通ライブラリ
├── phases/
│   └── init/                   ← sf-init.sh のフェーズスクリプト
│       ├── init-common.sh
│       ├── add_tier.sh          ← --add-tier オプションで呼ばれる tier 追加スクリプト
│       ├── 01_check_env.sh
│       ├── 02_project_info.sh
│       ├── 03_repo_create.sh
│       ├── 04_gen_files.sh
│       ├── 05_setup_branches.sh
│       ├── 06_pat_token.sh
│       ├── 07_slack.sh
│       ├── 08_initial_commit.sh
│       ├── 09_repo_rules.sh
│       └── 10_sf_auth.sh
├── hooks/
│   ├── pre-push                ← sf-hook.sh がプロジェクト側へコピー
│   └── pre-commit
├── templates/                  ← force-* プロジェクトの雛形（sf-tools/templates/ が唯一の正本）
│   ├── .forceignore
│   ├── .gitattributes
│   ├── .gitignore
│   ├── .prettierignore / .prettierrc
│   ├── .github/
│   │   └── workflows/          ← 自己完結型 CI/CD ワークフロー
│   ├── .vscode/
│   ├── config/
│   ├── eslint.config.js
│   ├── force-app/
│   ├── package.json
│   ├── scripts/
│   ├── sfdx-project.json       ← __REPO_NAME__ プレースホルダーあり
│   ├── sf-start.sh / sf-restart.sh
│   └── sf-tools/
│       ├── config/             ← metadata.txt / branches.txt 雛形
│       └── release/__BRANCH__/ ← deploy-target.txt / remove-target.txt 雛形
├── doc/
│   ├── setup-guide.md
│   └── sf-cicd-strategy.md
├── tests/                      ← 単体テスト一式
│   └── e2e/                    ← 実環境での通し検証（sf-init の自動実行。9.3 参照）
├── CLAUDE.md
└── README.md
```

---

## 8. 設計方針

- シンプルなコマンドで毎日の作業を自動化する
- 失敗時はログで原因を追いやすくする
- 追加依存を減らし、Git Bash（Windows）と GitHub Actions（Ubuntu）を検証対象に、macOS / WSL でも動くクロスプラットフォーム構成を維持する
- まず dry-run を基本にし、必要時のみ本番実行する
- Bash 4.3 以上を必須とし、互換ハックより環境アップグレードを優先する（コード品質・メンテナンス性を守るため）

---

## 9. 開発・リリースの流れ（sf-tools の開発者向け）

sf-tools の `main` ブランチは、**そのまま全ユーザーに配布される**ブランチです。各ユーザーの `~/sf-tools` は `git pull` で `main` を取り込みます。そのため、修正はいきなり `main` に入れず、次の順で進めます。

| 手順 | 内容 |
|---|---|
| 1. 修正 | `development` ブランチで修正し、`bash tests/run_tests.sh` を全件 PASS させる（`mm`：`development` までコミット・push） |
| 2. 検証 | 検証環境の `force-*` で実際に動作を確認する（下記） |
| 3. リリース | 検証 OK を確認してから、`development` → `main` の PR をマージする（`rr`）。これが配布になる |

### 9.1 検証環境とは

`sf-init.sh` の Phase 2 で「検証環境」を選んだ `force-*` のことです。そのリポジトリの GitHub Actions は、sf-tools の `main` ではなく `development` ブランチを使います（Variable `SF_TOOLS_BRANCH=development`）。開発者の `~/sf-tools` を `development` にしておけば、ローカルのコマンドも同じ内容で動きます。

### 9.2 検証で確認すること

変更内容に応じて確認します。詳細は `doc/dev-reference.md` セクション 9 を参照してください。

- 新規セットアップ（`sf-init.sh`）が最後まで通ること。9.3 の e2e で自動化できます
- メタデータ同期（`wf-metasync`）を手動実行して成功すること
- デプロイ対象を含む PR で `wf-validate` が通ること（動作確認だけの PR はマージせずに閉じる）

> ℹ️ `sf-tools` は公開リポジトリのため、`main` のブランチ保護を、GitHub の無料プランでも設定できます（以前の Private リポジトリでは設定できませんでした）。**設定済みです**（Ruleset `protect-main`: 削除の禁止、強制プッシュの禁止、直接のプッシュの禁止で PR 経由のみ。承認者の人数は 0 人）。GitHub Actions は、実行のたびに sf-tools の `main` を取得して、その中のコードを、秘密鍵を持つ環境で実行するため、`main` を誰が書き換えられるかが、最も重要です。変更は、引き続き、運用（mm / rr）を守ってください。設定は、リポジトリの **Settings → Rules** で確認・変更できます。

### 9.3 e2e: `sf-init.sh` の通し検証を自動で行う

`sf-init.sh` を検証するたびに、Token の作成、Slack の設定、Salesforce へのログイン、前回のテスト用リポジトリの削除などを手作業で繰り返すのは大変です。`tests/e2e/` は、これを自動化します。実際の GitHub と Salesforce を使うため、通常のテスト（`bash tests/run_tests.sh`）には含まれず、開発者が手動で実行します。

**仕組み:** `sf-init.sh` 自体は変えません。質問への答えを標準入力に流し、`sf org login web`（ブラウザでのログイン）だけを「認証 URL でのログイン」に差し替え、ブラウザは開かないようにします。それ以外（リポジトリの作成、外部クライアントアプリの作成、JWT のログイン、Secret の登録など）は、本物がそのまま動きます。

**最初の 1 回だけ（手動）:**

```bash
gh auth refresh -h github.com -s delete_repo   # テスト用リポジトリを削除するための権限
bash tests/e2e/bootstrap.sh                    # 鍵一式（Token など）を、リポジトリの外に保存する
```

`bootstrap.sh` では、Classic PAT、Slack の Bot Token と通知先の共有チャンネルの ID を入力し、ブラウザでテスト用の Salesforce 組織にログインします（認証 URL を取得して保存するため）。これらは `~/.sf-tools-e2e/fixture.env` に、本人だけが読める権限で保存され、リポジトリには入りません。テスト用の組織は、本番または Developer Edition（Sandbox ではない）にしてください。

**毎回の実行:**

```bash
bash tests/e2e/run.sh
```

| 順 | 内容 |
|---|---|
| 1. 前掃除 | 前回の失敗で残ったテスト用のもの（名前が決まった形式で、オーナーが一致するものだけ）を削除する |
| 2. 実行 | `force-e2e-日時` というリポジトリを作り、`sf-init.sh` を Phase 1〜10 まで自動で実行する（検証環境・main のみの構成） |
| 3. 確認 | Secret・Variable・ブランチ・ワークフローが揃っていること、Token が画面・ログに出ていないこと、`wf-metasync` と `wf-release`（JWT ログイン・sf-tools の取得（公開リポジトリを Token なしで clone）・Slack 通知）が動くことを確認する |
| 4. 後掃除 | テスト用のリポジトリ、Salesforce の外部クライアントアプリ、ローカルのフォルダを削除し、`sf` のエイリアスを実行前の状態に戻す |

テスト用のリポジトリは毎回別の名前（`force-e2e-日時`）なので、前回の削除が終わっていなくても実行できます。`--keep` を付けると後掃除をしないので、失敗の原因を調べられます。残ったものは、次のコマンドで確認・削除できます。

```bash
bash tests/e2e/cleanup.sh          # 削除対象の一覧を表示するだけ（何も削除しない）
bash tests/e2e/cleanup.sh --yes    # 一覧を見せたうえで、delete と入力すると削除する
```

**途中で止まったとき（ウィンドウが閉じた、など）:** テスト用のリポジトリやアプリ、認証 URL を含む一時フォルダ（`/tmp/e2e-run.*`）が、残ることがあります。次の実行の最初に、自動で掃除されます。すぐに片付ける場合は、`cleanup.sh --yes` を実行してください。ただし、**30 分以内に作られた一時フォルダは、別の実行の途中かもしれないため、掃除の対象外**です（認証 URL が入っているので、気になる場合は、手動で削除してください）。

**一覧を取得できなかったとき:** 削除の前に、テスト用のものの一覧を取得します。取得に失敗した場合は、数回やり直し、それでも取れなければ「対象なし」とは表示せず、エラーとして終わります（削除し損ねたのに「成功」と報告しないためです）。エラーになったときは、時間をおいて `cleanup.sh` を実行してください。

**認証 URL について:** 新しい `sf` は、`sf org display --verbose` で認証 URL を隠します。`bootstrap.sh` は、`sf org auth show-sfdx-auth-url` で取得し、形式が正しくない値は保存しません。

**安全のために:** 削除できるのは、`force-e2e-YYYYMMDD-HHMMSS` のようなテスト用の名前のものだけです。`SF_TOOLS`（元からあるアプリ）や、ふだん使っているリポジトリは、削除の対象になりません。オーナーも、鍵一式で指定したものだけです。GitHub Actions 上では動きません。

**できないこと:** Token の作成と、テスト用組織への最初のログインは自動化できません（最初の 1 回だけ手動です）。また、`sf-init.sh` の質問の順番を変えたときは、`tests/e2e/lib.sh` の入力の台本（`e2e_make_input`）も直す必要があります（直し忘れは、通常のテストで検知されます）。

---

## 10. ライセンス

`sf-tools` は、公開リポジトリです。ライセンスは、制限のない「パブリックドメイン」（The Unlicense。`LICENSE` を参照）で、誰でも自由に、コピー・改変・公開・使用・販売できます。無保証です。

- GitHub Actions は、`sf-tools` を Token なしで clone します（`SF_TOOLS_TOKEN` は不要です）。
- `sf-tools` に、認証情報や個人の秘密情報を含めないでください（履歴を含め、すべて公開されます）。
