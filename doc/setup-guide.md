# 🚀 force-* プロジェクト 新規セットアップガイド

新しい Salesforce プロジェクト（force-xxx）を GitHub に作成し、sf-tools と連携させるまでの手順。

> **📝 注意:** 本ガイドの例示（`yamada-corp`、`force-yamada`、`/c/home/dev` など）は説明用のサンプルです。実際の環境に合わせて読み替えてください。

> **本ドキュメントの範囲:** 新規プロジェクトのセットアップ手順。入力項目やディレクトリ構成の詳細はコード（`sf-init.sh` のヘッダーコメント等）を正とします。

---

## 1. 前提条件

> **⚠️ Windows ユーザーへ:** 本ガイドのすべての操作は **Git Bash** で行ってください。コマンドプロンプトや PowerShell は非対応です。

### 1.1 🖥️ ローカル環境

- Git（Git Bash 含む） — ソースコード管理
- GitHub CLI（`gh` コマンド） — GitHub 操作の自動化
- Node.js / npm — ビルドツール・依存管理
- Salesforce CLI（`sf` コマンド） — Salesforce 組織との接続・デプロイ
  - **npm 版**（`npm install -g @salesforce/cli`）を使うこと。Windows の Git Bash で公式インストーラー版を使うと、`sf` が成功しても終了コード 1 を返し、sf-tools の処理が失敗扱いになる（README 1.1 参照）
- Visual Studio Code — コードエディタ
  - Salesforce Extension Pack (Expanded) を事前にインストールしておくこと
- Slack — ワークフローの通知先

> 各ツールの取得先・Windows でのインストール方法は `README.md` §1 を参照してください。

### 1.2 ☁️ Salesforce 環境

- 開発用の Sandbox（Developer / Developer Pro）が作成済みであること
- 接続先の Sandbox 名を把握していること

### 1.3 🐙 GitHub アカウント

- リポジトリ作成権限があること
- GitHub CLI で認証済みであること（`gh auth login` で事前にログインしておく）

---

## 2. sf-tools をクローン

sf-tools は、Salesforce 開発の環境構築・日々の作業を自動化するシェルスクリプト集です。
`~/sf-tools/` に設置し、各 Salesforce プロジェクト（`force-*` ディレクトリ）から共通で呼び出して使います。
一度クローンすれば、複数のプロジェクトで共有できます。

```bash
git clone https://github.com/tama-create/sf-tools.git ~/sf-tools
```

PATH に追加して、どこからでも実行できるようにする:

```bash
# Windows（Git Bash）・Linux
echo 'export PATH="$HOME/sf-tools/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

macOS（標準のターミナル = zsh）は、`~/.zshrc` に追加します。

```bash
echo 'export PATH="$HOME/sf-tools/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

---

## 3. sf-init.sh でセットアップを自動実行

新しい Salesforce プロジェクトを一から立ち上げるための初期セットアップスクリプトです。
GitHub リポジトリの作成から Salesforce 組織への接続、ブランチ構成の設定、Secrets の登録、ブランチ保護ルールの適用まで、すべてを一括で自動実行します。
手動でひとつひとつ設定する手間をなくし、設定漏れを防ぐことが目的です。

```bash
~/sf-tools/bin/sf-init.sh
```

対話形式で必要な情報を入力するだけで、以下がすべて自動で行われる:

| フェーズ | 内容 |
| :--- | :--- |
| 環境チェック | 必要なツールの確認・GitHub CLI 認証確認 |
| リポジトリ作成 | GitHub リポジトリを作成・クローン・`sf-tools/templates/` からファイルをコピー |
| ファイル生成 | 設定ファイル・Git フックを自動生成（ワークフローはテンプレートに同梱） |
| ブランチ構成 | main / staging / develop などの構成を選択・作成 |
| PAT_TOKEN 登録 | GitHub Classic PAT を発行して GitHub Secrets に登録 |
| Slack 連携 | Slack Bot Token・チャンネル ID を GitHub Secrets に登録 |
| 初回コミット | セットアップ内容をまとめてコミット＆プッシュ |
| Ruleset 設定 | ブランチ保護ルールを自動設定 |
| JWT Secrets 登録 | JWT 認証情報（SF_PRIVATE_KEY 等）を GitHub Secrets に登録 |

### 3.1 入力が必要な項目

リポジトリ名は **`force-XXXX`**（`force-` は固定。`XXXX` は管理者が決める名前）です。フォルダ構成には、決まりがありません。**作業フォルダ（どこでもよい）** で `sf-init.sh` を実行してください。

```bash
cd {作業フォルダ}
sf-init.sh                                  # 対話: オーナーを選び、XXXX を入力
sf-init.sh --owner yamada-corp --project yamada   # 引数で指定（対話なし）→ yamada-corp/force-yamada
```

対話では、次のように聞かれます。

```
  GitHub のオーナー: yamada-corp（gh のログインから取得。複数あれば、番号で選ぶ）

  リポジトリ名は「force-XXXX」の形です。
  「force-」は自動で付きます。XXXX の部分だけを入力してください。
     例: acme と入力 → force-acme

  yamada-corp に、すでにあるプロジェクト（XXXX）:
     acme / beta

  XXXX（force- の後ろ）を入力してください: yamada
```

- 入力は、**XXXX の部分だけ**です（`force-yamada` と書いても、`yamada` として扱います）。すでにある名前は、警告して、聞きなおします。
- 管理者用の作業フォルダは `{作業フォルダ}/init-yamada/force-yamada` になります。複数のプロジェクトを、同じ作業フォルダで作っても、途中経過が、衝突しません。
- **従来のフォルダ構成**（`~/home/{github-owner}/{company}/`。例: `~/home/yamada-corp/yamada/`）で実行したときは、引数も入力もなしで、フォルダ名からオーナーとプロジェクトが決まります（管理者用の作業フォルダは、従来どおり `init`）。

実行中に以下を順番に入力・操作する:

1. **環境種別の選択**（**通常は「1. 本番環境」**）
   - 1. 本番環境: GitHub Actions は sf-tools の `main`（リリース済みの配布版）を使用します
   - 2. 検証環境: **sf-tools の開発者専用**です。リリース前の未検証コード（`development`）が使われます。選択すると確認（Y/N/q）が出ます
   - 選択した環境に合わせて、`~/sf-tools` が最新かどうかも確認されます。遅れていれば更新して中断するので、もう一度 `sf-init.sh` を実行してください
2. **ブランチ構成の選択**（3 / 2 / 1 階層）
3. **GitHub Classic PAT の発行**（ブラウザで操作・トークンを貼り付け）
   - **作るアカウント**: force-* のリポジトリの**オーナー**（組織のリポジトリなら、その組織の**管理者**）のアカウントです（実行の最初に表示されます）。ブラウザのログイン中のアカウントが違う場合は、切り替えてください。sf-tools の開発者のアカウントは、関係ありません
   - ブラウザで、Token の作成ページが自動で開きます（Note と Scopes は、入力済みです）。ページの一番下の「Generate token」を押して、表示された Token をコピーし、ターミナルに貼り付けます
   - Note: `sf-metasync-{プロジェクト名}`（自動表示）
   - Expiration: `No expiration`
   - Scopes: `repo`（全選択）・`workflow`
   - 貼り付けると、文字の数だけ `*` が並びます（Token の中身は、画面に出ません）。Git Bash は、**右クリック**（または Shift+Insert）で貼り付けます。Enter を押すと、「N 文字を受け取りました」と表示されます。スコープ（`repo`・`workflow`）と、リポジトリの管理者であることを、GitHub に問い合わせて確認します。違う場合は、理由が表示され、3 回まで貼り直せます（Fine-grained の Token は、スコープを確認できないため、使えません）
4. **Slack Bot Token の取得**（ブラウザで操作・トークンを貼り付け）
5. **Slack チャンネル ID の入力**（`C` で始まる文字列）
   - 通知先は、**このプロジェクトを使う全員が参加する共有チャンネル**です。`sf-init` はチャンネルを作らないので、**Slack で事前に作成**しておいてください（既存のチャンネルでも構いません）
   - DM（`D…`）やユーザー（`U…`）の ID は、本人にしか通知が届かないため受け付けられず、入力し直しになります
6. **Bot をチャンネルに招待**（Slack で手動実行が必要）
   - 通知先チャンネルを開き、以下を実行:
   ```
   /invite @sf-notify-<プロジェクト名>
   ```
   - Bot がチャンネルに参加していないと通知が届きません
7. **JWT 認証情報の設定**（Salesforce の組織ごと）
   - 既定は、**外部クライアントアプリケーション（Salesforce 推奨）です。アプリの作成を `sf-init` が自動で行います**（アプリの種類は、聞きません）
     - 段階（main / staging / develop）ごとに、**ログイン先**（`login.salesforce.com` / `test.salesforce.com` / 組織の URL）を選び、**ブラウザで Salesforce にログイン**する（接続ユーザー＝管理者権限のユーザー）だけです。どの段階にも、本番・Sandbox・Developer Edition を、つなげます。ただし、**Salesforce の本番組織は、main にしか、つなげません**
     - ブラウザでのログインは、約 2 分で時間切れになります。ブラウザが開いたら、すぐにログインしてください
     - アプリの作成・証明書の登録・ポリシーとプロファイルの設定・コンシューマー鍵の取得は自動です（反映待ちのため、接続テストは成功するまでリトライします）
   - `sf-init.sh --legacy-connected-app` を付けた場合（従来の接続アプリケーション。廃止予定）は、手動です。Salesforce の画面で設定し、次を入力します
     - `SF_CONSUMER_KEY_*`: Connected App コンシューマーキー（本番・ステージング・開発）
     - `SF_USERNAME_*`: 接続ユーザー名（本番・ステージング・開発）
   - いずれの場合も、次が GitHub に登録されます
     - `SF_PRIVATE_KEY`: PEM 秘密鍵（全組織共通）
     - `SF_CONSUMER_KEY_*` / `SF_USERNAME_*` / `SF_INSTANCE_URL_*`（例: `https://login.salesforce.com`）

> JWT 秘密鍵の事前準備: `openssl genrsa -out server.key 2048` で生成し、公開鍵を各 Salesforce 組織の Connected App に登録しておくこと。

> クローン先は sf-init.sh を実行したディレクトリに自動設定されます。

### 3.2 SF_TOOLS_TOKEN は不要です

`sf-tools` は**公開リポジトリ**のため、GitHub Actions（wf-metasync / wf-validate / wf-release）は、Token なしで `sf-tools` を clone します。以前のバージョンにあった Token（`SF_TOOLS_TOKEN`）の作成・登録（`sf-init.sh` の Phase 11）は、ありません。

- 以前のバージョンで作ったプロジェクトに `SF_TOOLS_TOKEN` が登録されていても、そのままで構いません。
- ただし、そのプロジェクトのワークフローが、Token 付きで clone している間は、その Token を**無効にしないでください**（無効な Token では、公開リポジトリでも clone に失敗します）。ワークフローを、新しいひな形（Token なし）に更新したあとなら、Token と Secret を削除して構いません。更新の手順は、7.6 を参照してください。

---

## 4. 動作確認

sf-init.sh によるセットアップが正しく完了したことを確認します。
メタデータ同期とワークフローの2点を検証することで、Salesforce 組織との接続・GitHub Actions の動作・ブランチ保護ルールがすべて正しく機能しているかを確かめます。

### 4.1 🔄 sf-metasync の確認

GitHub → Actions → 「[metasync] メタ同期」→ 「Run workflow」で手動実行。
✅ 正常に完了すれば本番組織のメタデータが main に同期される。

### 4.2 📝 PR ワークフローの確認

```bash
# 1. ジョブブランチを作成・クローン・sf-start 起動
#    作業フォルダ（作業単位のフォルダを置く場所）で実行
sf-job.sh
```

`sf-job.sh` 実行後、`sf-start.sh` が自動実行され、`sf-install.sh` が `sf-tools/release/{branch}/` 配下に以下のファイルを自動生成する:

```
sf-tools/release/{branch}/
├── deploy-target.txt   ← 自動生成（空テンプレート）
└── remove-target.txt   ← 自動生成（空テンプレート）
```

これらの自動生成ファイルがそのままコミットの差分になるため、**追加のファイル変更は不要**。

```bash
# 2. 自動生成ファイルをコミット＆プッシュ
#    force-* ディレクトリ内で実行
sf-push.sh

# 3. 次の PR 先を確認・PR 作成 → ブラウザで PR 作成 → マージ
#    ブランチ構成が 3 階層なら develop → staging → main の順で繰り返す
sf-next.sh
```

- `sf-push.sh` がコミットメッセージ入力（VS Code）→ commit → push を一括実行
- `sf-next.sh` が次の PR 先を自動判定し、🌐 ブラウザで PR 作成画面を開く
- PR をマージしたら再度 `sf-next.sh` を実行して次のブランチへ PR を出す

PR が作成されると以下が自動実行される:
- ✅ [validate] デプロイ前検証 — すべての PR で実行
- ✅ [sequence] マージ順序チェック — main / staging への PR で実行
- ✅ [release] デプロイ → Slack 通知 — PR マージ後に実行

---

## 5. ワークフロー一覧（自動生成済み）

sf-init.sh によって `.github/workflows/` に自動生成されるワークフローの一覧です。

| ファイル | ワークフロー名（`name:` フィールド） | トリガー |
| :--- | :--- | :--- |
| `wf-validate.yml` | [validate] デプロイ前検証 | すべてのブランチへの PR 作成・更新・再オープン時 |
| `wf-sequence.yml` | [sequence] マージ順序チェック | main / staging への PR 作成・更新時 |
| `wf-release.yml` | [release] デプロイ | main / staging / develop への PR マージ後 |
| `wf-propagate.yml` | [propagate] ブランチ伝播 | main への PR マージ後 |
| `wf-metasync.yml` | [metasync] メタ同期 | 平日 JST 9:00 / 12:00 / 15:00 / 18:00 の 3 時間おきに自動実行 |

---

## 6. ディレクトリ構成（セットアップ後）

```
force-xxx/
├── .forceignore                 # Salesforce CLI の無視対象
├── .gitattributes               # 改行コード統一・マージドライバー設定
├── .gitignore                   # Git の無視対象
├── .prettierrc                  # Prettier 設定（Apex/XML 対応）
├── .prettierignore              # Prettier の無視対象
├── .github/
│   └── workflows/
│       ├── wf-metasync.yml
│       ├── wf-propagate.yml
│       ├── wf-release.yml
│       ├── wf-sequence.yml
│       └── wf-validate.yml
├── sf-tools/
│   ├── config/
│   │   ├── branches.txt        # ブランチ階層設定
│   │   └── metadata.txt        # メタデータ同期対象
│   └── release/
│       ├── branch_name.txt      # 現在のブランチ名
│       └── <branch>/
│           ├── deploy-target.txt # デプロイ対象
│           └── remove-target.txt # 削除対象
├── force-app/                   # Salesforce メタデータ
├── sf-start.sh                  # ラッパー（~/sf-tools/bin/sf-start.sh を呼び出す）
└── sf-restart.sh                # ラッパー（~/sf-tools/bin/sf-restart.sh を呼び出す）
```

---

## 7. トラブルシューティング

### 7.1 ❌ sf-init.sh が途中でエラー終了した

ログファイルを確認する:

```bash
cat ~/sf-tools/logs/sf-init.log
```

「どこで間違えたか分からない」ときは、`force-*` フォルダ（管理者用の `init` フォルダの中にあります）で `sf-init.sh --status` を実行する。リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているかを、✓（できている）・✗（不足。直し方も表示）で確認できる（何も変更しない）。

エラー内容を確認して対処後、**同じフォルダで `sf-init.sh` をもう一度実行する**。途中まで進んでいた場合は、次の選択肢が出る。

```
前回のセットアップは、「ブランチの構成」まで完了しています（2026-10-11 14:32）。（owner/force-xxx）
    [1] 「GitHub の Token」から、続きをやる   ← おすすめ
    [2] 最初からやり直す（作成済みのリポジトリ・init フォルダは、そのまま使います）
    [q] 中断
```

- **[1] 続きをやる**: 保存済みの入力内容（環境種別・ブランチ構成など）を使い、失敗した Phase から再開する（Phase 1 の環境チェックは毎回実行する）。
- **[2] 最初からやり直す**: 保存した状態を消して、Phase 1 から始める。作成済みのリポジトリと `init` フォルダは、削除せず、そのまま使う（Phase 3 が、すでにあるものはスキップする）。
- 前回が最後（Phase 10）まで完了している場合は、「セットアップが、すでに完了しています」と表示され、[1] いまの接続を見る／[2] 動作を確認する（`sf-init.sh --verify`）／[3] 最初からやり直す／[q] 終了を選べる。別のリポジトリの状態の場合は、この選択肢は出ず、最初から始まる。
- **`init` フォルダは、削除せず残す**（管理者用のフォルダ。ワークフローの更新・接続の確認・接続先の付け替えなどのメンテナンスに使う。日常の開発には使わない）。
- Phase 10（Salesforce の接続）は、段階ごとに完了を記録する。途中で失敗しても、「続きをやる」では、完了した段階は、スキップされる（ブラウザのログインを、やり直さなくてよい）。
- 完了済みのプロジェクトでは、`--resume N` は、使えない（接続処理を、確認なしで、やり直さないため）。引数なしで実行して、選ぶ。
- 進捗は `init/.sf-init.progress` の `SF_INIT_DONE_PHASE` に記録される（入力内容は `init/.sf-init.env`）。`--resume N`（Phase N から、質問なしで実行）を指定した場合は、この選択肢は出ない。
- リポジトリそのものを作り直したい場合は、GitHub 上のリポジトリと `init` フォルダを、手動で削除してから実行する。

### 7.2 ❌ sf-metasync が「push declined due to repository rule violations」で失敗

PAT_TOKEN が未設定、または権限不足。3.1 の PAT_TOKEN 登録を確認。sf-init.sh の Phase 6 は、登録時に、スコープとリポジトリの管理者であることを確認しますが、登録後に Token を無効にしたり、有効期限が切れたりした場合は、この状態になります（新しい Token を発行して、リポジトリの Secrets の `PAT_TOKEN` を登録し直してください。`sf-update-secret.sh` は、JWT 用で、PAT_TOKEN は更新できません）。

### 7.3 ❌ wf-validate / wf-sequence が動かない

ワークフローファイルが `.github/workflows/` にあるか確認。
ファイルが存在しない場合は、`~/sf-tools/templates/.github/workflows/` から `wf-*.yml` を手動でコピーすること。

### 7.4 ⚠️ CRLF の警告が出る

Windows 環境での改行コードの違い。動作に影響はない。
`git checkout -- <file>` でリセット可能。

### 7.5 ⚠️ pre-push フックがプッシュをブロックする

main ブランチへの直接プッシュは禁止。PR 経由でマージすること。
テスト等でバイパスが必要な場合は `git push --no-verify`。

### 7.6 ❌ wf-metasync / wf-validate / wf-release が「自動化ツール（sf-tools）を取得」で失敗する

`sf-tools` は公開リポジトリのため、新しい `wf-*.yml`（`sf-tools/templates/`）は、Token なしで clone します。このエラーは、**以前のバージョンのひな形で作ったプロジェクト**で、ワークフローが `SF_TOOLS_TOKEN` 付きで clone している場合に、その Token が未設定・期限切れ・無効のときに起きます。force-* 側の `wf-metasync.yml` / `wf-validate.yml` / `wf-release.yml` の clone 行を、新しいひな形と同じ Token なしの形（`git clone -b ${{ vars.SF_TOOLS_BRANCH || 'main' }} https://github.com/tama-create/sf-tools.git ...`）に直してください。配布済みの force-* には自動反映されません。

### 7.7 ❌ 「差分抽出ツール（Salesforce Git Delta）をインストール」で TypeError が出て失敗する

エラー例: `TypeError: webidl.util.markAsUncloneable is not a function`

ワークフローの Node.js が古い（`@salesforce/cli` の最新版は Node 22 以上が必要）。各 `wf-*.yml` の `node-version` を `22` 以上にする。`sf-tools/templates/` を直しても配布済みの force-* には自動反映されないため、force-* 側の `wf-*.yml` も修正すること。
