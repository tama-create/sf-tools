# Salesforce Git 運用・CI/CD 基本戦略＆設計思想

> **本ドキュメントの範囲:** 設計思想・判断理由・ワークフロー全体像。実装の詳細（ファイルパス・コマンド引数等）はコードを正とします。

## 1. 目的

Salesforce メタデータの「パッチ形式」の特性を最大限に活かし、Git と各組織（Production / Staging / Dev）の整合性を保つ。

**設計上の 3 つの柱:**

1. **本番が正（Source of Truth）** — 本番組織の変更を SGD で高速検知し、人間を介さず全環境へ即座に波及させる「自己修復型同期」
2. **スター型プロモート** — feature ブランチから各環境へ個別に PR を送る。環境ブランチ間の直接マージは禁止
3. **セルフコンテインド WF** — CI/CD ロジックを各プロジェクト（force-*）の `.github/workflows/` に完全内包し、`sf-tools/templates/` からの一括配布で管理する

---

## 2. 環境構成とブランチ戦略

### 2.1 ブランチ構成の動的設定（branches.txt）

ブランチ階層は `sf-tools/config/branches.txt` で **プロジェクトごとに設定可能**。
`sf-install.sh` が初回セットアップ時にテンプレートからコピーする。

| パターン | branches.txt | 用途 |
| :--- | :--- | :--- |
| **3階層** | main / staging / develop | 標準構成（開発→検証→本番） |
| **2階層** | main / staging | 開発組織を使わない場合 |
| **1階層** | main | 小規模プロジェクト・単独開発 |

### 2.2 環境マッピング（3階層の場合）

| 層 | 環境（Org） | ブランチ | エイリアス | 役割 |
| :--- | :--- | :--- | :--- | :--- |
| **本番層** | Production | `main` | `prod` | **正（Source of Truth）**。本番の最新状態。 |
| **検証層** | Staging / UAT | `staging` | `staging` | 結合テスト・顧客確認用。 |
| **開発層** | Development / QA | `develop` | `develop` | 初期検証用。開発のベースライン。 |
| **作業層** | 各 Sandbox | `feature/*` | — | 作業項目ごとのソースの源泉。 |

---

## 3. リリース戦略（スター型プロモート）

### 3.1 配布ルール

すべてのリリースは `feature/*` ブランチを起点とし、各ターゲットブランチへ **個別に PR** を作成してデプロイする。

```
feature/xxx ──→ develop   （開発組織へリリース）
feature/xxx ──→ staging   （ステージング組織へリリース）
feature/xxx ──→ main      （本番組織へリリース）
```

デプロイ対象は `sf-tools/release/<branch>/deploy-target.txt` に記載したコンポーネントのみ。

**設計理由:** 環境ブランチ間でマージすると、意図しない変更が混入するリスクがある。必ず feature ブランチを経由させることで、各環境に「何がデプロイされたか」を明確に追跡できる。

### 3.2 マージ順序チェック（推奨順序）

プロモーションの推奨順序は `branches.txt` の逆順（下位 → 上位）。
例: 3階層の場合 `develop → staging → main` の順。
GitHub Actions（sf-sequence）が `branches.txt` を動的に読み込んで順序を自動チェックし、未確認の場合は **警告を出すが PR はブロックしない**（緊急リリースを妨げないため）。

**sf-sequence は常に `origin/main` の branches.txt を参照する。** PR のマージコミット（head+base の合成）には branches.txt が含まれない場合があるため。

| チェック対象（3階層の場合） | 確認内容 |
| :--- | :--- |
| staging への PR | feature が develop にマージ済みか |
| main への PR | feature が develop かつ staging にマージ済みか |

### 3.3 sf-next.sh（次のPR先の自動判定）

`sf-next.sh` を実行すると、現在のブランチが各ターゲットブランチにどのような状態かを判定し、次にPRを出すべきブランチを表示する。Y 入力でブラウザのPR作成画面を直接開く。

**判定ロジック（優先順）:**
1. `gh pr list --state merged` で**直接 PR** のマージ済みを確認 → `マージ済み`
2. `git merge-base --is-ancestor` で**間接伝播**（上位ブランチ経由）を確認 → `マージ済み（ブランチ同期）`
3. `gh pr list --state open` で PR 発行中を確認 → `PR発行中`
4. いずれも該当なし → `次のPR先` / `未着手`

**表示ステータス:**

| 記号 | 表示 | 意味 |
| :--- | :--- | :--- |
| `✓` | マージ済み | 直接 PR をマージ済み。デプロイ WF 実行済み |
| `✓` | マージ済み（ブランチ同期） | 直接 PR はないが上位ブランチ経由でコードが伝播済み。**デプロイ WF は未実行** |
| `⚠` | マージ済み（順序外） | 前のブランチの直接 PR が完了する前にマージ済み。**前のブランチのデプロイは未実行** |
| `→` | PR発行中 | PR を発行済み（マージ待ち） |
| `▶` | 次のPR先 | 次に PR を出すべきブランチ |
| `✗` | 未着手 | まだ PR を出していない |

```
  feature/xxx のマージ状況
  ────────────────────────────
    ✓ develop   マージ済み
    ▶ staging   次のPR先
    ✗ main
```

**順序外マージの制約:**
`develop → staging → main` の順番を守らずにマージした場合、スキップしたブランチへのデプロイは永久にできない。上位ブランチにマージするとコードが下位ブランチに伝播（`wf-propagate`）し、その後は「差分なし」で直接 PR が作れなくなるため。デプロイ WF は直接 PR のマージイベントでのみ起動する。

### 3.4 マージ禁止制限（システムによる強制ブロック）

**環境ブランチ間の直接 PR** は sf-sequence で検知しエラーでブロックする。
`branches.txt` に記載されたブランチからの PR は全てブロック対象。

3階層の場合の例:
- develop → staging
- develop → main
- staging → main

### 3.5 ローカルでの main 同期（pre-push フック）

`git push` 前に、リモートの最新 `main`（自動更新された本番の状態）を取り込んでいるかチェック。
未取り込みの場合は main からのマージを自動実行して最新化する。

sf-start.sh 実行時に pre-push フックを自動インストール。

---

## 4. CI/CD ワークフロー全体像

### 4.1 セルフコンテインド WF パターン

CI/CD ロジックは各 Salesforce プロジェクト（force-*）の `.github/workflows/` に **完全内包**する。`sf-tools/templates/.github/workflows/` が唯一の正本であり、`sf-init` 実行時にコピーされる。

```
sf-tools（テンプレートの正本）                force-* リポジトリ（完全内包版）
templates/.github/workflows/  ─sf-init→   .github/workflows/
├── wf-validate.yml                        ├── wf-validate.yml
├── wf-sequence.yml                        ├── wf-sequence.yml
├── wf-release.yml                         ├── wf-release.yml
├── wf-propagate.yml                       ├── wf-propagate.yml
└── wf-metasync.yml                        └── wf-metasync.yml
```

**設計理由:** sf-tools リポジトリへの依存をなくし、各プロジェクトが独立して動作する。WF を変更する場合は `sf-tools/templates/` を更新し、`sf-sync-wf.sh`（未実装）で各プロジェクトへ配布する。

### 4.2 ワークフロー一覧

ファイル名・WF 名・トリガーの詳細は `doc/setup-guide.md` のセクション 5 を参照。

| ワークフロー | 目的 | ブロック |
| :--- | :--- | :--- |
| **wf-validate** | dry-run 検証 → PR にコメント投稿 | 失敗時ブロック |
| **wf-sequence** | マージ順序（プロモーション順序）チェック | 環境ブランチ間のみブロック |
| **wf-release** | 対応組織へリリース → Slack 通知 | — |
| **wf-propagate** | main → staging / develop へ連鎖伝播 | — |
| **wf-metasync** | 本番組織のメタデータを main へ自動同期 | — |

### 4.3 Slack 通知

| イベント | 通知内容 |
| :--- | :--- |
| リリース成功/失敗（sf-release） | リリース先・PR 情報・Actions ログへのリンク |
| マージ順序未確認（sf-sequence） | 未マージのブランチ・PR 情報 |
| 下流伝播コンフリクト（sf-propagate） | コンフリクト発生ブランチ・PR 情報・Actions ログへのリンク |

---

## 5. 各ワークフロー詳細

### 5.1 wf-validate（PR 検証）

PR の作成・更新をトリガーに、sf-release.sh を **検証モード（`--release` なし = dry-run）** で実行する。

**処理フロー:**
1. マージ先ブランチに応じて接続する Salesforce 組織を選択
2. sf-release.sh を検証モードで実行
3. 検証結果を **PR にコメントとして投稿**（成否・ログ付き）
4. 検証失敗時は exit 1 でマージをブロック

**接続先の切り替え:**
| マージ先 | 認証 Secret | 接続組織 |
| :--- | :--- | :--- |
| main | `SF_CONSUMER_KEY_PROD` / `SF_USERNAME_PROD` / `SF_INSTANCE_URL_PROD` | 本番組織 |
| staging | `SF_CONSUMER_KEY_STG` / `SF_USERNAME_STG` / `SF_INSTANCE_URL_STG` | ステージング組織 |
| develop / その他 | `SF_CONSUMER_KEY_DEV` / `SF_USERNAME_DEV` / `SF_INSTANCE_URL_DEV` | 開発組織 |

全組織共通: `SF_PRIVATE_KEY`（JWT Bearer Flow 用 PEM 秘密鍵）

### 5.2 wf-sequence（マージ順序チェック）

`branches.txt` に記載されたブランチへの PR 時にプロモーション順序を検証する。
**branches.txt は常に `origin/main` から読み込む**（PR のマージコミットには含まれない場合があるため）。

**動作:**
- マージ元が branches.txt 記載のブランチ（環境ブランチ）→ **エラーでブロック**
- 順序未確認（例: staging 未マージで main へ PR）→ **警告 + Slack 通知（ブロックしない）**
- branches.txt が見つからない場合 → チェックをスキップ
- 順序 OK → 正常終了

**設計判断:** 警告のみにすることで、緊急の Hotfix を妨げない。Slack 通知でチームへの可視性は確保する。

### 5.3 wf-release（リリース実行）

PR マージ後に、マージ先ブランチに対応する Salesforce 組織へリリースを実行する。

**処理フロー:**
1. リリース先情報を GitHub Actions Summary に記録
2. マージ先に応じた組織に認証
3. `sf-tools/release/branch_name.txt` を動的生成（ローカルでは sf-start.sh が自動生成）
4. `sf-release.sh --release --no-open --target <alias>` を実行
5. 成否に関わらず **Slack へ結果を通知**

### 5.4 wf-propagate（下流ブランチ伝播）

main への PR マージ後に、下位ブランチへ変更を自動伝播する。

```
main → staging   （git merge & push）
main → develop   （git merge & push）
```

**注意:**
- **Git 上の同期のみ** であり、Sandbox 組織への自動デプロイは行わない
- sf-metasync.sh のボット push（GitHub Actions bot による直接 push）では **このワークフローは発火しない**（caller の on: pull_request は PR マージ時のみトリガー）
- sf-metasync.sh による本番同期の下流伝播は sf-metasync.sh 自身が担う
- **現状ハードコードされているのは wf-propagate 側の staging / develop である。** 一方、sf-metasync.sh 側の下流伝播は `branches.txt` を読む動的実装になっている
- caller 側で `permissions: contents: write` を付与する必要がある

**コンフリクト検知:**
develop / staging で並行開発中の変更と main の変更が同じ箇所に及んだ場合、マージがコンフリクトする可能性がある。コンフリクト発生時はマージを中止し、**Slack に通知**して手動対応を促す。自動解決は行わない（人間が判断すべき状況のため）。

### 5.5 wf-metasync（本番組織の自動同期）

**実行スケジュール:** `cron: "0 0-10/3 * * 1-5"`（UTC 0:00 / 3:00 / 6:00 / 9:00 = JST 9:00 / 12:00 / 15:00 / 18:00、平日のみ、3 時間おき）

**処理フロー:**
1. main ブランチを全履歴付きでチェックアウト（SGD が全履歴を必要とするため。`PAT_TOKEN` で checkout することで後続の push がブランチ保護をバイパス可能）
2. Node.js / Salesforce CLI をインストール
3. 本番組織に JWT Bearer Flow で認証（`SF_PRIVATE_KEY` / `SF_CONSUMER_KEY_PROD` / `SF_USERNAME_PROD` / `SF_INSTANCE_URL_PROD`）
4. sf-tools をクローンして sf-metasync.sh を実行
5. SGD で前回同期コミットからの差分 `package.xml` を生成
6. 差分取得 + `sf-tools/config/metadata.txt` に定義されたメタデータタイプを一括 retrieve
7. 変更がある場合: git commit → push（main へ直接 push）→ staging / develop へ伝播
8. 変更がない場合: 何もせず正常終了

**対象メタデータタイプ:**
`sf-tools/config/metadata.txt` の設定に従う。このファイルは force-*（Salesforce プロジェクト）の管理者が、sf-metasync で同期するメタデータタイプを定義する。1 行 1 タイプ、`#` でコメント、空行は無視。

---

## 6. デプロイ定義ファイル

### 6.1 ファイル配置

```
sf-tools/release/<branch>/
├── deploy-target.txt    # 追加/更新対象
└── remove-target.txt    # 削除対象
```

`sf-tools/release/branch_name.txt` にブランチ名を書き込むことで、どの release ディレクトリを参照するかを sf-release.sh に伝える。

### 6.2 deploy-target.txt の形式

書き方の詳細は `README.md` のセクション 5 を参照。

内部動作:
- `[files]` セクション → `sf project deploy start --source-dir` 引数に変換
- `[members]` セクション → `sf project deploy start --metadata` 引数に変換（部分デプロイ用）

### 6.3 デプロイ対象なしの扱い

deploy-target.txt が空（コメントのみ）の場合、sf-release.sh は内部的には `RET_NO_CHANGE` として扱うが、CLI の終了コードは `0` で正常終了する。CI でも失敗扱いにはならない。

---

## 7. セットアップ要件

### 7.1 GitHub Secrets（force-* リポジトリに設定）

| Secret | 用途 |
| :--- | :--- |
| `SF_PRIVATE_KEY` | JWT Bearer Flow 用 PEM 秘密鍵（全組織共通） |
| `SF_CONSUMER_KEY_PROD` | 本番組織 Connected App のコンシューマーキー |
| `SF_CONSUMER_KEY_STG` | ステージング組織 Connected App のコンシューマーキー |
| `SF_CONSUMER_KEY_DEV` | 開発組織 Connected App のコンシューマーキー |
| `SF_USERNAME_PROD` | 本番組織の接続ユーザー名 |
| `SF_USERNAME_STG` | ステージング組織の接続ユーザー名 |
| `SF_USERNAME_DEV` | 開発組織の接続ユーザー名 |
| `SF_INSTANCE_URL_PROD` | 本番組織の接続 URL（例: `https://login.salesforce.com`） |
| `SF_INSTANCE_URL_STG` | ステージング組織の接続 URL |
| `SF_INSTANCE_URL_DEV` | 開発組織の接続 URL |
| `PAT_TOKEN` | GitHub Classic PAT（`repo` + `workflow` スコープ）— sf-metasync がブランチ保護をバイパスして main に直接 push するために必要 |
| `SLACK_BOT_TOKEN` | Slack API の Bot Token |
| `SLACK_CHANNEL_ID` | 通知先 Slack チャンネル ID |

JWT 秘密鍵の作成: `openssl genrsa -out server.key 2048` → 公開鍵を Salesforce Connected App に登録
PAT の作成: GitHub → Settings → Developer Settings → Personal access tokens (classic) → `repo` と `workflow` スコープにチェック

### 7.2 GitHub リポジトリ設定

- **Settings → Actions → General:** 「Allow GitHub Actions to create and approve pull requests」を有効化
- **Branch Protection:** sf-validate チェックを必須に設定（マージブロック用）
- **ブランチ構成:** `sf-tools/config/branches.txt` に記載されたブランチが存在すること

### 7.3 ローカル環境

- Git（Git Bash 推奨 on Windows）
- GitHub CLI（`gh` コマンド）
- Node.js / npm（Salesforce CLI のインストール・依存管理に必要）
- Java（SGD の実行に必要）
- Salesforce CLI（`sf` コマンド）
- Visual Studio Code（`code` コマンドが PATH に含まれること）

---

## 8. 設計上のトレードオフと判断

| 判断 | 理由 |
| :--- | :--- |
| 本番同期を PR なしの直接 push にした | 毎時の同期に承認は不要。ボットコミットで手動コミットと区別可能。管理者の負担を最小化。PAT_TOKEN でブランチ保護ルールをバイパスする。 |
| sf-metasync のボット push で propagate を発火させない | PR マージ時のみトリガー。メタデータ同期の下流伝播は sf-metasync.sh 自身が担う。 |
| マージ順序チェックを警告のみ（ブロックしない）にした | 緊急 Hotfix を妨げないため。Slack 通知で可視性は確保。 |
| 環境ブランチ間の直接マージはブロック | 意図しない変更の混入を防止。feature 経由を強制し、各環境のデプロイ内容を追跡可能にする。 |
| deploy-target.txt が空なら正常終了（内部的には RET_NO_CHANGE、終了コードは 0） | CI でリリース定義だけ先に準備する運用を許容するため。 |
| セルフコンテインド WF + `sf-tools/templates/` 一元管理 | sf-tools への実行時依存をなくし、各プロジェクトが独立して動作する。WF 変更は sf-sync-wf.sh（未実装）で各プロジェクトへ配布。 |
| 24 時間スロットルでツール更新 | 毎回 sf-start.sh 実行時にアップデートすると起動が遅くなるため。 |
| 下流伝播のコンフリクトは自動解決しない | 本番と開発で同じ箇所が変更された状況は人間が判断すべき。Slack 通知で検知し手動対応。 |
| 本番の変更を 1 時間以内に全環境へ伝播 | 古いコードベースでの開発によるデグレを防止する。 |
| branches.txt でブランチ構成を動的化 | プロジェクト規模に応じて 1〜3 階層を選択可能にする。sf-sequence は origin/main から読み込む。 |
| sf-next.sh で次の PR 先を自動判定 | マージ順序の間違いを防止。ブラウザで PR 作成画面を直接開ける。 |
