# sf-tools 開発・リリースの流れ（開発者向けガイド）

> **本書の位置づけ:** sf-tools 自体を開発・リリースする人向けの手順書です（以前は `README.md` の 9 章でした）。利用者向けの使い方は、文書サイト（`site/`）にあります。
> 実装の詳細は `doc/dev-reference.md`（9 章に、本書と同じ範囲の詳しい説明）、AI 向けの作業ルールは `CLAUDE.md` を参照してください。

> **e2e の実行について:** e2e は、GitHub Actions（`.github/workflows/e2e.yml`）でも動きます。通常は、Actions の結果が正です。同じテスト用の組織を使うため、**Actions の実行中に、手元で動かさないでください**。手元で動かすのは、新しい環境（Mac など）の確認や、不具合の調査のときです。

> **Actions の無料枠について（2026-10-23）:** e2e が使うテスト用の組織（非公開のリポジトリ）の GitHub Actions は、無料枠（月 2000 分）を使い切ると、起動の直後に失敗します（コードの不具合ではありません）。枠が回復するまで、`e2e.yml` は無効にしています。**枠が回復したら（11 月 1 日以降）、`gh workflow enable e2e.yml` で戻し、枠切れの間に変えた配布物を、e2e で確認してください。**

---

## 1. 全体の流れ

sf-tools の `main` ブランチは、**そのまま全ユーザーに配布される**ブランチです。各ユーザーの `~/sf-tools` は `git pull` で `main` を取り込みます。そのため、修正はいきなり `main` に入れず、次の順で進めます。

| 手順 | 内容 |
|---|---|
| 1. 修正 | `development` ブランチで修正し、変えたファイルのテスト（`bash tests/run_tests.sh --changed`）を PASS させる（`mm`：`development` までコミット・push）。push すると、GitHub Actions が、全件のテストを、Windows・macOS・Linux で自動で動かす（約 12 分）。赤なら直す |
| 2. 検証 | 実環境の動作を確認する。配布物（`bin/` `lib/` `phases/` `hooks/` `templates/` `config/`）か `tests/e2e/` を変えた `development` への push で、GitHub Actions の `e2e.yml` が、自動で実行する（下記の e2e。約 30 分）。結果は、`gh run list --workflow e2e.yml` で確認する |
| 3. リリース | 検証 OK を確認してから、`development` → `main` の PR をマージする（`rr`）。これが配布になる |

## 2. 検証環境とは

`sf-init.sh` の Phase 2 で「検証環境」を選んだ `force-*` のことです。そのリポジトリの GitHub Actions は、sf-tools の `main` ではなく `development` ブランチを使います（Variable `SF_TOOLS_BRANCH=development`）。開発者の `~/sf-tools` を `development` にしておけば、ローカルのコマンドも同じ内容で動きます。

## 3. 検証で確認すること

変更内容に応じて確認します。詳細は `doc/dev-reference.md` セクション 9 を参照してください。

- 新規セットアップ（`sf-init.sh`）が最後まで通ること。4 章の e2e で自動化できます
- メタデータ同期（`wf-metasync`）を手動実行して成功すること
- デプロイ対象を含む PR で `wf-validate` が通ること（動作確認だけの PR はマージせずに閉じる）

> ℹ️ `sf-tools` は公開リポジトリのため、`main` のブランチ保護を、GitHub の無料プランでも設定できます（以前の Private リポジトリでは設定できませんでした）。**設定済みです**（Ruleset `protect-main`: 削除の禁止、強制プッシュの禁止、直接のプッシュの禁止で PR 経由のみ。承認者の人数は 0 人）。GitHub Actions は、実行のたびに sf-tools の `main` を取得して、その中のコードを、秘密鍵を持つ環境で実行するため、`main` を誰が書き換えられるかが、最も重要です。変更は、引き続き、運用（mm / rr）を守ってください。設定は、リポジトリの **Settings → Rules** で確認・変更できます。

## 4. e2e: `sf-init.sh` の通し検証を自動で行う

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
| 4. Hello World のリリースと削除 | テスト用の Apex クラス（`SfToolsE2eHello` と、そのテスト）を、本物の流れで、リリースして削除する（下の「Hello World のリリースと削除」を参照）。`wf-metasync` は、その前に実行して、完了を待つ（組織からの取得と、組織へのデプロイを、同時に行わないため） |
| 5. 終了 | `sf` のエイリアスを実行前の状態に戻す。テスト用のリポジトリ・外部クライアントアプリなどは、**既定では削除せずに残す**（あとから GitHub の画面で、Actions の実行・PR・ファイルを見返せる。終了時に、リポジトリの URL を表示する）。`--cleanup` を付けると、終了時に削除する（リポジトリ、外部クライアントアプリ、Apex クラス、ローカルのフォルダ） |

**Hello World のリリースと削除:** sf-tools の本来の機能（PR → 検証 → マージ → リリース、削除用の PR）を通しで確認します。

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

`--interrupt` を付けると、`sf-init` を、わざと途中（Phase 8 の初回コミットの push）で失敗させ、失敗の画面が案内する「続きをやる」で再開してから、いつもの確認を行います（中断→再開が、実環境で正しく動くことの確認です。`--resume` とは同時に指定できません）。

`--resume` では、前掃除・`sf-init`・`wf-metasync` を行いません。ジョブ名は、毎回、時刻付きの別の名前（`e2e-hello-時刻`）になるので、同じリポジトリで、何度でも実行できます。前回の失敗で、Hello World の Apex クラスが組織に残っていたら、最初に削除します（名前が完全に一致するものだけ）。前回残したリポジトリがない場合は、エラーになります（通常の実行をしてください）。

**シナリオを 1 つずつ動かす（`scenario.sh`）:** `run.sh` が残したテスト用リポジトリに対して、確かめたいことだけを、短く動かします。`bash tests/e2e/scenario.sh --list` で一覧を見て、`bash tests/e2e/scenario.sh log-secrets` のように名前で選びます（名前なしは、何も実行しません）。実行の前後で、`main` の SHA・ブランチ・PR の数を比べ、変わっていたら、後続を実行しません。現在あるのは、`log-secrets`（直近の Actions のログと PR のコメントに、PAT・Slack の Token・認証 URL・秘密鍵が出ていないこと。読み取りのみ）、`validate-fail`（壊れた Apex の PR で `wf-validate` が失敗してコメントが付き、直すと成功すること。PR は、マージせずに閉じます）、`dist-main`（配布版 = `SF_TOOLS_BRANCH` 未設定で、sf-tools の `main` が使われること。`main` と `development` の配布物に差がない rr の直後だけ実行できます）、`metasync-diff`（組織にだけ作った Apex が、`wf-metasync` で `main` に反映されること。組織と `main` は、実行前の状態に戻します）、`propagate-fail`（`main` と `staging` に、同じファイルの違う内容を入れて `wf-propagate` を動かすと、コンフリクトで失敗し、Slack に通知され、`staging` は変わらないこと。ファイルは、終了時に削除します）、`restart-org`（`sf-restart.sh` で、ジョブのクローンの接続先を staging の組織に切り替え、`sf-dryrun.sh` が新しい組織を使うこと。終了時に、元の組織へ戻します）、`update-secret`（`sf-update-secret.sh` で、秘密鍵を、同じ鍵で上書きします。Secret の更新日時が進み、ほかの Secret は変わらず、誤った鍵のパスは断られることを確かめます。値は変わりません）、`cross-os`（リポジトリを GitHub から clone して、OS 混在の問題がないことを確かめます: 記録されたテキストファイルに CRLF がない・`sf-hook.sh` で入れたフックが `~/sf-tools/hooks/` と同じ内容で実行できる・`sf-sync-wf.sh --check` が成功する。読み取りのみで、一時フォルダの中だけを使います。リポジトリを作った OS とは別の OS で動かすと、OS 混在の確認になります。別の OS が作ったリポジトリは、`--repo force-e2e-日時` で指定します。GitHub Actions では、macOS が、Windows の作ったリポジトリに対して動かします）、`sync-wf`（管理者用のクローンの中だけで、ワークフローをわざと書き換え、`sf-sync-wf.sh` が見つけて雛形に戻すこと、`--remove` が、雛形にあるファイルは断り、不要なファイルだけ消すことを確かめます。コミット・push はしません）、`manual-delete`（テスト用リポジトリの Secret・Variable を手で削除 → `sf-init.sh --status` が見つけ、直し方を示す → 元に戻す。書き込みがあるため、開始の前に、書き込む内容が表示されます。終了時に、必ず元に戻します）です。「実行できない」（検査できるログがない、など）は、成功には数えません。

```bash
bash tests/e2e/cleanup.sh          # 削除対象の一覧を表示するだけ（何も削除しない）
bash tests/e2e/cleanup.sh --yes    # 一覧を見せたうえで、delete と入力すると削除する
```

**途中で止まったとき（ウィンドウが閉じた、など）:** テスト用のリポジトリやアプリ、認証 URL を含む一時フォルダ（`/tmp/e2e-run.*`）が、残ることがあります。次の実行の最初に、自動で掃除されます。すぐに片付ける場合は、`cleanup.sh --yes` を実行してください。ただし、**30 分以内に作られた一時フォルダは、別の実行の途中かもしれないため、掃除の対象外**です（認証 URL が入っているので、気になる場合は、手動で削除してください）。

**一覧を取得できなかったとき:** 削除の前に、テスト用のものの一覧を取得します。取得に失敗した場合は、数回やり直し、それでも取れなければ「対象なし」とは表示せず、エラーとして終わります（削除し損ねたのに「成功」と報告しないためです）。エラーになったときは、時間をおいて `cleanup.sh` を実行してください。

**認証 URL について:** 新しい `sf` は、`sf org display --verbose` で認証 URL を隠します。`bootstrap.sh` は、`sf org auth show-sfdx-auth-url` で取得し、形式が正しくない値は保存しません。

**安全のために:** 削除できるのは、`force-e2e-YYYYMMDD-HHMMSS` のようなテスト用の名前のものだけです。`SF_TOOLS`（元からあるアプリ）や、ふだん使っているリポジトリは、削除の対象になりません。オーナーも、鍵一式で指定したものだけです。GitHub Actions 上では、専用のワークフロー（`e2e.yml`）以外からは動きません。

**できないこと:** Token の作成と、テスト用組織への最初のログインは自動化できません（最初の 1 回だけ手動です）。また、`sf-init.sh` の質問の順番を変えたときは、`tests/e2e/lib.sh` の入力の台本（`e2e_make_input`）も直す必要があります（直し忘れは、通常のテストで検知されます）。
