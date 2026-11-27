# Salesforce Git 運用・CI/CD 基本戦略＆設計思想

> **本ドキュメントの範囲:** 設計思想・判断理由・ワークフロー全体像。実装の詳細（ファイルパス・コマンド引数等）はコードを正とします。
> 利用者向けの読み物（要点のみ）は、文書サイトの `site/design/cicd.html`。設計を変えたときは、両方を直すこと。

## 1. 目的

Salesforce メタデータの「パッチ形式」の特性を最大限に活かし、Git と各組織（Production / Staging / Dev）の整合性を保つ。

**設計上の 3 つの柱:**

1. **本番が正（Source of Truth）** — 本番組織の変更を SGD で高速検知し、人間を介さず全環境へ定期的に（平日 3 時間おき）波及させる「自己修復型同期」
2. **スター型プロモート** — feature ブランチ（作業用ブランチ）から各環境へ個別に PR を送る。環境ブランチ間の直接マージは禁止
3. **セルフコンテインド WF** — ワークフローの定義（起動の条件・ジョブ・ステップ）を各プロジェクト（force-*）の `.github/workflows/` に内包し、`sf-tools/templates/` からの配布で管理する。処理の中身（`sf-release.sh`・`sf-metasync.sh`）は、実行のたびに sf-tools を clone して使う

---

## 2. 環境構成とブランチ戦略

### 2.1 ブランチ構成の動的設定（branches.txt）

ブランチ階層は、各プロジェクト（force-*）の `sf-tools/config/branches.txt` で **プロジェクトごとに設定可能**。
`sf-init` が作る（Phase 4 で雛形 `templates/sf-tools/config/branches.txt` をコピーし、Phase 5 で選んだ構成に書き直す。リモートのブランチは Phase 8 が作る）。あとから階層を足すときは `sf-init.sh --add-tier staging|develop`。日常の `sf-install.sh` は、branches.txt がなければ、生成せずに中断する（プロジェクトの破損として扱う）。

| パターン | branches.txt | 用途 |
| :--- | :--- | :--- |
| **3階層** | main / staging / develop | 標準構成（開発→検証→本番） |
| **2階層** | main / staging | 開発組織を使わない場合 |
| **1階層** | main | 小規模プロジェクト・単独開発 |

main は必須。develop を使う場合は staging も必須（雛形のコメントの規則）。

### 2.2 環境マッピング（3階層の場合）

| 層 | 環境（Org） | ブランチ | エイリアス | 役割 |
| :--- | :--- | :--- | :--- | :--- |
| **本番層** | Production | `main` | `prod` | **正（Source of Truth）**。本番の最新状態。 |
| **検証層** | Staging / UAT | `staging` | `staging` | 結合テスト・顧客確認用。 |
| **開発層** | Development / QA | `develop` | `develop` | 初期検証用。開発のベースライン。 |
| **作業層** | 各 Sandbox | 作業用ブランチ（ジョブ名。例: `JOB-20260323`） | 任意（`sf-start.sh` で入力） | 作業項目ごとのソースの源泉。 |

- 本書の「feature ブランチ」は、この作業用ブランチを指す。`sf-job.sh` が、ジョブ名で、GitHub 上の `main` の最新から作る（ジョブ名は英数字・`-`・`_` だけのため、`feature/xxx` のような `/` を含む名前は作らない。`main` / `staging` / `develop` / `admin` は使えない）
- エイリアス `prod` / `staging` / `develop` / `main` は予約名（共有環境）。ローカルからは、これらの組織へリリース・検証できない（3.6）

### 2.3 プロジェクトの作成（管理者が先）

プロジェクト（`force-XXXX`）は、**管理者が先に** `sf-init.sh` で作る（リポジトリ・ワークフロー・ブランチ・Ruleset・Secrets / Variables・組織への JWT 接続・最初のメタデータの同期）。管理者用のクローンは `admin/force-XXXX`（`admin` ブランチ。日常の開発には使わない）。

開発者は、管理者から完成の連絡を受けてから、`sf-job.sh` で作業を始める。リポジトリがまだなければ、`sf-job.sh` は中断するため、**管理者と開発者の作業は、並行して進められない**（詳細は `doc/dev-reference.md` の 4.13・8）。

---

## 3. リリース戦略（スター型プロモート）

### 3.1 配布ルール

すべてのリリースは feature ブランチ（作業用ブランチ）を起点とし、各ターゲットブランチへ **個別に PR** を作成してデプロイする。

```
JOB-xxx ──→ develop   （開発組織へリリース）
JOB-xxx ──→ staging   （ステージング組織へリリース）
JOB-xxx ──→ main      （本番組織へリリース）
```

デプロイ対象は、作業用ブランチにコミットした `sf-tools/release/<作業用ブランチ名>/deploy-target.txt`（追加・更新）と `remove-target.txt`（削除）に記載したコンポーネントのみ（6 章）。同じターゲットファイルが、各環境への PR で使われる。

**設計理由:** 環境ブランチ間でマージすると、意図しない変更が混入するリスクがある。必ず feature ブランチを経由させることで、各環境に「何がデプロイされたか」を明確に追跡できる。

### 3.2 マージ順序チェック（一方通行。2026-11-26 から強制）

開発物は、`branches.txt` の逆順（下位 → 上位）に、**同じコミットのまま**上げる（3 階層なら `develop → staging → main`）。staging で問題が出たら、staging では直さず、開発環境で直して develop から出し直す。**推奨ではなく、仕組みで強制する決まり**（設計: `doc/one-way-promotion-design.md`。判定の本体は `bin/sf-promote-check.sh` の 1 か所）。

- **リリースの印**: wf-release は、組織へのリリースが成功したとき、PR の先端のコミットに commit status `sf-tools/released-<段階>` を付ける（信じるのは、wf-release の成功した実行が付けたものだけ）
- **R1 順序**: main / staging への PR で、wf-sequence が、PR の先端のコミットに 1 つ前の段階の印があるかを確かめる。なければ、ジョブ「順序チェック」を**失敗にする**（PR の会話欄に「⛔ 一方通行の決まりにより、この PR はマージできません」・Slack 通知）。警告だけにする扱い・Hotfix の例外は、なくした
- **R2 積み重ね**: wf-validate が、同じブランチから前に同じ段階へ出した（まだ main まで届いていない）リリースの部品が、今回の宣言に全部あるかを確かめる（dry-run の前。破ればジョブ「デプロイ検証」が失敗）
- **R3 環境ブランチ**: 環境ブランチからの PR は失敗（3.4）
- **最後の守り**: wf-release は、マージのあと、R0〜R3 をすべて確かめ直し、破っていれば組織へ出さない（Ruleset が効かない組織でも、組織を守る）。wf-release の手動の実行（workflow_dispatch）は、なくした
- 開発者が `sf-next.sh` を使う限り、順序は守られる（3.3）

**段階の並びは、常に `origin/main` の branches.txt で決める**（`get_tier_list --strict`。読めない・構成が正しくないときは止める）。

| チェック対象（3階層の場合） | 確認内容 |
| :--- | :--- |
| staging への PR | PR の先端のコミットに、develop のリリースの印があるか |
| main への PR | PR の先端のコミットに、staging のリリースの印があるか（staging の印は、develop の印があるコミットにしか付かない） |

### 3.3 sf-next.sh（次のPR先の自動判定）

`sf-next.sh`（ランチャーの 5 Next）を実行すると、現在のブランチの**先端のコミット**が、どの段階まで出たかを確かめ、次に PR を出してよい段階を表示する。Y 入力でブラウザのPR作成画面を直接開く（PR そのものは作らない）。保護ブランチ（branches.txt のブランチ）・detached HEAD の上では、エラーで終了する。判定は `sf-promote-check.sh --plan` に任せる（自分では計算しない）。詳細は `doc/dev-reference.md` の 4.5。

**判定:** 段階を下から順に見て、先端のコミットに印がない最初の段階を「次のPR先」にする（全部にあれば完了）。develop に出したあとで変更して push すると、先端のコミットが変わるため、次の PR 先は develop に戻る。次の PR 先で R2 も確かめ、破っていれば PR を勧めない。

**表示ステータス:**

| 記号 | 表示 | 意味 |
| :--- | :--- | :--- |
| `✓` | リリース済み（このコミット） | 先端のコミットに、その段階の印がある |
| `▶` | 次のPR先 | 次に PR を出すべき段階 |
| `→` | PR発行中（#N） | 次の PR 先へ、PR を発行済み（マージ待ち） |
| `✗` | （文言なし） | 次の PR 先より上の段階 |

```
  JOB-xxx のリリース状況（先端のコミット）
  ────────────────────────────
    ✓ develop   リリース済み（このコミット）
    ▶ staging   次のPR先
    ✗ main
```

**下りの伝播はしない（2026-11-26 に廃止）:** 以前は、main へのマージで、wf-propagate が main を staging・develop へ伝播していた（そのため、順序を飛ばすと、飛ばしたブランチへ直接 PR を作れなくなった）。今は伝播しない。main の最新は、開発者の PC で `sf-push.sh` が取り込む。

### 3.4 マージ禁止制限（システムによる強制ブロック）

**環境ブランチ間の直接 PR** は wf-sequence で検知しエラーにする（ジョブ「順序チェック」が失敗する。PR の会話欄へのコメントと Slack 通知も行う）。
`branches.txt` に記載されたブランチからの main / staging への PR は全てブロック対象。

3階層の場合の例:
- develop → staging
- develop → main
- staging → main

実際にマージを止めるのは、`sf-init` の Phase 9 が作る Ruleset（`protect-main` / `protect-staging`）の必須チェック（4.2）。Ruleset を作れなかった場合（無料プランの Private リポジトリなど）は、失敗の表示だけで、マージは止まらない（レビュアーが却下する）。リポジトリの Admin は、Ruleset をバイパスできる。

**環境ブランチへの直接プッシュの禁止:** ローカルでは、pre-push フック（3.5）が、保護ブランチ（branches.txt のブランチ。ファイルがない・空なら main）の上からのプッシュと、保護ブランチへのプッシュ（`git push origin feature:main`・削除を含む）を拒否する。`sf-push.sh`・`sf-next.sh` も、保護ブランチの上では実行できない。サーバー側では、Ruleset の必須チェックを満たさない main / staging への push が拒否される（そのため、`wf-metasync`・`wf-propagate` は `PAT_TOKEN` でバイパスする）。

### 3.5 ローカルでのプッシュ前チェック（pre-push フック）

`git push` のとき、pre-push フック（本体は `sf-prepush.sh`）が、次を行う。
1. 保護ブランチの上からのプッシュ・保護ブランチへのプッシュを拒否する（3.4）
2. `sf-check.sh` でターゲットファイルを検証する（エラーなら中止）
3. リモートの最新 `origin/<現在のブランチ>` と `origin/main`（自動更新された本番の状態）に未取り込みのコミットがあれば、merge で取り込む。取り込んだときは、**そのプッシュを中止する**（git はフックの前にプッシュするコミットを決めているため）。もう一度プッシュすると通る

フック（pre-commit / pre-push）は、`sf-install.sh`（`sf-start.sh` がバックグラウンドで実行する）が `sf-hook.sh` で自動インストールする。pre-commit も、`sf-check.sh` でターゲットファイルを検証する。`sf-metasync.sh` の push は、`--no-verify` でフックを通さない（詳細は `doc/dev-reference.md` の 4.3・4.12）。

### 3.6 ローカルでの検証と、共有環境へのリリースの禁止

- **`sf-check.sh`（ターゲットファイルの検証）**: `[files]` のパス（存在するか・リポジトリの外を指さないか・書けるディレクトリか）、`[members]` の形式（`種別名:メンバー名`）、種類の可否（`config/metadata-capability.txt`。リリース・削除できない種類はエラー）、テストクラスの不足（警告のみ）を確かめる。`sf-push.sh`・pre-commit / pre-push フック・`sf-release.sh`・ランチャーの 1 Check から呼ばれる（詳細は `doc/dev-reference.md` の 4.14）
- **`sf-dryrun.sh`（ランチャーの 2 Dryrun）**: `sf-release.sh` を検証モード（`sf project deploy start --dry-run`）で実行する。組織には反映しない
- **`sf-deploy.sh`（ランチャーの 3 Deploy）**: `sf-release.sh --release --force` のラッパー。個人用の Sandbox / Developer Edition / Scratch Org への強制リリース用（確認 Y/N あり）
- **共有環境の保護**: ローカル（`GITHUB_ACTIONS` が `true` 以外）からは、接続先のエイリアスが予約名（`prod` / `staging` / `develop` / `main`）の組織へは、dry-run を含めて実行できない。名前を付け替えた本番組織も止めるため、予約名でなくても組織の種類を調べ、本番、または種類を確認できない組織は中断する（`org_local_release_check`）。共有環境へのリリースは、GitHub にコミットし、PR のレビューを通して、GitHub Actions（wf-release）で行う（詳細は `doc/dev-reference.md` の 4.2・4.8）

### 3.7 開発者の日々の流れ（ランチャー）

1. `sf-job.sh`: ジョブ名を入力 → GitHub 上の `main` から作業用ブランチを作成 → `./{ジョブ名}/force-XXXX` にクローン → `sf-start.sh` を実行
2. `sf-start.sh`: 組織に接続（個人用の Sandbox など）→ VS Code を起動 → バックグラウンドで `sf-install.sh`（フック・`sf-tools/release/<ブランチ>/`・ツールの更新）→ 前面で `sf-launcher.sh` を起動
3. `sf-launcher.sh`（メニュー）: 1 Check（`sf-check.sh`）/ 2 Dryrun（`sf-dryrun.sh`）/ 3 Deploy（`sf-deploy.sh`）/ 4 Push（`sf-push.sh`）/ 5 Next（`sf-next.sh`）/ 6 Start / 7 Restart（VS Code のターミナルでは 6・7 は出ない）
4. `sf-push.sh`: `origin/main` を取り込み → カレント配下だけをコミット（`sf-check.sh` の検証のあと、VS Code でメッセージを入力）→ プッシュ
5. `sf-next.sh`: 次の PR 先を判定して、PR の作成画面を開く（3.3）。PR のマージで、wf-release が対応する組織へリリースする

---

## 4. CI/CD ワークフロー全体像

### 4.1 セルフコンテインド WF パターン

ワークフローの定義は各 Salesforce プロジェクト（force-*）の `.github/workflows/` に **内包**する（reusable workflow を呼ばない）。`sf-tools/templates/.github/workflows/` が唯一の正本であり、`sf-init` 実行時（Phase 3）にコピーされる。

```
sf-tools（テンプレートの正本）                force-* リポジトリ（完全内包版）
templates/.github/workflows/  ─sf-init→   .github/workflows/
├── wf-validate.yml                        ├── wf-validate.yml
├── wf-sequence.yml                        ├── wf-sequence.yml
├── wf-release.yml                         ├── wf-release.yml
└── wf-metasync.yml                        └── wf-metasync.yml
```

**設計理由:** reusable workflow を通じた sf-tools リポジトリへの依存をなくし、各プロジェクトのワークフローが独立して動作する。WF を変更する場合は `sf-tools/templates/` を更新し、`sf-sync-wf.sh` で各プロジェクトへ反映する（管理者が手動で実行し、作業用ブランチ → PR で入れる。詳細は `doc/wf-distribution-strategy.md`）。

ただし、wf-validate・wf-release・wf-metasync は、実行のたびに、公開リポジトリの sf-tools を Token なしで clone し（Variable `SF_TOOLS_BRANCH` のブランチ。未設定なら `main`）、`sf-release.sh`・`sf-metasync.sh` を使う。そのため、スクリプトの修正は、sf-tools の `main` へのマージで、全プロジェクトにすぐ届く。配布済みの `force-*` に自動で届かないのは、WF 自体の変更だけ。

### 4.2 ワークフロー一覧

ファイル名・トリガーの正本は、各ワークフロー（`templates/.github/workflows/*.yml`）本体の冒頭コメント。ジョブ名・concurrency の一覧は `doc/wf-distribution-strategy.md` の 2.1。読み物としての一覧は、文書サイトの `site/admin/workflows.html`（本書より後に書かれた、利用者向けの説明）。

| ワークフロー（Actions の画面での名前） | 目的 | ブロック |
| :--- | :--- | :--- |
| **wf-validate**（`[validate] デプロイ前検証`） | PR の作成・更新で dry-run 検証 → PR にコメント投稿 | main / staging への PR で、失敗時ブロック（必須チェック） |
| **wf-sequence**（`[sequence] マージ順序チェック`） | main / staging への PR で、一方通行の順序（R1）・環境ブランチ（R3）のチェック | 順序外・環境ブランチからの PR をブロック（必須チェック） |
| **wf-release**（`[release] デプロイ`） | PR のマージで、一方通行の決まり（R0〜R3）を確かめ直し、対応組織へリリース → リリースの印 → Slack 通知 | マージは止められないが、破っていれば組織へ出さない（最後の守り） |
| **wf-metasync**（`[metasync] メタ同期`） | 本番組織のメタデータを main へ定期同期 | — |

**必須チェック:** Ruleset（`protect-main` / `protect-staging`。`sf-init` の Phase 9 が作る）に登録するのは、ワークフローの**ジョブ名だけ**（`対象ファイル確認`・`デプロイ検証`・`順序チェック`。正本は `lib/project.sh` の `required_status_check_names`）。`ワークフロー名 / ジョブ名` の形では永久に満たされず、PR がマージできなくなる。ジョブ名を変えるときは、既存の force-* の Ruleset も直す（食い違いは `sf-init.sh --status` が検出する。詳細は `doc/dev-reference.md` の 9.5）。デプロイ対象のない PR は、検証のジョブがスキップされ、必須チェックとしては成功として扱われる。

### 4.3 Slack 通知

| イベント | 通知内容 |
| :--- | :--- |
| リリース成功/失敗（wf-release） | リリース先・PR 情報・Actions ログへのリンク（デプロイ対象がなくスキップしたときは通知しない） |
| 順序外・環境ブランチからの PR（wf-sequence） | 理由（どの段階に出ていないか）・PR 情報 |
| 一方通行の決まりでリリースを止めた（wf-release） | 「リリースを止めました」・PR 情報・Actions ログへのリンク（組織は変わっていない） |

wf-validate の結果は、Slack ではなく PR のコメントで知らせる。wf-metasync は、失敗しても Slack に通知しない（ジョブが失敗するだけ）。

---

## 5. 各ワークフロー詳細

### 5.1 wf-validate（PR 検証）

PR の作成・更新（opened / synchronize / reopened。マージ先は問わない）をトリガーに、sf-release.sh を **検証モード（`--release` なし = dry-run）** で実行する。

**処理フロー:**
1. ジョブ「対象ファイル確認」: `sf-tools/release/<ソースブランチ名>/` のターゲットファイルに実質的な行がなければ、検証をスキップする
2. ジョブ「デプロイ検証」: マージ先ブランチに応じて接続する Salesforce 組織を選択し、JWT でログイン
3. PR の先端のコミットを `force-promote-check/` に取得し、`sf-promote-check.sh --pr <番号> --only stack`（R0・R2。積み重ね）を実行する。破っていれば、dry-run をせずに失敗する
4. `branch_name.txt` にソースブランチ名を書き、sf-release.sh を検証モードで実行
5. 検証結果を **PR にコメントとして投稿**（成否・ログ付き。毎回、新しいコメントを追加）
6. 検証失敗時はジョブが失敗する。main / staging への PR では、必須チェックのため、マージできない（それ以外への PR は、表示だけ）

**接続先の切り替え:**
| マージ先 | 認証情報（Secret / Variable） | 接続組織 |
| :--- | :--- | :--- |
| main | `SF_CONSUMER_KEY_PROD` / `SF_USERNAME_PROD` / `SF_INSTANCE_URL_PROD` | 本番組織 |
| staging | `SF_CONSUMER_KEY_STG` / `SF_USERNAME_STG` / `SF_INSTANCE_URL_STG` | ステージング組織 |
| develop / その他 | `SF_CONSUMER_KEY_DEV` / `SF_USERNAME_DEV` / `SF_INSTANCE_URL_DEV` | 開発組織 |

`SF_CONSUMER_KEY_*` は Secret、`SF_USERNAME_*`・`SF_INSTANCE_URL_*` は Variable。全組織共通: `SF_PRIVATE_KEY`（JWT Bearer Flow 用 PEM 秘密鍵を 1 行の Base64 にした値。Secret）。
DEV の組織を登録していない構成（main のみ・main + staging）で、main / staging 以外へ PR を出すと、ログインで失敗する。

### 5.2 wf-sequence（マージ順序チェック）

main / staging への PR 時（opened / synchronize / reopened）にプロモーション順序を検証する（develop への PR では動かない）。
**branches.txt は常に `origin/main` から読み込む**（PR のマージコミットには含まれない場合があるため）。
ジョブ「対象ファイル確認」は、ソースブランチのターゲットファイルに実質的な行がなければ、順序チェックをスキップする（ソースが環境ブランチのときは、スキップしない）。

**動作:**
- マージ元が branches.txt 記載のブランチ（環境ブランチ）→ **エラーでブロック**（PR へのコメント + Slack 通知も行う）
- 順序外（PR の先端のコミットに、1 つ前の段階のリリースの印がない。例: develop に出したあとで変更したコミットを staging へ）→ **エラーでブロック**（「⛔ 一方通行の決まりにより、この PR はマージできません」のコメント（同じ PR では既存のコメントを更新）+ **Slack 通知**）
- branches.txt が見つからない・構成が正しくない場合 → **エラーでブロック**（判断できないときは止める。R0）
- 順序 OK → 正常終了（以前の ⛔ のコメントがあれば「✅ 問題ありません」に更新）
- 判定は `sf-promote-check.sh --pr <番号> --only sequence --json`（PR の先端のコミットを `force-promote-check/` に取得して、その中で実行）

**設計判断（2026-11-26 に変更）:** 順序は、開発者がランチャー（`sf-next.sh`）を使う限り守られる。以前は、ランチャーを使わずに GitHub 上で直接 PR を作った場合に、**レビュアーが気づける**ことを目的に、警告だけにしていた（Hotfix を妨げないため）。前の段階を飛ばしたリリースで本番だけが失敗した事故（force-test-win・PR #18）から、仕組みで止める形に変えた（`doc/one-way-promotion-design.md`）。以下は、以前の判断の記録（判定は、PR を作った時点で行う。push だけでは、どの段階へ出すか分からないため）。警告のみにして、設定ファイルやチェックの失敗は、設けない（Free プランの Private リポジトリでは、GitHub がマージを止められず、失敗にしても、却下するのは、レビュアーであるため。緊急の Hotfix も、妨げない）。

**テスト:** `tests/test_wf-sequence.sh`（YAML の判定スクリプトを取り出して、実際の git リポジトリで、全パターンを実行する）。

### 5.3 wf-release（リリース実行）

PR が main / staging / develop にマージされたあとに、マージ先ブランチに対応する Salesforce 組織へリリースを実行する（手動の workflow_dispatch は、2026-11-26 になくした。PR を通らずに組織へ出す道をなくすため。失敗したリリースのやり直しは、その実行の「Re-run jobs」）。

**処理フロー:**
1. ジョブ「リリース対象確認」: ターゲットファイルに実質的な行がなければ、リリースをスキップする（Slack にも通知しない）
2. ジョブ「リリース実行」: リリース先情報を GitHub Actions Summary に記録
3. マージ先に応じた組織だけに JWT で認証（main → prod、staging → staging、develop → develop）
4. `sf-tools/release/branch_name.txt` にソースブランチ名を書く（ローカルでは `sf-install.sh` が書く）
5. **一方通行の確認（最後の守り）**: PR の先端のコミットを `force-promote-check/` に取得し、`sf-promote-check.sh --pr <番号>`（`--only` なし = R0〜R3）を実行する。破っていれば、組織へ出さずに失敗する
6. `sf-release.sh --release --no-open --target <alias>` を実行
7. 成功したら、PR の先端のコミットに、リリースの印（commit status `sf-tools/released-<段階>`）を付ける（3 回まで試し、だめならジョブを失敗にする。権限 `statuses: write`）
8. 成否に関わらず **Slack へ結果を通知**（止めたときは「リリースを止めました」）

同時実行の制御: マージ先のブランチごとに、1 つずつ動く（待機中のものも、すべて残す）。ジョブ名「リリース対象確認」は、必須チェックの「対象ファイル確認」と、わざと別の名前にしてある（同じコミットが次の段階の PR にも使われるため。`doc/wf-distribution-strategy.md` の 2.1）。

### 5.4 wf-propagate（下流ブランチ伝播。2026-11-26 に廃止）

**廃止した**（雛形から消した。既存の force-* は `sf-sync-wf.sh --remove wf-propagate.yml` で消す）。サーバーで全員のブランチへ一斉にマージすると、作業中の手元と食い違い、コンフリクトを解けないため。main の最新は、開発者の PC で `sf-push.sh` が取り込む。環境のブランチは、PR で上がってくる開発のブランチだけで更新され、main とずれてよい（組織と中身の一致は、上りの PR の一方通行の決まりで守る。`doc/one-way-promotion-design.md` 3.7）。以下は、以前の動きの記録。

以前の動き: main への PR マージ後に、下位ブランチへ変更を自動伝播していた（手動の workflow_dispatch もあった。main で実行したときだけ伝播した）。

```
main → staging   （git merge & push。PR は通さない）
main → develop   （git merge & push。PR は通さない）
```

**注意:**
- **Git 上の同期のみ** であり、Sandbox 組織への自動デプロイは行わない（伝播の push は pull_request ではないため、wf-release は動かない）
- sf-metasync.sh のボット push（GitHub Actions bot による直接 push）では **このワークフローは発火しない**（起動の条件は、main への PR のマージ（pull_request の closed）と手動の実行だけ）
- sf-metasync.sh による本番同期の下流伝播は sf-metasync.sh 自身が担う
- **現状ハードコードされているのは wf-propagate 側の staging / develop である**（ブランチがない構成では、そのブランチの伝播をスキップする）。一方、sf-metasync.sh 側の下流伝播は `branches.txt` を読む動的実装になっている
- チェックアウトと push には `PAT_TOKEN` を使う（staging の Ruleset のバイパスと、`.github/workflows/` の変更を含むマージの push のため）。ワークフローに `permissions: contents: write` を付与している
- 続けてマージしても、伝播は 1 つずつ動く（concurrency `propagate`）

**コンフリクト検知:**
develop / staging で並行開発中の変更と main の変更が同じ箇所に及んだ場合、マージがコンフリクトする可能性がある。コンフリクト発生時はマージを中止し、**Slack に通知**して、ジョブを失敗させ、手動対応を促す。自動解決は行わない（人間が判断すべき状況のため）。

### 5.5 wf-metasync（本番組織の自動同期）

**実行スケジュール:** `cron: "0 0 * * 1-5"`（UTC 0:00 = JST 9:00、平日、毎日 1 回。`--full` 付き）と `cron: "0 3-10/3 * * 1-5"`（UTC 3:00 / 6:00 / 9:00 = JST 12:00 / 15:00 / 18:00、平日のみ、3 時間おき）。変更の検知（Variable `SF_METASYNC_DETECT` が shadow・on のとき）が「変更なし」なら、全件取得を省く（`--full` の回と手動の実行は、省かない）。手動の workflow_dispatch もある（`sf-init` のセットアップの最後と、`sf-init.sh --verify` が起動する）。同時実行は、1 つずつ（concurrency `metasync`）。

**処理フロー:**
1. main ブランチを全履歴付きでチェックアウト（直近のマージの確認（`git log --since`。削除の守り S5）に、履歴が要るため。`PAT_TOKEN` で checkout することで、後続の push が Ruleset `protect-main` / `protect-staging` をバイパス可能。PAT の持ち主が Admin のとき）
2. Node.js / Salesforce CLI をインストール（以前入れていた Java と sf のプラグイン sfdx-git-delta は、使わなくなったため外した）
3. 本番組織（エイリアス `prod`）に JWT Bearer Flow で認証（`SF_PRIVATE_KEY` / `SF_CONSUMER_KEY_PROD` / `SF_USERNAME_PROD` / `SF_INSTANCE_URL_PROD`）
4. sf-tools をクローンして sf-metasync.sh を実行
5. `git pull origin main --rebase` のあと、組織から一時プロジェクトへ取得する準備（`sfdx-project.json` の確認など）
6. `sf-tools/config/metadata.txt` に定義されたメタデータタイプを、一時プロジェクトへ一括 retrieve（一時的なエラーは 1 回だけやり直す）→ `lib/metasync.js` で、main の「同期の対象のフォルダ」を、取得結果と同じにする（追加・変更・**削除**。削除には安全の守り S2〜S5 があり、当たったものは保留）。設計: `doc/sf-metasync-redesign.md`
7. 変更がある場合: git commit → push（main へ直接 push。`--no-verify`）。staging・develop のブランチへは伝播しない（2026-11-26 にやめた）。削除の保留（S2〜S4）があるときは、これらを行ったあと終了コード 3（ジョブは失敗として表示される）
8. 変更がない場合: 何もせず正常終了

詳細は `sf-metasync.sh` の冒頭コメントと `doc/dev-reference.md` の 4.3。

**対象メタデータタイプ:**
force-* の `sf-tools/config/metadata.txt` の設定に従う。このファイルは force-*（Salesforce プロジェクト）の管理者が、sf-metasync で同期するメタデータタイプを定義する。1 行 1 タイプ、`#` でコメント、空行は無視。雛形（`templates/sf-tools/config/metadata.txt`）は、Developer Edition でリリース・削除を確認した標準セットを有効にしている（種類ごとの可否は `config/metadata-capability.txt`・`sf-typecheck.sh`）。

---

## 6. デプロイ定義ファイル

### 6.1 ファイル配置

```
sf-tools/release/<作業用ブランチ名>/   ← force-* のリポジトリの中（作業用ブランチと一緒にコミットする）
├── deploy-target.txt    # 追加/更新対象
└── remove-target.txt    # 削除対象
```

作業用ブランチで `sf-install.sh`（`sf-start.sh` が実行する）が、ディレクトリを作り、ファイルがなければ雛形（`config/install/release/`。sf-init が丸ごとコピーする `templates/` には置かない）からコピーする。`main` では作らない。

`sf-tools/release/branch_name.txt` にブランチ名を書き込むことで、どの release ディレクトリを参照するかを sf-release.sh・sf-check.sh に伝える（Git の管理外の手元のファイル。ローカルでは `sf-install.sh`、GitHub Actions では wf-validate・wf-release が、ソースブランチ名を書く）。

### 6.2 deploy-target.txt の形式

書き方の詳細は、文書サイトの `site/reference/target-files.html` を参照。

内部動作:
- `[files]` セクション（最初のマーカーより前の行を含む）→ `sf project generate manifest --source-dir` 引数に変換
- `[members]` セクション（`種別名:メンバー名`）→ `sf project generate manifest --metadata` 引数に変換（部分デプロイ用）
- 両者は別々にマニフェストを生成して 1 つの `package.xml` に統合し、`sf project deploy start --manifest` で検証・リリースする（同時に渡すと、sf CLI が共通部分だけを返すため）。remove-target.txt は `destructiveChanges.xml` にして `--pre-destructive-changes` で渡す（削除が先）
- deploy-target.txt の `[files]` の `.cls` に `@isTest` があれば、`--test-level RunSpecifiedTests` と `--tests <クラス名>` を付ける
- 詳細は `doc/dev-reference.md` の 4.2。検証の内容（sf-check.sh）は 3.6

### 6.3 デプロイ対象なしの扱い

deploy-target.txt と remove-target.txt の両方が空（コメント・空行・`[files]`・`[members]` のみ）の場合、wf-validate・wf-sequence・wf-release はジョブ「対象ファイル確認」「リリース対象確認」でスキップする（必須チェックとしては成功）。sf-release.sh を直接実行した場合も、内部的には `RET_NO_CHANGE` として扱い、「デプロイ対象なし。正常終了します。」で終了コード `0` で正常終了する。CI でも失敗扱いにはならない。
deploy-target.txt が空で remove-target.txt にだけ対象があれば、削除だけを行う。

---

## 7. セットアップ要件

### 7.1 GitHub Secrets / Variables（force-* リポジトリに設定）

すべて `sf-init` が登録する（登録元は各行。再登録は `sf-update-secret.sh`・`sf-init.sh --reconnect`・`sf-init.sh --add-tier`）。手で設定する必要はない。

| 名前 | 種別 | 用途（登録元） |
| :--- | :--- | :--- |
| `SF_PRIVATE_KEY` | Secret | JWT Bearer Flow 用 PEM 秘密鍵を 1 行の Base64 にした値（全組織共通。Phase 10） |
| `SF_CONSUMER_KEY_PROD` | Secret | 本番組織のアプリ（外部クライアントアプリケーション）のコンシューマー鍵（Phase 10） |
| `SF_CONSUMER_KEY_STG` | Secret | ステージング組織のアプリのコンシューマー鍵（Phase 10・`--add-tier`） |
| `SF_CONSUMER_KEY_DEV` | Secret | 開発組織のアプリのコンシューマー鍵（Phase 10・`--add-tier`） |
| `PAT_TOKEN` | Secret | GitHub Classic PAT（`repo` + `workflow` スコープ。持ち主はリポジトリの Admin）— wf-metasync が main に直接 push するために必要（main・staging の Ruleset のバイパスと、`.github/workflows/` の変更を含む push のため。Phase 6） |
| `SLACK_BOT_TOKEN` | Secret | Slack API の Bot Token（Phase 7） |
| `SF_USERNAME_PROD` / `_STG` / `_DEV` | Variable | 各組織の接続ユーザー名（Phase 10） |
| `SF_INSTANCE_URL_PROD` / `_STG` / `_DEV` | Variable | 各組織の接続 URL（例: `https://login.salesforce.com`。Phase 10） |
| `SLACK_CHANNEL_ID` | Variable | 通知先 Slack チャンネル ID（Phase 7） |
| `SF_TOOLS_BRANCH` | Variable | Actions が clone する sf-tools のブランチ（任意。未設定なら `main`。Phase 9 が、開発版のときだけ `development` を登録） |
| `SF_ORG_*` | Variable | 組織の情報（`sf-init.sh --status` の表示用） |

JWT の秘密鍵・証明書: Phase 10 が `openssl` で生成し（`~/.sf-jwt/<リポジトリ名>/`）、外部クライアントアプリケーションを組織ごとに自動作成して、コンシューマー鍵を取得する（従来の接続アプリケーション（`--legacy-connected-app`）は、廃止した）。
PAT の作成: Phase 6 が、Note・Scopes・Expiration を入力済みの作成ページをブラウザで開き、貼り付けた Token のスコープと Admin 権限を確かめてから登録する（詳細は `doc/dev-reference.md` の 4.13）。
`SF_TOOLS_TOKEN` は 2026-10-05 に廃止（sf-tools は公開リポジトリ）。

### 7.2 GitHub リポジトリ設定

`sf-init` の Phase 9 が自動で設定する（どれが失敗しても WARNING で続行する）。
- **基本設定（`gh repo edit`）:** 既定のブランチ main・マージの方法をすべて許可・マージ後のブランチの自動削除を無効 など
- **Ruleset `protect-main` / `protect-staging`:** 削除の禁止・強制プッシュの禁止・必須のステータスチェック 3 つ（ジョブ名だけ: `対象ファイル確認`・`デプロイ検証`・`順序チェック`。4.2）。バイパスはリポジトリの Admin。ブランチ構成に関係なく両方を作る。無料プランの Private リポジトリなど、Ruleset が使えない場合は、マージは止まらない
- **ブランチ構成:** `sf-tools/config/branches.txt` に記載されたブランチが存在すること（Phase 8 が push する）

### 7.3 ローカル環境

`sf-init` の Phase 1 が、`git` / `gh` / `node` / `npm` / `sf` / `code` の有無を確認する（利用者向けの手順は `site/guide/install.html`）。
- Git（Windows は Git Bash。PowerShell・コマンドプロンプトでは動かない）
- GitHub CLI（`gh` コマンド。認証済みであること）
- Node.js / npm（Salesforce CLI のインストール・依存管理に必要）
- Salesforce CLI（`sf` コマンド。**npm 版が前提**。Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）
- Visual Studio Code（`code` コマンドが PATH に含まれること）
- 管理者のみ: `openssl`（`sf-init` の Phase 10・`sf-update-secret.sh`）。手元で `sf-metasync.sh` を実行するときは、sf のプラグイン sfdx-git-delta（`sf sgd`）
- Bash 3.2 以上（macOS 標準の `/bin/bash` のままで動く）

---

## 8. 設計上のトレードオフと判断

| 判断 | 理由 |
| :--- | :--- |
| 本番同期を PR なしの直接 push にした | 数時間おき（平日の日本時間 9・12・15・18 時）の同期に承認は不要。ボットコミットで手動コミットと区別可能。管理者の負担を最小化。PAT_TOKEN で Ruleset（必須チェック）をバイパスする（PAT の持ち主が Admin のとき）。 |
| 下りの伝播（main → staging・develop）をしない（2026-11-26） | サーバーでの一斉のマージは、作業中の手元と食い違い、コンフリクトを解けない。main の最新は、開発者の PC で sf-push.sh が取り込む。以前の「sf-metasync のボット push で propagate を発火させない」「下流伝播のコンフリクトは自動解決しない」は、伝播とともになくなった。 |
| ローカルから共有環境（予約名の組織・本番組織）へは、dry-run を含めて実行させない | 共有環境への反映は、GitHub にコミットし、PR のレビューを通して、GitHub Actions だけで行う。名前を付け替えた本番組織も、組織の種類の確認で止める（誤操作の防止。共有環境の認証情報は GitHub Secrets にあり、手元にはない）。 |
| 一方通行の決まりを、仕組みで強制する（2026-11-26。以前は、マージ順序チェックを警告のみにしていた） | 前の段階を飛ばしたリリースで、本番だけが失敗した事故があったため。Hotfix の例外・wf-release の手動の実行もなくした。Ruleset が効かない組織でも、wf-release が組織を守る。 |
| 環境ブランチ間の直接マージはブロック | 意図しない変更の混入を防止。feature 経由を強制し、各環境のデプロイ内容を追跡可能にする。 |
| ターゲットファイルが空なら正常終了（WF はスキップ。sf-release.sh は内部的には RET_NO_CHANGE、終了コードは 0） | CI でリリース定義だけ先に準備する運用を許容するため。 |
| セルフコンテインド WF + `sf-tools/templates/` 一元管理 | reusable workflow を通じた sf-tools への依存をなくし、各プロジェクトのワークフローが独立して動作する。処理の中身（sf-release.sh・sf-metasync.sh）は実行時に sf-tools を clone するため、スクリプトの修正は rr で全プロジェクトに届く。WF 変更は sf-sync-wf.sh で各プロジェクトへ反映（管理者が手動で実行）。 |
| 24 時間スロットルでツール更新 | 毎回 sf-start.sh 実行時にアップデートすると起動が遅くなるため（`sf-install.sh` が、24 時間以上経っていれば `sf-upgrade.sh` をバックグラウンドで起動する）。 |
| 本番の変更を定期同期（平日 3 時間おき）で main へ取り込む | 古いコードベースでの開発によるデグレを防止する（開発のブランチは、sf-push.sh で main を取り込む）。 |
| branches.txt でブランチ構成を動的化 | プロジェクト規模に応じて 1〜3 階層を選択可能にする。wf-sequence は origin/main から読み込む。 |
| sf-next.sh で次の PR 先を自動判定 | マージ順序の間違いを防止。ブラウザで PR 作成画面を直接開ける。 |
