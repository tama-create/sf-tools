# sf-tools — Salesforce 開発自動化ツールキット

> **本ドキュメントの範囲:** sf-tools の機能概要・使い方・スクリプト一覧。実装の詳細（フロー・ファイルパス等）はコードのヘッダーコメントを正とします。

Salesforce 開発で毎回発生する環境構築、デプロイ、事前チェック、メタデータ同期をまとめて自動化するシェルスクリプト集です。
`~/sf-tools` に配置し、各 Salesforce プロジェクト (`force-*` ディレクトリ) から呼び出して使います。

---

## 1. 前提条件

> ⚠️ **動作確認ずみの環境**（実際に動かして確かめたものだけを書いています）
>
> | 環境 | 使う場面 | 確認した内容 |
> |---|---|---|
> | **Windows**（Git Bash） | 手元のパソコン（開発者・管理者） | ✅ 自動テストに合格。さらに、実際の GitHub と Salesforce を使って、初期セットアップから、Salesforce へのリリース・削除まで、最初から最後まで動かして確認しました |
> | **Mac**（macOS） | 手元のパソコン | ✅ 同じ確認を、Mac mini の実機で行いました |
> | **WSL**（Windows の中の Ubuntu） | 手元のパソコン | ✅ 同じ確認を行いました |
> | **Linux**（GitHub Actions のサーバー） | 自動で動く部分（人は触りません）: 変更の検証・Salesforce へのリリース・メタデータの同期 | ✅ 実際の Salesforce に対して、検証・リリース・同期が成功することを確認しました |
>
> - 確認に使った Salesforce は、**Developer Edition**（開発者向けの無料の組織）です。ほかのエディション（Enterprise など）や Sandbox では、確認していません。
> - **自動テスト**とは、プログラムの各部分が正しく動くかを、機械が確かめるものです。GitHub 上で、変更のたびに自動で実行され、Linux・Mac・Windows の 3 つの環境で、合格しています。
> - Linux を、手元のパソコンとして使うことは、想定していません（Linux は、自動で動くサーバーとしてだけ使います）。
> - Mac は、標準のターミナル（zsh）と標準の Bash のままで動きます。Homebrew などで、Bash を入れ直す必要はありません。
> - いつ、どの環境で確認したかの記録は、開発者向けの資料（`doc/dev-reference.md` の 9.7）にあります。

以下のコマンドが使えること。

| ツール | 確認コマンド | 用途 | 取得先 | Windows インストール方法 |
|---|---|---|---|---|
| Git (Git Bash) | `git --version` | Git Bash / フック / バージョン管理 | https://git-scm.com/download/win | インストーラ実行 |
| Salesforce CLI（**npm 版**） | `sf --version` | 組織接続、デプロイ、retrieve | https://developer.salesforce.com/tools/salesforcecli | `npm install -g @salesforce/cli`（Node.js が必要。**公式インストーラー版は非対応**。1.1 参照） |
| GitHub CLI | `gh --version` | PR 作成・Secrets 登録・リポジトリ操作 | https://cli.github.com/ | `winget install --id GitHub.cli` |
| Visual Studio Code | `code --version` | エディタ起動 | https://code.visualstudio.com/ | `winget install --id Microsoft.VisualStudioCode` |
| Slack | — | デプロイ通知の受信 | https://slack.com/downloads/windows | インストーラ実行 |

> Bash 3.2 以上で動きます（Windows は、Git for Windows の Git Bash。macOS は、標準の `/bin/bash` のままで動きます）。

補足:
- Windows は、Git Bash で実行してください（PowerShell / コマンドプロンプトは非対応）。macOS は、標準のターミナル（zsh）から、そのまま実行できます
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

シェルの設定ファイルに以下を追加すると、どこからでもスクリプト名だけで呼び出せます。

| 環境 | 設定ファイル |
|---|---|
| Windows（Git Bash）・Linux | `~/.bashrc` |
| macOS（標準のターミナル = zsh） | `~/.zshrc` |

```bash
# sf-tools
export PATH="$HOME/sf-tools/bin:$PATH"
```

追加後に `source ~/.bashrc`（macOS は `source ~/.zshrc`）で反映します。

---

## 3. 使い方

#### 3.0.1 プロジェクトと、フォルダの構成

| 呼び方 | 内容 |
|---|---|
| **プロジェクト** | `force-XXXX`（リポジトリのクローン。VS Code で開く単位）。**`force-` は固定、`XXXX` は管理者が決める名前**（例: `acme` → `force-acme`） |
| **作業単位** | プロジェクトの**直上のフォルダ**（`JOB-xxx` / `admin` など）。同じ `force-XXXX` を、同時に複数、別々の作業として開くための入れ物 |
| **作業フォルダ** | 作業単位のフォルダを置く場所。**どこでもよい**（`sf-init.sh` / `sf-job.sh` は、ここで実行する） |

```
{作業フォルダ}\                    ← 好きな場所・好きな名前（おすすめ: C:\sf や ~/sf のような、短い名前）
├── admin\force-acme\              ← 管理者用（sf-init.sh が作る。メンテナンス用として残す）
├── admin\force-beta\              ← 別のプロジェクトも、同じ admin に置く
├── JOB-20261016\force-acme\       ← ジョブごとのクローン（sf-job.sh が作る）。同じ force-acme を、同時に複数開ける
└── JOB-20261017\force-beta\       ← 別のプロジェクトを、同じ作業フォルダに置いてもよい
```

**どのプロジェクトか（オーナーと XXXX）は、フォルダの名前では決まりません。** 次の順で決めます。

| コマンド | 決め方（上にあるものが優先） |
|---|---|
| `sf-init.sh`（管理者） | ① 引数 `--owner` / `--project` → ② 対話: オーナーは `gh` のログインから候補を出す（1 つなら自動・複数なら番号で選ぶ）。**XXXX は、管理者が入力**する（「force- は自動で付きます。XXXX の部分だけを入力してください」と案内し、すでにあるプロジェクトの一覧を、参考に表示する） |
| `sf-job.sh`（開発者） | ① 引数 `--owner` / `--project` → ② 作業フォルダの下にあるクローンの **`git remote`**（クローンした時点で、Git が記録した住所から、オーナーとリポジトリ名を読む。1 種類なら自動、複数なら番号で選ぶ）→ ③ 対話 |

- `sf-init.sh` を実行すると、管理者用の作業フォルダは **`admin`**（固定）になります。複数のプロジェクトを、同じ `admin` に作ってもよく、途中経過のファイルは、プロジェクトごとに分かれます（`.sf-init-XXXX.env` / `.sf-init-XXXX.progress`。途中で止まったときの続きに使い、**セットアップが完了すると削除されます**。完了済みかどうかは、クローンの `git config sf-tools.setup-complete` で判定します）。`admin` フォルダのクローンは、削除せず、更新・接続の確認・やり直しなどの、管理者のメンテナンスに使います。
- `sf-job.sh` は、管理者用の作業フォルダ（`admin`）と `force-*` の中では、実行できません。作業フォルダで実行してください。

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

作業フォルダ（どこでもよい）で実行します。

```bash
sf-init.sh                                  # 対話: オーナーを選び、XXXX（force- の後ろ）を入力
sf-init.sh --owner my-org --project acme    # 引数で指定（対話なし）→ my-org/force-acme を作る
```

- `--project` には、**XXXX だけ**を指定します（`force-` は自動で付きます。`force-acme` と書いても、`acme` として扱います）。**XXXX に使える文字**: 英数字と、区切り（`-` `_` `.`）。区切りは、英数字の間に 1 つだけ（`a--b`・末尾の `-` は不可）、50 文字までです（外部クライアントアプリの名前が、Salesforce の API 名の制約を満たすため）。**同じ作業フォルダでは、同じ XXXX で、別のオーナーのプロジェクトは作れません**（`admin/force-XXXX` が、別のリポジトリのクローンだと、中断します）。`admin` や `force-*` の中では、実行できません（作業フォルダで実行してください）

以下を自動実行します。

1. 環境チェック（ツール・GitHub CLI 認証）
2. プロジェクト情報（オーナーとプロジェクト名 XXXX）の確認と環境種別の選択（通常は「1. 本番環境」。「2. 検証環境」は sf-tools の開発者専用で、選択すると確認が出ます。あわせて `~/sf-tools` が最新かを確認し、遅れていれば更新して中断します）
3. GitHub リポジトリ作成・clone
4. ワークフロー・設定ファイル生成
5. ブランチ構成
6. PAT_TOKEN の設定（force-* のリポジトリの**オーナー（組織なら管理者）のアカウント**で発行した Classic PAT を貼り付けます。発行済みの Token があれば、ブラウザは開かず、そのまま貼り付けられます。貼り付けた Token は、画面に表示されず、スコープ（`repo`・`workflow`）とリポジトリの管理者であることを、GitHub に問い合わせて確認します。違えば、貼り直せます）
7. Slack 連携の設定（通知先は、全員が参加する共有チャンネルを Slack で事前に作成しておく。DM は使えません）
8. 初回コミット＆プッシュ
9. GitHub リポジトリ設定・Ruleset 適用
10. JWT 認証情報（Salesforce → GitHub Secrets / Variables）の設定（外部クライアントアプリは、ブラウザでログインするだけで自動作成）
11. **最初のメタデータの同期**（Phase 10 のあと）: `wf-metasync` を実行して完了を待ち、同期した内容を、管理者用のクローン（`admin/force-XXXX`）に `git pull` します（数分。組織の大きさで伸びます）。**セットアップが終わった瞬間に、Salesforce のメタデータが、GitHub の `main` にも、手元のクローンにも、全部入っています**（初期コミットの `force-app` は、空のひな型です）。同期に失敗しても、セットアップは成功のままで、完了画面に、すぐ同期する方法が出ます（定期実行は、平日 3 時間おきです）。

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

作業フォルダで実行します。

```bash
sf-job.sh                          # 作業フォルダの下のクローンから、プロジェクトが決まる（複数なら、番号で選ぶ）
sf-job.sh --project acme           # プロジェクトを指定する（force-acme）
```

ブランチ名の入力だけで、以下をすべて自動実行します。

1. ジョブ名（例: `JOB-20260323`）でブランチを作成
2. 作業ディレクトリを準備（worktree または clone）
3. `sf-start.sh` を自動起動（ログイン・フック設定・VS Code 起動）

> **Windows のパス長について:** クローンは `core.longpaths=true` 付きで行います（Windows のパスの長さの上限（260 文字）対策）。組織に長い名前のメタデータ（例: DevOps Center の `objectTranslations`）があっても、チェックアウトに失敗しません。この設定はクローン先に残るので、以降の `git add` / `commit` / `push` にも効きます。

### 3.4 作業を再開する（sf-start）

前日の続きなど既存ブランチで再開するときは `force-*` ディレクトリ内で実行します。

```bash
sf-start.sh
```

| | sf-job | sf-start |
|---|---|---|
| 実行場所 | 作業フォルダ（作業単位を置く場所） | `force-*` ディレクトリ内 |
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

カレントディレクトリ配下の変更をまとめてコミット＆プッシュします。コミットメッセージは VS Code で入力します。main との差分も自動で取り込みます。プッシュだけ失敗したときは、もう一度実行すれば、未プッシュのコミットが送られます。

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
| 開発者 | `sf-hook.sh` / `sf-unhook.sh` | 手元のクローンの、検証フックの有効化 / 削除 | ランチャー外 |
| 管理者 | `sf-update-secret.sh` | ⚠️ GitHub Secrets の再登録（管理者のみ） | ランチャー外 |
| 管理者 | `sf-sync-wf.sh` | ⚠️ 作成済みのワークフローを、雛形に合わせて更新 | ランチャー外 |
| 管理者 | `sf-init.sh --verify` | ⚠️ 実際のリポジトリ・組織で、リリースと削除が動くことを検証（Hello World） | ランチャー外 |
| 管理者 | `sf-typecheck.sh` | ⚠️ 個人用の組織で、メタデータの種類ごとに、リリースと削除ができるかを確かめ、可否の表を作る（`--coverage`: 変更セットで扱える種類のうち、確認済み・未確認の数を表示。組織には接続しない） | ランチャー外 |
| — | `sf-install.sh` | sf-start から自動実行 | 自動実行 |
| — | `sf-upgrade.sh` | sf-install から自動実行 | 自動実行 |
| — | `sf-prepush.sh` | git pre-push フックから自動実行 | 自動実行 |
| — | `sf-precommit.sh` | git pre-commit フックから自動実行 | 自動実行 |
| — | `sf-metasync.sh` | ⚠️ GitHub Actions から自動実行（ローカル実行時は管理者のみ） | 自動実行 |

### 4.2 `sf-job.sh`

```bash
sf-job.sh
```

新しい作業（ブランチ）を始めるときのオールインワンスクリプトです。作業フォルダ（作業単位のフォルダを置く場所）で実行します。

主な処理:
- ジョブ名（例: `JOB-20260323`）を入力してブランチを生成
- `git worktree` または `git clone` で作業ディレクトリを作成
- `sf-start.sh` を自動起動（ログイン・フック設定・VS Code 起動）

補足:
- ブランチ作成から VS Code 起動まですべて自動のため、**新規作業は必ずここから始める**
- 環境ブランチ・管理者用のブランチの名前（`main` / `staging` / `develop` / `admin`）は、ジョブ名に使えません
- GitHub 上に、同名のブランチがすでにあるときは、最後のコミットの作者・日時を表示して、確認します（`Y`: そのブランチを使って続ける = ブランチ作成のあとに clone が失敗した、前回のジョブの続き / `N`: 別のジョブ名）。ほかの人のジョブのブランチなら、`N` にしてください
- `--project` だけを指定して、同じプロジェクト名のクローンが、複数のオーナーにあるときは、最初のものを黙って使わず、オーナーを選ばせます
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
| `--resume N` | Phase N から、質問なしで再開（通常は、指定不要です。下記「途中で止まったとき」）。**完了済みのプロジェクトでは、拒否されます**（接続処理などを、確認なしで、やり直さないため）。動作の確認（最後のステップ）は、聞きません |
| `--only N` | Phase N のみ実行（デバッグ用）。進捗は更新しません（開始時に、その旨を表示します）。動作の確認は、聞きません |
| `--add-tier staging` | 既存プロジェクトに staging 階層を追加 |
| `--add-tier develop` | 既存プロジェクトに develop 階層を追加（`main` へは直接 push せず、PR を作成します） |
| `--reconnect <段階>` | 1 つの段階（main / staging / develop）の、接続先の Salesforce 組織を付け替える（`force-*` 内で実行） |
| `--status` | **セットアップの診断**（リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているか。不足は、直し方つきで表示）と、段階ごとの接続先（ログイン先・組織の種類・ユーザー・組織 ID・最終確認日時）の一覧（読み取りのみ。`force-*` 内で実行。不足があれば、終了コード 1） |
| `--verify` | **動作の確認**（実際のリポジトリ・組織に、Hello World を、リリースして、削除します。環境全体の確認も、最初に行います）。`force-*` フォルダの中で実行します。`--plan`（実行内容の表示だけ）・`--cleanup`（削除のみ）・`--no-metasync` と一緒に指定できます。詳しくは 4.21 |
| `--legacy-connected-app` | 従来の接続アプリケーション（今後廃止予定。手動の入力）を使う。既定は、外部クライアントアプリ（自動で作成） |

**Salesforce 組織の接続（段階と組織の種類は、結びつけません）:** main / staging / develop のどの段階にも、本番・Sandbox・Developer Edition などを、自由につなげます（main に Sandbox や Developer Edition でも構いません）。ただし、**Salesforce の本番組織は、main にしかつなげません**（staging・develop に本番をつなごうとすると、ログイン後に、組織の種類を読み取って、中断します）。
- 段階ごとに、**ログイン先**を、次の 3 つから選びます（Enter は 2）。種類ではなく、URL で選びます。
  1. `https://login.salesforce.com` — 本番・Developer Edition・Trial など
  2. `https://test.salesforce.com` — Sandbox（**安全なおすすめ**。本番に影響しません）
  3. 組織の URL を入力（My Domain。例: `https://会社名.my.salesforce.com`）
- ログイン後に、組織の ID・名前・種類（本番 / Sandbox / Developer Edition / Trial）を、**組織から読み取って**、表示・保存します。
- あとから付け替えるときは `sf-init.sh --reconnect <段階>`、いまの状態を見るときは `sf-init.sh --status` です（`force-*` フォルダの中で実行します）。`--status` は、「どこで間違えたか分からない」ときの最初の手がかりです。✓（できている）・✗（不足。直し方を表示）・！（注意）・？（確認できず）で、項目ごとに表示します。Salesforce 側（外部クライアントアプリ・JWT 接続）は、ログインが必要なため確認しません。直近の wf-metasync / wf-release が成功していれば、接続はできています。

**画面の流れ（ウィザード形式）:** 実行すると、はじめに、作るもの・かかる時間の目安・**先に用意するもの**（GitHub の管理者のブラウザ、Slack の共有チャンネル、Salesforce の管理者アカウント）・全 9 ステップの一覧が表示されます。用意ができたら Enter を押します（q で中断）。各ステップの先頭には、「ステップ n / 9」と、完了したステップ・そのステップの目的が表示されます。終わると、**できたことと、次にやること**（`sf-job.sh` の実行など）と、**管理者用フォルダ**（`admin` フォルダ。削除せず、残します）の場所が表示されます。`~/sf-tools` が古いときは、確認のうえ更新し、**自動で、はじめから実行しなおします**（もう一度の実行は、不要です）。

**途中で止まったとき（続きから）:** どの Phase まで進んだかを、利用者が覚えておく必要はありません。止まったら、**同じフォルダで、もう一度 `sf-init.sh` を実行**してください。前回の状態が残っていれば、次の選択肢が表示されます。

```
前回のセットアップは、「ブランチの構成」まで完了しています（2026-10-11 14:32）。（owner/force-xxx）

    [1] 「GitHub の Token」から、続きをやる   ← おすすめ
    [2] 最初からやり直す（作成済みのリポジトリ・admin フォルダは、そのまま使います）
    [q] 中断
```

- **[1]** 保存済みの入力内容（環境種別・ブランチ構成など）を使い、失敗した所から再開します（最初の環境チェックは、毎回行います）。
- **[2]** 保存した状態を消して、Phase 1 から始めます。作成済みのリポジトリと `admin` フォルダは、削除せず、そのまま使います。
- **最後のステップ（ステップ 9: 動作の確認・任意）**: Phase 10 のあとに、「動作を確認しますか？ [Enter = 確認する / s = あとで]」と聞きます。Enter なら、`sf-init.sh --verify`（環境全体の確認 → Hello World のリリースと削除。約 20 分（3 層の場合））を、続けて実行します（確認は、ここの 1 回だけです）。確認で失敗があっても、セットアップは完了扱いです（結果と、直し方が表示されます）。**聞くのは、通しの実行と、中断後に「続きをやる」を選んだときだけ**です（`--resume N` / `--only N` では、聞きません）。端末でない実行（テスト・e2e）でも、聞きません。
- **Phase 10（Salesforce の接続）は、段階ごとに、完了を記録します。** 途中（例: staging）で失敗しても、「続きをやる」では、完了した段階（main など）は、スキップし、残りの段階だけを実行します（ブラウザのログインを、やり直さなくて済みます。登録した Secret が、いまもあるときだけ、スキップします）。
- 前回が最後まで完了している場合は、「セットアップが、すでに完了しています」と表示され、**[1] いまの Salesforce の接続を見る（何も変更しません）／[2] 動作を確認する（`sf-init.sh --verify`）／[3] 最初からやり直す／[q] 終了** を選べます。別のリポジトリの状態の場合は、選択肢は出ず、最初から始まります。
- **`admin` フォルダは、管理者用のフォルダとして残します**（以前あった、削除の質問は、廃止しました）。ワークフローの更新（`sf-sync-wf.sh`）・接続の確認（`--status`）・接続先の付け替え（`--reconnect`）など、管理者のメンテナンスに使います。日常の開発には使いません（開発は、`sf-job.sh` の作業フォルダで行います）。
- **管理者用のクローンは、セットアップの最後に、`admin` ブランチになります**（`main` から作り、GitHub にも `git push -u origin admin` で作ります。強制 push はしません）。`main` は保護ブランチのため、その上で作業しないようにするためです（`sf-sync-wf.sh` も、保護ブランチでは実行を断ります）。管理者の変更は、「`main` を取り込む → 変更する → push → PR」で GitHub に反映するため、最初から、ローカルと GitHub の両方に、同じ `admin` を置きます。**`admin` は、`main` から古くなります。使う前に、`main` を取り込んでください**（`git pull origin main`）。`--add-tier` は、終わったら、実行前のブランチ（`admin`）に戻ります。`admin` ブランチがすでにあるときは、作り直さず、そこへ切り替えます（作業を消しません）。作れなかったとき・push できなかったときは、完了画面に出るとおり、管理者用フォルダで `git switch -c admin`（作れなかったとき）・`git push -u origin admin`（push できなかったとき）を実行してください（セットアップ自体は、成功のままです）。
- Token の入力欄は、貼り付けた文字の数だけ `*` を表示します（Token の中身は、画面に出ません）。Git Bash は、**右クリック**（または Shift+Insert）で貼り付けます。Enter のあと、「N 文字を受け取りました（先頭: ghp_…）」と表示されるので、コピーできたかを確認できます。
- 管理者向けの警告と確認は、どちらの場合も、毎回表示されます。

補足:
- 通常の初期セットアップは `force-*` ディレクトリの外で実行します
- `--add-tier` は **`force-*` ディレクトリ内**で実行します（初回のセットアップとは、処理の順序が逆です: 段階の追加では、先に Salesforce に接続し、成功してから、ブランチと PR を作ります。接続に失敗したときに、GitHub 側を、変更しないためです）
- Salesforce ログイン、PAT 作成、Slack 設定など一部は対話操作が必要です

#### 4.4.1 GitHub Secrets と Variables の使い分け

sf-init.sh が登録する認証情報は、機密性に応じて **Secret（暗号化）** と **Variable（平文）** に分けて管理します。

| 項目 | 種別 | 説明 |
|---|---|---|
| `SF_PRIVATE_KEY` | Secret | JWT 署名用 RSA 秘密鍵 |
| `SF_CONSUMER_KEY_*` | Secret | Connected App のコンシューマキー |
| `PAT_TOKEN` | Secret | GitHub Personal Access Token（Classic。`repo`・`workflow`。force-* のリポジトリのオーナー・組織の管理者のもの。sf-tools（公開リポジトリ）とは関係ありません） |
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

#### 4.5.1 表示ステータス一覧

| 記号 | ステータス | 説明 |
|---|---|---|
| `✓` | マージ済み | 直接 PR をマージ済み（デプロイ WF 実行済み） |
| `✓` | マージ済み（ブランチ同期） | 直接 PR はないが上位ブランチ経由でコード伝播済み。**デプロイ WF は未実行** |
| `⚠` | マージ済み（順序外） | 前のブランチの直接 PR が完了する前にマージ済み。**前のブランチのデプロイは未実行** |
| `→` | PR発行中 | PR を発行済み（マージ待ち） |
| `▶` | 次のPR先 | 次に PR を出すべきブランチ |
| `✗` | 未着手 | まだ PR を出していない |

#### 4.5.2 判定方法

1. `gh pr list --state merged` で現在ブランチ → 対象ブランチへの**直接 PR** を確認 → `マージ済み`
2. `git merge-base --is-ancestor` で間接伝播（上位ブランチ経由）を確認 → `マージ済み（ブランチ同期）`
3. `gh pr list --state open` で PR 発行中を確認 → `PR発行中`
4. いずれも該当なし → `次のPR先` / `未着手`

#### 4.5.3 順序外マージの制約

`develop → staging → main` の順番を守らずにマージした場合、スキップしたブランチへのデプロイは**永久にできません**。

- 上位ブランチ（例: main）にマージすると、コードが下位ブランチ（例: staging）に伝播する
- 伝播後は「差分なし」となり、feature → staging の直接 PR が作成できなくなる
- GitHub Actions のデプロイ WF は直接 PR のマージイベントで起動するため、伝播では WF が動かない

**スキップしたブランチにデプロイしたい場合は、新しいブランチを切って改めて順序通りに PR を出し直す必要があります。**

**順序外の PR を、レビュアーが見つけられる仕組み（`wf-sequence`）:**

`sf-next.sh` を使う限り、PR 先は「次の段階」だけです。ランチャーを使わず、GitHub 上で直接 PR を作って、段階を飛び越した場合は、PR を作った時点で、次のように、レビュアーに知らせます。

| 通知先 | 内容 |
|---|---|
| PR の会話欄 | 「⚠️ マージ順序の確認が必要です。意図的でなければ、この PR は却下してください」というコメント（同じ PR では、既存のコメントを更新） |
| Slack | 通知 |

- マージは、止めません（緊急の Hotfix を妨げないため。Free プランの Private リポジトリでは、GitHub が、そもそも止められません）。**気づいたレビュアーが、PR を却下します。**

#### 4.5.4 補足

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
- `deploy-target.txt` に記述した `.cls` ファイルに `@isTest` アノテーションがあれば自動検出し、`--test-level RunSpecifiedTests --tests <クラス名>` を自動設定します（ユーザーが手動で指定する必要はありません）

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
- `[files]` セクション: 記述したパスがリポジトリ内に存在するか（絶対パス・`..` を含むパスなど、リポジトリの外を指すパスは、存在していてもエラー）
- `[members]` セクション: `種別名:メンバー名` の書式になっているか
- **種類の可否**: `config/metadata-capability.txt`（`sf-typecheck.sh` が実際の組織で確かめた表）で、API でリリース・削除できないと確認済み（`ng`）の種類を書くと、エラーにします。条件によって、できないことがある種類（`limited`。権限・使用中・標準のもの など）は、警告にします。組織の権限で、できる場合は、環境変数 `SF_CHECK_IGNORE_CAPABILITY=1` で、この確認を省略できます
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
- 変更がなくても、前回の同期のコミットの push が失敗して、未プッシュのコミットが残っているときは、確認のうえ、push だけ行います
- main への push は、pre-push フックを通しません（`--no-verify`。このコマンド専用。GitHub の保護の設定は、そのまま効きます）

主に GitHub Actions からの定期実行を想定しています。

> ⚠️ **管理者専用**: 実行前に赤い警告ボックスと確認プロンプトが表示されます。`GITHUB_ACTIONS=true` の場合はスキップして自動実行します。

#### 取得するメタデータの種類（`sf-tools/config/metadata.txt`）

取得する種類は、各プロジェクトの `sf-tools/config/metadata.txt` で決まります（`sf-init` が、雛形から作ります）。設定ファイルだけで調整でき、コードの変更は不要です。

**前提**: 雛形の標準セットは、**Developer Edition（Sales・Service の標準機能つき）でのみ、リリースと削除を確認**しています。ほかのエディション・製品（Service Cloud・Experience Cloud・業種クラウドなど）で使う場合は、必要な種類を足してください。

| 区分 | 既定 | 内容 |
|---|---|---|
| 1. 標準セット | 有効 | Developer Edition で、リリース・削除を確認済み（Apex・LWC・オブジェクト・項目・Layout・権限・レポート・ワークフローなど） |
| 2. 標準だが制限あり | 有効 | 更新のみ・権限による・一部未確認（StandardValueSet・Flow・Settings など。理由は、ファイル内のコメント） |
| 3. 機能が必要なもの | コメントアウト | Service Cloud 系（Entitlement・Omni-Channel・Knowledge）・Experience Cloud 系。使う組織だけ、コメントを外す |
| 4. 未確認 | コメントアウト | 確認できていない種類。使う場合は、外して、リリースを確かめる |
| 5. 参考 | コメントアウト | そのほかの種類の候補（業種クラウド・AI・分析など） |

- 取得対象に、その組織に無い種類があっても、**警告になるだけ**で、取得は続きます。
- 種類ごとの確認の状況は、`sf-typecheck.sh --coverage` で見られます（変更セットで扱える種類のうち、確認済み・未確認の数）。
- リリース・削除できないと確認済みの種類は、ターゲットファイルに書くと、`sf-check.sh` が止めます（警告のみの種類もあります）。
- すでに作成済みのプロジェクトの `metadata.txt` は、雛形が更新されても、**変わりません**。

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
- `branches.txt` に、origin にまだないブランチ名があっても、push は止めません（その名前だけ取得せず、警告します）

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
- 変更がなくても、未プッシュのコミットがあれば、コミットせず、プッシュだけ行います（コミットは成功し、プッシュが失敗した後に、もう一度 `sf-push.sh` を実行すれば、取り残されません）

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


### 4.20 `sf-sync-wf.sh`

```bash
sf-sync-wf.sh            # 雛形との差分を表示し、確認のうえ、上書きする
sf-sync-wf.sh --check    # 差分があるかだけを調べる（何も変更しない）
sf-sync-wf.sh --remove wf-old.yml   # 雛形から廃止されたワークフローを削除する
```

`sf-init.sh` で作成済みの `force-*` に、あとから、ワークフロー（`.github/workflows/`）の修正（不具合の修正・安全対策など）を反映するコマンドです。sf-tools の雛形（`templates/.github/workflows/`）と、プロジェクトのワークフローを比べ、差分を表示して、確認のうえ、雛形の内容で上書きします。

> ⚠️ **管理者専用**: CI/CD（リリース・検証）の動作が変わるため、実行の冒頭に、赤い警告ボックスと確認プロンプトが表示されます（`--check` を除く）。`sf-install.sh` などから、自動では実行されません（利用者の意思なく、ワークフローが書き換わるのを防ぐためです）。

**更新の手順（推奨）**
1. `sf-job.sh` で、ジョブ名 `system-日付`（例: `system-20261006`）の作業用ブランチを作る（`main` から作られ、古くなりません。ワークフローの更新の PR だと、名前で分かります）
2. そのフォルダで `sf-sync-wf.sh` を実行し、差分を確認して Y
3. `git diff .github/workflows/` で内容を確認する
4. `sf-push.sh` でコミット・プッシュする（ワークフローをプッシュするには、`workflow` スコープのある権限が必要です）
5. PR を出して、マージする。`develop` / `staging` がある構成では、通常の変更と同じ順序（`develop` → `staging` → `main`）で PR を出します（次の PR 先は `sf-next.sh` が案内します）

**動作**
- `force-*` のフォルダの中で、環境ブランチ（`branches.txt` のブランチ。`main` / `staging` / `develop` など）以外でしか、実行できません。
- **sf-tools（`~/sf-tools`）が最新であることが必須です。** 実行のはじめに、origin と比べ、遅れていれば、確認のうえ、sf-tools を更新し、更新した sf-tools で、自動的に、もう一度、実行します（古い雛形で、プロジェクトのワークフローを書き換えないためです）。origin に接続できない・更新を断った・sf-tools に未コミットの変更や未プッシュのコミットがある場合は、中断します。`--check` は、何も変更しない（読み取り専用の）ため、sf-tools を更新せず、遅れていれば中断します。
- 改行コード（CRLF / LF）だけの違いは、差分とみなしません。
- 自動でコミット・プッシュはしません。雛形にないワークフローは、変更せず、表示するだけです（`--remove` で、雛形から廃止されたものだけ、二重に確認して削除できます。雛形にあるものは、削除できません）。
- `--check` は、差分なしで終了コード 0、あれば 1 を返します。複数のリポジトリを見回るときに使えます。

---

### 4.21 `sf-init.sh --verify`（動作の確認）

```bash
sf-init.sh --verify               # 診断 → 実行内容の表示 → 確認 → リリース → 削除 → 結果（force-* の中で実行する）
sf-init.sh --verify --plan        # 診断と、実行内容の表示だけ（何も変更しない）
sf-init.sh --verify --no-metasync # wf-metasync（Salesforce → Git の同期）の実行を、省略する
sf-init.sh --verify --cleanup     # 削除のみ（リリースの途中で止まって、組織に Hello World が残ったとき）
sf-init.sh --verify --components                  # パターン別のサンプルを、develop の組織だけに、リリースして、削除する
sf-init.sh --verify --components --validate-only  # 検証（dry-run）だけ。マージせず、組織には、何も反映しない（オブジェクト系も含む）
sf-init.sh --verify --components --with-objects   # オブジェクト系（トリガー・Layout・オブジェクト・項目）も、リリースして、削除する
```

`sf-init.sh` で作った、**実際のリポジトリと、実際の Salesforce 組織**で、リリースと削除が正しく動くことを確認します。誰も使わない、単純な Apex（Hello World: `SfToolsE2eHello` / `SfToolsE2eHelloTest`）を、各段階にリリースして、削除します。本番の組織（main）にも、リリースして、削除します。

> ⚠️ **管理者専用**: 実際のリポジトリに PR・コミットが残り、実際の組織にデプロイします。実行内容を表示したうえで、**Enter を 1 回押して**確認します（q で中断。何も変更しません）。本番（または、種類を判定できない）組織があるときは、質問の文面で、本番を含むことを明示します。

**流れ**
1. **診断**: `sf-init.sh --status` と同じ診断。不足があれば、ここで中断します（直し方が表示されます）
2. **実行内容の表示**: リポジトリ・段階ごとの組織の名前と種類（本番は、赤く表示）・PR の数・目安の時間
3. **確認**: Enter を 1 回押すだけ（sf-init と同じ Git Bash で、続けて実行する想定のため、入力は最小です。`sf-init.sh` から呼ばれたときは、sf-init が確認済みのため、聞きません）
3b. **環境の確認**（リリースの前。NG があれば、リリースへ進まず、組織には、何も変更しません）: `SF_TOOLS_BRANCH` が `main` または `development` である／ローカルのログ（`~/sf-tools/logs`）に、Token・認証 URL が残っていない／`wf-metasync`（Salesforce → Git の同期）を、手動で 1 回実行し、成功する（JWT ログイン・sf-tools の取得を含む。`main` の組織の変更が、`main` にコミットされることがあります。手前の 2 つの確認が NG のときは、実行しません）。`--no-metasync` で、`wf-metasync` の実行を省略できます
4. **リリース**: 同じブランチから、`develop` → `staging` → `main` の順（ない段階は、とばす）に、段階ごとの PR を出し、`wf-validate`（検証）→ マージ → `wf-release`。`main` へのマージのあとは、`wf-propagate` も確認します
5. **削除**: 削除用のブランチ（`remove-target.txt` と、リポジトリのクラスのファイルの削除）から、同じ順に、各段階へ。組織のクラスと、リポジトリのファイルの両方が、消えます
6. **結果**: 段階ごとの成功・失敗を表示します

**段階ごとに確認すること**: その段階の組織への JWT ログインが成功した／ほかの段階のログインのステップが、実行されていない（別の組織に入っていない）／接続ユーザー（`SF_USERNAME_*`）が登録されていて、ログに、そのユーザーが出ている／ログに、Hello World のクラス名が出ている。組織へのログインは、不要です（ワークフローの実行結果で確認します）。文言の中立化（2026-10）より前に作られたリポジトリの、古いステップ名（本番組織・ステージング組織・開発組織）も、読めます。

**注意**
- リポジトリに、PR・コミット（追加と削除）の履歴が残ります（作業用ブランチ `verify-hello-*` は、検証の最後に、自動で削除します。PR の履歴は、PR の番号で残ります。途中で止まったときは、調査のために、ブランチを残します）。Slack に、段階ごとに、数通の通知が届きます
- リリースの間、組織が、短時間、占有されます。作業の少ない時間帯に、実行してください
- ブランチ保護で、PR のマージが拒否されると、その段階で止まり、PR が残ります
- 検証用と同じ名前のクラス（`SfToolsE2eHello` / `SfToolsE2eHelloTest`）のファイルが、すでにリポジトリにあると、上書きして削除してしまうため、**実行しません**（前回の検証の残りなら、`--cleanup`）。組織だけにある同名のクラスは、検出できません。`--cleanup` は、この固定名のクラスだけを削除します
- **失敗したとき**: リリースのあとで止まった場合は、組織に Hello World が残ることがあります。残った段階と、`sf-init.sh --verify --cleanup`（削除のみ）を、表示します
- gh のアカウントは、リポジトリのオーナー（組織の管理者）にしてください

**`--components`（パターン別のサンプルの確認。develop の組織だけ）**

Hello World（Apex のみ）の代わりに、**書き方のパターンが違うコンポーネント**を、小さく 1 つずつ、develop の組織にリリースして、削除します。
全種類を試すものではなく、「種類ごとに、ターゲットファイルの書式（`[files]` / `[members]`）・パス・名前の書き方が違っても、リリースの仕組みが動く」ことの確認です。

| パターン | サンプル |
|---|---|
| 1 ファイル + `-meta.xml` | ApexClass（本体・テスト・トリガーのテスト）／ ApexTrigger |
| バンドル（フォルダ単位） | LWC（`[files]` に `.js` を指定）／ Aura（`[members]` で指定） |
| 単独の XML | Flow（Draft。**検証のみ**）／ PermissionSet |
| 名前に空白・ハイフン | Layout（`SfToolsE2eHello__c-SfToolsE2eHello Layout`） |
| フォルダ付き・名前に `$` | EmailTemplate（`unfiled$public/SfToolsE2eHello`） |
| 1 ファイルに複数メンバー | CustomLabels（リポジトリに、すでに labels のファイルがあるときは、上書きを避けるため、含めません） |
| 親子（オブジェクト系） | CustomObject（`SfToolsE2eHello__c`）／ CustomField（`Note__c`）／ ApexTrigger ／ Layout |

> **オブジェクト系**（ApexTrigger とそのテスト・Layout・CustomObject・CustomField）は、`--validate-only`（何も作らない）では、常に検証します。
> リリースと削除の通しには、**既定では含めません**（`--with-objects` で含めます）。カスタムオブジェクトは、削除すると、**15 日間、削除済みの状態で名前が予約され**、
> 同じ API 名を、ごみ箱から消すまで再作成できないためです（通しを繰り返すと、2 回目から失敗します）。

- 対象は **develop の組織だけ**です（develop・staging・main の 3 層の構成のみ。それ以外は、拒否します）。staging・本番の組織には、入れません
- 流れ: サンプルと `deploy-target.txt` を載せた PR を develop 向けに出す → `wf-validate`（dry-run）→ マージ → `wf-release`。続けて、削除を行います（既定は 1 段階。`--with-objects` のときは **2 段階**: 段階 1: トリガー・テストクラス・LWC・Aura・Flow・権限セット・メール テンプレート・labels → 段階 2: 項目・オブジェクト。参照するものを先に消すため）
- `--validate-only`: サンプルの PR を出して、`wf-validate`（dry-run）の成功を確認し、**PR はマージせずに閉じます**。組織には、何も反映しません（目安 4 分）
- 目安の時間: リリースと削除の通しで、約 7 分（`--with-objects`: 約 10 分）
- **Flow は、検証のみ（`--validate-only`）で検証し、リリースと削除の通しには含めません**: 接続ユーザーに、API で Flow を削除する権限がない組織があり（`insufficient access rights on cross-reference id`。`Flow` 型・`FlowDefinition` 型のどちらでも拒否されます）、削除できずに組織に残ってしまうためです。`--cleanup` は、リポジトリの Flow のファイルを削除します。組織に残った Flow は、画面（設定 → フロー）で、手動で削除してください
- Layout は、オブジェクトの最後の 1 つにできないため、削除対象にせず、オブジェクトの削除に任せます
- 名前は、すべて `SfToolsE2eHello` 系で、誰も使いません。ほかのファイルを、上書きしません（検証用と同名のファイルが、develop にすでにあるときは、実行しません）
- 途中で止まって、組織に残ったときは、`sf-init.sh --verify --components --cleanup`（削除のみ。`--with-objects` でリリースしたときは、`--with-objects` も付けます）で消します。失敗したときの案内にも、付けるべきコマンドが表示されます。`--cleanup` は、何度実行しても通ります（組織にすでに無いものがあっても、エラーにしません）。前回の検証が残した labels のファイル（サンプルのラベルだけのもの）も、サンプルのものとして、削除します

e2e（`tests/e2e/run.sh`）との違い: e2e は、sf-tools の開発者が、新しく作ったテスト用のリポジトリ・組織で、sf-tools 自体を確認する回帰テストです。`sf-init.sh --verify` は、管理者が、実際のリポジトリ・組織を確認するためのものです。PR と実行の待ちの部品は、共通（`lib/verify-common.sh`）です。


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
- `@isTest` アノテーションを持つ `.cls` ファイルを記述すると、`sf-release.sh` が `--test-level RunSpecifiedTests --tests <クラス名>（クラスごとに繰り返す）` を自動設定します
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
│   ├── sf-typecheck.sh
│   ├── sf-restart.sh
│   ├── sf-init.sh
│   ├── sf-hook.sh
│   ├── sf-unhook.sh
│   ├── sf-sync-wf.sh
│   ├── sf-update-secret.sh
│   ├── sf-install.sh
│   ├── sf-upgrade.sh
│   ├── sf-prepush.sh
│   ├── sf-precommit.sh
│   └── sf-metasync.sh
├── lib/
│   ├── common.sh               ← 全スクリプト共通ライブラリの窓口（ログ・実行・終了・JSON の読み取り。下の 3 つを source する）
│   ├── input.sh                ← 対話入力（read_input / read_key / press_enter / read_or_quit / read_secret / ask_yn）
│   ├── platform.sh             ← OS・外部コマンド（is_gitbash / run_isolated_home / check_sf_cli / open_browser）
│   ├── project.sh              ← プロジェクト（force-* の確認・gh のオーナー確認・ブランチ一覧・組織エイリアス）
│   ├── wizard.sh               ← ウィザード形式の画面の共通部品（sf-init で使用）
│   ├── org.sh                  ← Salesforce 組織の接続情報の共通部品（ログイン先の選択・種類の判定・本番は main のみのガード）
│   ├── diag.sh                 ← セットアップの診断（sf-init.sh --status で使用。読み取りのみ）
│   └── verify-common.sh        ← Hello World の本文・PR とワークフローの実行の部品（phases/init/verify.sh と e2e で共有）
├── phases/
│   └── init/                   ← sf-init.sh のフェーズスクリプト
│       ├── init-common.sh
│       ├── add_tier.sh          ← --add-tier オプションで呼ばれる tier 追加スクリプト
│       ├── verify.sh            ← --verify オプションで呼ばれる動作の確認（Hello World のリリースと削除）
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
├── config/                     ← sf-tools 自身の設定・データ（force-* には配布されない）
│   ├── metadata-capability.txt ← メタデータの種類ごとの、リリース・削除の可否の表（sf-typecheck.sh が確認。sf-check.sh が参照）
│   └── changeset-types.txt     ← 変更セットで扱える種類の一覧（公式の Metadata Coverage Report。sf-typecheck.sh --coverage が参照）
├── doc/
│   ├── setup-guide.md          ← 新規プロジェクトのセットアップ手順（管理者向け）
│   ├── sf-cicd-strategy.md     ← Git 運用・CI/CD の基本戦略・設計思想
│   ├── sf-tools-vision.md      ← 設計思想・競合との差別化・位置づけ（内部ドキュメント）
│   ├── wf-distribution-strategy.md ← ワークフローの配布・更新の戦略（sf-sync-wf.sh）
│   ├── jwt-auth-spec.md        ← JWT 認証方式の仕様
│   ├── wizard-ux-design.md     ← ウィザード形式（sf-init など）の UX 設計
│   ├── sf-logwatch-design.md   ← sf-logwatch.sh の設計書（未実装）
│   └── dev-reference.md        ← 実装の詳細リファレンス（AI・開発者向け）
├── tests/                      ← 単体テスト一式
│   └── e2e/                    ← 実環境での通し検証（sf-init の自動実行。9.3 参照）
├── CLAUDE.md
└── README.md
```

---

## 8. 設計方針

- シンプルなコマンドで毎日の作業を自動化する
- 失敗時はログで原因を追いやすくする
- 追加依存を減らし、Git Bash（Windows）・macOS（標準の Bash 3.2）・Linux（GitHub Actions の Ubuntu）で、同じように動くクロスプラットフォーム構成を維持する
- まず dry-run を基本にし、必要時のみ本番実行する
- Bash 3.2 以上で動かす（macOS 標準の `/bin/bash` のまま、追加のインストールなしで使えるようにするため。Bash 4 以降の機能は、使わない）

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

**新しい環境（Mac など）で動かすとき:** 先に `bash tests/e2e/doctor.sh` を実行します。必要なコマンド（`git` / `gh` / npm 版の `sf` / `node` / `openssl`）、`gh` のログインと権限、鍵一式（`fixture.env`）の有無・権限・必須の項目・作業フォルダ（`E2E_HOME_ROOT`）、JWT 用の鍵と証明書を作れるか（macOS 標準の LibreSSL の確認）を調べ、足りないものを、対処つきで表示します（何も作らず、鍵一式の値は表示しません）。すべて OK なら `bash tests/e2e/run.sh` を実行します。**WSL・Linux では、`git` の認証の仕組み（`gh auth setup-git`）と、ユーザー名・メールアドレスの設定も要ります**（無いと、リポジトリのクローンが、パスワードを待って止まる・初回のコミットが失敗する。`doctor.sh` が検出します）。**鍵一式は、安全な方法（AirDrop・USB など）で、別のマシンからコピーして `chmod 600` にしてください。チャットや Git には載せないでください。** 作業フォルダ（`E2E_HOME_ROOT`）は、そのマシンの場所に書き換えます。`run.sh` は、終わりに、「どの環境で、どのコミットを、何件確認したか」を、表の 1 行にして表示します。成功したら、それを `doc/dev-reference.md` の 9.7 に追記し、この表（README の「検証済み動作環境」）を更新します。

**最初の 1 回だけ（手動）:**

```bash
gh auth refresh -h github.com -s delete_repo   # テスト用リポジトリを削除するための権限
bash tests/e2e/bootstrap.sh                    # 鍵一式（Token など）を、リポジトリの外に保存する
bash tests/e2e/bootstrap.sh --add-orgs         # （2 層・3 層で確認するときだけ）staging・develop のテスト用組織を追加する
bash tests/e2e/bootstrap.sh --refresh-orgs     # （e2e が RefreshTokenAuthError で失敗したとき）無効になった認証 URL だけを、ログインし直して取り直す
```

`bootstrap.sh` では、Classic PAT、Slack の Bot Token と通知先の共有チャンネルの ID を入力し、ブラウザでテスト用の Salesforce 組織にログインします（認証 URL を取得して保存するため）。これらは `~/.sf-tools-e2e/fixture.env` に、本人だけが読める権限で保存され、リポジトリには入りません。テスト用の組織は、本番または Developer Edition（Sandbox ではない）にしてください。

**毎回の実行:**

```bash
bash tests/e2e/run.sh
```

既定では、**管理者が実際に行う操作と同じ流れ**で確認します（約 30 分）: `sf-init.sh` を引数なしの対話（オーナーの選択 → XXXX の入力 → 確認）で実行し、`admin` ブランチ（ローカルと GitHub）・`sf-sync-wf.sh` の動作・`sf-job.sh` の自動判定を確認し、最後に `--add-tier staging` を実行して、`admin` ブランチに戻ること・PR ができること・`main` へ直接 push しないことを確認します（鍵一式に staging の組織があるときだけ）。引数での指定に切り替えるには `--with-args`、`--add-tier` の確認を省くには `--no-add-tier` を付けます。

| 順 | 内容 |
|---|---|
| 1. 前掃除 | 前回の失敗で残ったテスト用のもの（名前が決まった形式で、オーナーが一致するものだけ）を削除する |
| 2. 実行 | `force-e2e-日時` というリポジトリを作り、`sf-init.sh` を Phase 1〜10 まで自動で実行する（検証環境・main のみの構成） |
| 3. 確認 | Secret・Variable・ブランチ・ワークフローが揃っていること、Token が画面・ログに出ていないこと、`wf-metasync` が成功することを確認する |
| 4. Hello World のリリースと削除 | テスト用の Apex クラス（`SfToolsE2eHello` と、そのテスト）を、本物の流れで、リリースして削除する（9.3.1 参照）。`wf-metasync` は、その前に実行して、完了を待つ（組織からの取得と、組織へのデプロイを、同時に行わないため） |
| 5. 終了 | `sf` のエイリアスを実行前の状態に戻す。テスト用のリポジトリ・外部クライアントアプリなどは、**既定では削除せずに残す**（あとから GitHub の画面で、Actions の実行・PR・ファイルを見返せる。終了時に、リポジトリの URL を表示する）。`--cleanup` を付けると、終了時に削除する（リポジトリ、外部クライアントアプリ、Apex クラス、ローカルのフォルダ） |

**9.3.1 Hello World のリリースと削除:** sf-tools の本来の機能（PR → 検証 → マージ → リリース、削除用の PR）を通しで確認します。

1. **通常の運用と同じく、sf-tools のコマンドで作業します。** `sf-job.sh`（ブランチ `e2e-hello` の作成・clone・`sf-start.sh`）→ Apex クラスと `release/e2e-hello/deploy-target.txt` を書く → `sf-dryrun.sh`（ローカルで検証。`@isTest` を検出して `--tests` を付ける）→ `sf-push.sh`（commit・push。`pre-push` フックも動く）。ここまでは、開発者がターミナルで行う操作と同じです（VS Code の起動・メッセージ入力、ブラウザでのログインだけを、自動化のために差し替えています）。そのあと、`gh` で PR を作ります
2. `wf-validate`（検証）が成功することを確認し、PR をマージする
3. `wf-release` が成功し（JWT ログイン・sf-tools の取得（公開リポジトリを Token なしで clone）・Slack 通知）、Salesforce にクラスができたことを確認する
   （マージ時には `wf-propagate` も動きます。`staging` / `develop` がない構成では、失敗にせずスキップして成功します）
4. リリースしたジョブのクローンで、`sf-next.sh`（マージ済みと表示されること）と、`sf-deploy.sh -t main`（共有環境への、ローカルからの強制リリースが、拒否されること）も確認します
5. 続けて、削除も、同じ道で行います。`sf-job.sh`（ブランチ `e2e-hello-delete`）→ `remove-target.txt` を書く → `sf-dryrun.sh` → `sf-push.sh` → `gh` で PR → `wf-validate` → マージ → `wf-release`。Salesforce からクラスが消えたことを確認します

ワークフローが失敗したときは、失敗したステップのログの末尾が、その場で画面に表示されます。失敗したワークフローは、Salesforce や通信側の一時的なエラーの可能性があるため、**1 回だけ自動で再実行**します（開発者が GitHub の画面で「Re-run」を押すのと同じです）。再実行で成功した場合は PASS にしますが、警告を表示し、結果にも件数を出します。再実行でも失敗したら FAIL です。

これで、Slack には、失敗ではなく、成功の通知が届きます。テスト用の組織は、Sandbox ではなく本番相当なので、**テスト用の 2 つのクラスだけ**（名前が完全に一致するもの）を、リリース・削除します。途中で失敗して組織に残ったときは、次回の前掃除（または `cleanup.sh`）が、同じ名前のものだけを削除します。実行の時間は、環境により、10〜15 分ほどです（各待ちの上限: `E2E_WF_TIMEOUT` 秒、確認の間隔: `E2E_POLL_SEC` 秒）。

テスト用のリポジトリは毎回別の名前（`force-e2e-日時`）です。終了後も残るのは、直前の 1 回分だけで、次回の `e2e` の最初（前掃除）に、自動で削除されます（Token は、GitHub の Secret として暗号化された状態です）。終了時に削除したいときは、`--cleanup` を付けます。すぐに削除したいときは、次のコマンドを使います。

**層数（段階の数）に応じた確認（`--layout`）:** **層の数だけ、別々の Salesforce 組織が必要です**（2 層 = 2 つ、3 層 = 3 つ。1 つの組織では、層数を再現できません）。既定は main のみ（1 層。組織は 1 つ）です。`--layout 2`（main + staging）・`--layout 3`（main + staging + develop）を付けると、その構成のリポジトリを作り、**段階ごとに、実際にワークフローを動かして確認**します。

```bash
bash tests/e2e/bootstrap.sh --add-orgs      # 2 層・3 層に必要な、staging・develop のテスト用組織を、鍵一式に追加する（1 回だけ）
bash tests/e2e/bootstrap.sh --refresh-orgs  # 認証 URL（リフレッシュトークン）が失効したとき（RefreshTokenAuthError）に、無効なものだけを取り直す
bash tests/e2e/run.sh --layout 3            # 3 層で、通しで確認する
```

確認する内容（3 層の例）: 同じブランチから、develop → staging → main の順に、段階ごとの PR を出し、PR をマージするたびに、**その段階の組織にだけ**クラスができること（まだ先の段階の組織には入っていないこと）、main へのマージのあと、`wf-propagate` が成功し、staging・develop のブランチに main の最新が入ること、削除（main への PR）が、ほかの段階の組織には及ばないこと。3 つの組織（main・staging・develop）は、別々の組織にしてください。`--resume` では、リポジトリの構成（層数）を、ブランチから自動で判定します。

**実際のリポジトリの検証は、`sf-init.sh --verify` です。** この e2e は、sf-tools の開発者が、sf-tools 自体の変更を確認するための回帰テストです。管理者が、自分の実際のリポジトリ・実際の組織で、リリースと削除が動くことを確認するときは、`sf-init.sh --verify`（4.21）を使います。

**途中から再実行する（`--resume`）:** `e2e` は、`sf-init` と `wf-metasync` の確認に、15 分ほどかかります。Hello World の部分だけを直して確認したいときは、前回残したテスト用リポジトリ（最新の 1 つ）を使って、その部分だけを、約 15 分で再実行できます。

```bash
bash tests/e2e/run.sh --resume
```

`--resume` では、前掃除・`sf-init`・`wf-metasync` を行いません。ジョブ名は、毎回、時刻付きの別の名前（`e2e-hello-時刻`）になるので、同じリポジトリで、何度でも実行できます。前回の失敗で、Hello World の Apex クラスが組織に残っていたら、最初に削除します（名前が完全に一致するものだけ）。前回残したリポジトリがない場合は、エラーになります（通常の実行をしてください）。

**シナリオを 1 つずつ動かす（`scenario.sh`）:** `run.sh` が残したテスト用リポジトリに対して、確かめたいことだけを、短く動かします。`bash tests/e2e/scenario.sh --list` で一覧を見て、`bash tests/e2e/scenario.sh log-secrets` のように名前で選びます（名前なしは、何も実行しません）。実行の前後で、`main` の SHA・ブランチ・PR の数を比べ、変わっていたら、後続を実行しません。現在あるのは、`log-secrets`（直近の Actions のログと PR のコメントに、PAT・Slack の Token・認証 URL・秘密鍵が出ていないこと。読み取りのみ）、`validate-fail`（壊れた Apex の PR で `wf-validate` が失敗してコメントが付き、直すと成功すること。PR は、マージせずに閉じます）、`dist-main`（配布版 = `SF_TOOLS_BRANCH` 未設定で、sf-tools の `main` が使われること。`main` と `development` の配布物に差がない rr の直後だけ実行できます）、`metasync-diff`（組織にだけ作った Apex が、`wf-metasync` で `main` に反映されること。組織と `main` は、実行前の状態に戻します）、`manual-delete`（テスト用リポジトリの Secret・Variable を手で削除 → `sf-init.sh --status` が見つけ、直し方を示す → 元に戻す。書き込みがあるため、開始の前に、書き込む内容が表示されます。終了時に、必ず元に戻します）です。「実行できない」（検査できるログがない、など）は、成功には数えません。

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
