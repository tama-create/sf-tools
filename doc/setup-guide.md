# 🚀 force-* プロジェクト 新規セットアップガイド

新しい Salesforce プロジェクト（force-xxx）を GitHub に作成し、sf-tools と連携させるまでの手順。

> **📝 注意:** 本ガイドの例示（`yamada-corp`、`force-yamada`、`/c/home/dev` など）は説明用のサンプルです。実際の環境に合わせて読み替えてください。

> **本ドキュメントの範囲:** 新規プロジェクトのセットアップ手順。入力項目やディレクトリ構成の詳細はコード（`sf-init.sh` のヘッダーコメント等）を正とします。

---

## 1. 前提条件

> **⚠️ Windows ユーザーへ:** 本ガイドのすべての操作は **Git Bash** で行ってください。コマンドプロンプトや PowerShell は非対応です。

### 1.1. 🖥️ ローカル環境

- Git（Git Bash 含む） — ソースコード管理
- GitHub CLI（`gh` コマンド） — GitHub 操作の自動化
- Node.js / npm — ビルドツール・依存管理
- Salesforce CLI（`sf` コマンド） — Salesforce 組織との接続・デプロイ
- Visual Studio Code — コードエディタ
  - Salesforce Extension Pack (Expanded) を事前にインストールしておくこと
- Slack — ワークフローの通知先

> 各ツールの取得先・Windows でのインストール方法は `README.md` §1 を参照してください。

### 1.2. ☁️ Salesforce 環境

- 開発用の Sandbox（Developer / Developer Pro）が作成済みであること
- 接続先の Sandbox 名を把握していること

### 1.3. 🐙 GitHub アカウント

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
echo 'export PATH="$HOME/sf-tools/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
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

### 3.1. 入力が必要な項目

GitHub オーナー名とプロジェクト名はフォルダ構成から自動取得されます。
以下の階層で `sf-init.sh` を実行してください:

```
~/home/{github-owner}/{company}/
```

例: `~/home/yamada-corp/yamada/` で実行 → オーナー `yamada-corp`、プロジェクト `yamada` が自動取得されます。

> ⚠️ `~/home/{owner}/{company}/{subdir}/` のように1階層深い場所から実行するとエラーになります。

実行中に以下を順番に入力・操作する:

1. **ブランチ構成の選択**（3 / 2 / 1 階層）
2. **GitHub Classic PAT の発行**（ブラウザで操作・トークンを貼り付け）
   - Note: `sf-metasync-{プロジェクト名}`（自動表示）
   - Expiration: `No expiration`
   - Scopes: `repo`（全選択）・`workflow`
3. **Slack Bot Token の取得**（ブラウザで操作・トークンを貼り付け）
4. **Slack チャンネル ID の入力**（`C` で始まる文字列）
5. **Bot をチャンネルに招待**（Slack で手動実行が必要）
   - 通知先チャンネルを開き、以下を実行:
   ```
   /invite @sf-notify-<プロジェクト名>
   ```
   - Bot がチャンネルに参加していないと通知が届きません
6. **JWT 認証情報の入力**（各 Salesforce 組織の Connected App 情報）
   - `SF_PRIVATE_KEY`: PEM 秘密鍵（全組織共通）
   - `SF_CONSUMER_KEY_*`: Connected App コンシューマーキー（本番・ステージング・開発）
   - `SF_USERNAME_*`: 接続ユーザー名（本番・ステージング・開発）
   - `SF_INSTANCE_URL_*`: 接続 URL（例: `https://login.salesforce.com`）

> JWT 秘密鍵の事前準備: `openssl genrsa -out server.key 2048` で生成し、公開鍵を各 Salesforce 組織の Connected App に登録しておくこと。

> クローン先は sf-init.sh を実行したディレクトリに自動設定されます。

---

## 4. 動作確認

sf-init.sh によるセットアップが正しく完了したことを確認します。
メタデータ同期とワークフローの2点を検証することで、Salesforce 組織との接続・GitHub Actions の動作・ブランチ保護ルールがすべて正しく機能しているかを確かめます。

### 4.1. 🔄 sf-metasync の確認

GitHub → Actions → 「[metasync] メタ同期」→ 「Run workflow」で手動実行。
✅ 正常に完了すれば本番組織のメタデータが main に同期される。

### 4.2. 📝 PR ワークフローの確認

```bash
# 1. ジョブブランチを作成・クローン・sf-start 起動
#    ~/home/{owner}/{company}/ で実行
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

### 7.1. ❌ sf-init.sh が途中でエラー終了した

ログファイルを確認する:

```bash
cat ~/sf-tools/logs/sf-init.log
```

エラー内容を確認して対処後、再実行する。すでに作成されたリポジトリは手動で削除してからやり直すこと。

### 7.2. ❌ sf-metasync が「push declined due to repository rule violations」で失敗

PAT_TOKEN が未設定、または権限不足。3.1 の PAT_TOKEN 登録を確認。

### 7.3. ❌ wf-validate / wf-sequence が動かない

ワークフローファイルが `.github/workflows/` にあるか確認。
ファイルが存在しない場合は、`~/sf-tools/templates/.github/workflows/` から `wf-*.yml` を手動でコピーすること。

### 7.4. ⚠️ CRLF の警告が出る

Windows 環境での改行コードの違い。動作に影響はない。
`git checkout -- <file>` でリセット可能。

### 7.5. ⚠️ pre-push フックがプッシュをブロックする

main ブランチへの直接プッシュは禁止。PR 経由でマージすること。
テスト等でバイパスが必要な場合は `git push --no-verify`。
