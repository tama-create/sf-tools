# sf-tools — Salesforce 開発自動化ツールキット

> **本書は概要です。** 詳しい使い方・管理者向けの手順・コマンドの説明は、**[文書サイト](https://tama-create.github.io/sf-tools/)** にあります（手元では、`site/index.html` をブラウザで開いても読めます）。

---

## 1. sf-tools とは

Salesforce 開発で毎回発生する、環境構築・デプロイ・事前チェック・メタデータの同期を、まとめて自動化するシェルスクリプト集です。
`~/sf-tools` に置き、各 Salesforce プロジェクト（`force-*` フォルダ）から呼び出して使います。変更の検証とリリースは、GitHub Actions が自動で行います。

---

## 2. できること

- **プロジェクトの立ち上げ（管理者）:** `sf-init.sh` が、GitHub リポジトリの作成、Salesforce 組織への接続（JWT 認証）、ブランチ構成、Secrets の登録、ブランチ保護の設定までを、対話しながら、まとめて行います。
- **毎日の開発（開発者）:** `sf-job.sh` で作業を始め（ブランチ作成から VS Code の起動まで自動）、`sf-push.sh` でコミットして送り、`sf-next.sh` で次の PR 先を確認します。
- **安全なリリース:** 検証（dry-run）が既定です。git のフックと GitHub Actions が、ターゲットファイルの確認・マージ順序の確認・保護ブランチへの直接 push の禁止を、自動で行います。
- **メタデータの同期:** Salesforce 組織の最新の状態を、定期的に、Git の `main` に反映します。
- **Windows・Mac で動きます。** 追加のインストールは、不要です（Windows は Git Bash、Mac は標準のターミナル）。

---

## 3. 前提条件

次のコマンドが使えることが前提です。入れ方は、文書サイトの「前提条件とインストール」にあります。

| ツール | 確認コマンド | 用途 |
|---|---|---|
| Git（Windows は Git Bash） | `git --version` | バージョン管理・フック |
| Salesforce CLI（**npm 版**） | `sf --version` | 組織への接続・デプロイ・取得 |
| GitHub CLI | `gh --version` | PR の作成・Secrets の登録 |
| Visual Studio Code | `code --version` | エディタの起動 |
| Slack | — | デプロイ通知の受信 |

> ⚠️ **Salesforce CLI は npm 版**（`npm install -g @salesforce/cli`）を使ってください。Windows の Git Bash で、公式インストーラー版を使うと、`sf` が成功しても終了コード 1 を返し、sf-tools の処理が失敗扱いになります。Windows は、Git Bash で実行します（PowerShell・コマンドプロンプトは非対応です）。

### 3.1 動作環境

実際に動かして確かめた環境だけを書いています。

| 環境 | 使う場面 | 確認した内容 |
|---|---|---|
| **Windows**（Git Bash） | 手元のパソコン（開発者・管理者） | ✅ 自動テストに合格。さらに、実際の GitHub と Salesforce を使って、初期セットアップから、Salesforce へのリリース・削除まで、最初から最後まで動かして確認しました |
| **Mac**（macOS） | 手元のパソコン | ✅ 同じ確認を、Mac mini の実機で行いました |
| **WSL**（Windows の中の Ubuntu） | 手元のパソコン | ✅ 同じ確認を行いました |
| **Linux**（GitHub Actions のサーバー） | 自動で動く部分（人は触りません）: 変更の検証・Salesforce へのリリース・メタデータの同期 | ✅ 実際の Salesforce に対して、検証・リリース・同期が成功することを確認しました |

- 確認に使った Salesforce は、**Developer Edition**（開発者向けの無料の組織）です。ほかのエディション（Enterprise など）や Sandbox では、確認していません。
- 自動テストは、GitHub 上で、変更のたびに自動で実行され、Linux・Mac・Windows の 3 つの環境で、合格しています。
- Linux を、手元のパソコンとして使うことは、想定していません（自動で動くサーバーとしてだけ使います）。
- Mac は、標準のターミナル（zsh）と標準の Bash のままで動きます（Bash の入れ直しは不要です）。
- いつ、どの環境で確認したかの記録は、開発者向けの資料（`doc/dev-reference.md` の 9.7）にあります。

---

## 4. はじめかた

```bash
# 1. sf-tools を置く
git clone https://github.com/tama-create/sf-tools.git ~/sf-tools

# 2. PATH を通す（どこからでも、コマンド名だけで呼べるようにする）
#    Windows（Git Bash）・Linux: ~/.bashrc / macOS（zsh）: ~/.zshrc に、次の 1 行を追加
export PATH="$HOME/sf-tools/bin:$PATH"
```

- **管理者**は、作業フォルダで `sf-init.sh` を実行して、プロジェクト（`force-XXXX`）を作ります。
- **開発者**は、作業フォルダで `sf-job.sh` を実行して、作業を始めます。ブランチ名を入力するだけで、作業用のクローンの準備から VS Code の起動までが進みます。

手順の詳細は、文書サイトの「使い方ガイド」（開発者向け）と「管理者ガイド」を見てください。

---

## 5. コマンド早見表

どのコマンドも `--help` で、概要・オプション・処理の流れを表示できます。⚠️ は管理者専用です（実行すると、警告と確認が出ます）。

| 対象 | コマンド | 用途 |
|---|---|---|
| 開発者 | `sf-job.sh` | 新しい作業を始める（ブランチ作成〜VS Code の起動） |
| 開発者 | `sf-start.sh` | 開発環境を起動する（作業の再開） |
| 開発者 | `sf-push.sh` | カレント配下をコミットしてプッシュする |
| 開発者 | `sf-next.sh` | 次の PR 先を確認する |
| 開発者 | `sf-check.sh` | ターゲットファイル（`deploy-target.txt` など）の構文を確認する |
| 開発者 | `sf-dryrun.sh` / `sf-release.sh` | dry-run で検証する / 検証・リリースする |
| 開発者 | `sf-deploy.sh` | ⚠️ 接続中の個人用の組織へ、強制リリースする（共有環境には、できません） |
| 開発者 | `sf-restart.sh` | 接続先の組織を切り替える |
| 開発者 | `sfl`（`sf-launcher.sh`） | 上のコマンドを、メニューから選んで実行する |
| 開発者 | `sf-hook.sh` / `sf-unhook.sh` | 手元のクローンの検証フックを、有効にする / 削除する |
| 管理者 | `sf-init.sh` | 新規プロジェクトの作成。段階の追加（`--add-tier`）・診断（`--status`）・接続先の付け替え（`--reconnect`）・動作の確認（`--verify`）も |
| 管理者 | `sf-update-secret.sh` | ⚠️ GitHub の Secrets / Variables を再登録する |
| 管理者 | `sf-sync-wf.sh` | ⚠️ 作成済みのワークフローを、最新の雛形に合わせて更新する |
| 管理者 | `sf-typecheck.sh` | ⚠️ 個人用の組織で、メタデータの種類ごとに、リリース・削除の可否を確かめる |
| 自動 | `sf-install.sh` / `sf-upgrade.sh` / `sf-prepush.sh` / `sf-precommit.sh` / `sf-metasync.sh` | ほかのコマンド・git のフック・GitHub Actions から、自動で動く |

---

## 6. ドキュメント

### 6.1 利用者向け（文書サイト）

**[https://tama-create.github.io/sf-tools/](https://tama-create.github.io/sf-tools/)**（手元では `site/index.html`）

| 読者 | 内容 |
|---|---|
| 開発者 | 前提条件とインストール・基本の使い方・日々の開発の流れ |
| 管理者 | 新規プロジェクトの作成・構成の変更と診断・認証情報・ワークフローの更新・動作の確認・トラブルシューティング |
| 調べたい人 | コマンド一覧・開発者向けコマンド・自動実行コマンド・ターゲットファイルの書き方・ログとリポジトリ構成 |
| 仕組みを知りたい人 | CI/CD の仕組み（ブランチ戦略・ワークフローの全体像・設計上の判断） |

### 6.2 設計書（実装・AI への指示用）

実装の判断の根拠になる設計書は、`doc/` に、Markdown のままで置いています（AI に実装を指示するときの資料です。読み物としての要点は、文書サイトの「CI/CD の仕組み」にあります）。

| 文書 | 内容 |
|---|---|
| `doc/sf-cicd-strategy.md` | Git 運用・CI/CD の基本戦略と、設計思想（詳細版） |
| `doc/jwt-auth-spec.md` | JWT 認証方式の仕様 |
| `doc/wf-distribution-strategy.md` | ワークフローの配布・更新の戦略 |
| `doc/wizard-ux-design.md` | ウィザード形式の画面（`sf-init` など）の設計 |
| `doc/sf-logwatch-design.md` | `sf-logwatch.sh` の設計書（未実装） |

### 6.3 sf-tools の開発者向け

| 文書 | 内容 |
|---|---|
| `doc/dev-guide.md` | 開発・リリースの流れ（`mm`・`rr`）と、e2e（実環境の通し検証）の使い方 |
| `doc/dev-reference.md` | 実装の詳細リファレンス（関数・処理フロー・テスト） |
| `doc/integration-test-plan.md` | 結合テストの計画と、カバレッジ表 |
| `CLAUDE.md` | AI（Claude Code）向けの作業ルール |

---

## 7. 設計方針

- シンプルなコマンドで、毎日の作業を自動化する。
- 失敗したときは、ログで原因を追いやすくする。
- 追加の依存を減らし、Git Bash（Windows）・macOS（標準の Bash 3.2）・Linux（GitHub Actions の Ubuntu）で、同じように動くクロスプラットフォームの構成を保つ。
- まず dry-run を基本にし、必要なときだけ本番を実行する。
- Bash 3.2 以上で動かす（macOS 標準の `/bin/bash` のまま、追加のインストールなしで使えるようにするため。Bash 4 以降の機能は使わない）。

---

## 8. ライセンス

`sf-tools` は、公開リポジトリです。ライセンスは、制限のない「パブリックドメイン」（The Unlicense。`LICENSE` を参照）で、誰でも自由に、コピー・改変・公開・使用できます。

- GitHub Actions は、`sf-tools` を Token なしで clone します（`SF_TOOLS_TOKEN` は不要です）。
- `sf-tools` に、認証情報や個人の秘密情報を含めないでください（履歴を含め、すべて公開されます）。
