# JWT 認証方式 実装仕様書

> **本ドキュメントの範囲:** JWT 認証への移行設計・仕様・実装方針。実装の詳細（コマンド引数等）はコードを正とします。
>
> **補足（sf-init Phase 10）:** Salesforce 側のアプリは、**既定が「外部クライアントアプリケーション（External Client App。以下 ECA）」で、自動で作成します**。従来の「接続アプリケーション（Connected App）」（手動で作成。今後廃止予定）は、`sf-init.sh --legacy-connected-app`（環境変数 `SF_INIT_LEGACY_CONNECTED_APP=1`）を指定したときだけ使います（利用者には選ばせません。4.1 の Step 1.5）。どちらも同じ JWT Bearer Flow で動作します。
>
> **ECA（既定）は自動作成です。** Step 2 の手動案内は出ず、Step 4 の組織ごとの設定で、ログイン先（URL）の選択 → `sf org login web`（ブラウザでログイン）→ 接続ユーザー名の取得 → 組織の種類の読み取りと「本番は main のみ」の確認（`org_guard`）→ プロファイル名（表示名）の取得 → メタデータ（5 ファイル）の `sf project deploy` でアプリ作成（証明書の登録、JWT Bearer、フルアクセス + refresh_token、管理者が承認したユーザーは事前承認済み）→ `sf project retrieve` でコンシューマー鍵を自動取得 → JWT 接続テスト（反映待ちのためリトライ）→ Secrets / Variables を登録、までを `sf-init` が行います（コンシューマーキー・ユーザー名の手入力は不要です。詳細は 4.2）。ログイン用の一時エイリアスは `sf-tools-PROD` / `sf-tools-STG` / `sf-tools-DEV` で、ユーザーが運用中のエイリアスと重ならない名前にしています。`sf` は npm 版が前提のため、ログイン（`sf org login web`）・接続情報の取得（`sf org display`）・プロファイル名の取得（`sf data query`）・deploy・retrieve・JWT 接続テストの成否は、すべて `sf` の終了コードで判定します（出力の文言では判定しません）。JWT 接続テスト以外は、0 以外なら中断します。JWT 接続テストは、リトライしても成功しなければ、「テストをスキップして登録だけ行う」かを確認します（N / q は中断）。**JWT 接続テストは、一時的なホームフォルダの中で実行します**（`run_isolated_home`）。`sf` の認証はユーザー名単位のため、そのまま実行すると、エイリアスが増える上に、同じユーザーの既存の認証が JWT の認証に置き換わってしまうからです。このため、`sf` の接続テストの `--alias`（`prod` / `staging` / `develop`）は、一時フォルダの中だけで有効で、ユーザーの `sf` には残りません（従来の接続アプリ・`sf-update-secret.sh` の接続テストも同様です。どちらも `lib/org.sh` の `org_jwt_test`）。実装は `phases/init/10_sf_auth.sh`、`phases/init/init-common.sh` の `register_jwt_secret_eca` / `generate_eca_metadata` / `register_jwt_secret`、`lib/org.sh` を参照してください。

---

## 1. 目的・背景

### 1.1 移行前（sfdxAuthUrl 方式）の課題

移行前の認証方式は `sf org login web`（ブラウザ認証）で取得した OAuth リフレッシュトークンを `sfdxAuthUrl` として GitHub Secrets に登録していた（移行は完了済み。いまの CI/CD は JWT のみ）。

| 課題 | 内容 |
|---|---|
| トークン失効 | リフレッシュトークンには有効期限があり、期限切れ時に手動再登録が必要 |
| 再登録の手間 | 組織ごとにブラウザログインが必要 |
| セキュリティ | リフレッシュトークンは汎用的な認証情報であり、漏洩リスクがある |

### 1.2 JWT 方式のメリット

| 項目 | 内容 |
|---|---|
| 有効期限なし | 秘密鍵そのものには期限がなく、トークンの再登録が不要（ただし、証明書は 10 年。3.2） |
| ヘッドレス認証 | ブラウザ不要で CI/CD に最適 |
| 利用者の限定 | アプリのポリシーで、使えるユーザーを、管理者が承認したプロファイルに限定できる（sf-init の設定は「事前承認済み」+ 接続ユーザーのプロファイル。スコープはフルアクセス + refresh_token） |
| 業界標準 | OAuth 2.0 JWT Bearer Flow（RFC 7523） |

### 1.3 移行方針

- **CI/CD（GitHub Actions）**: sfdxAuthUrl → JWT に完全移行
- **ローカル環境（sf-start.sh）**: 変更なし（引き続き `sf org login web` を使用）
- **既存プロジェクトの移行スクリプト**: 作成しない（新規セットアップから JWT を使用）

---

## 2. GitHub Secrets / Variables の設計

### 2.1 Secrets / Variables 一覧（JWT 認証）

機密の値（秘密鍵・コンシューマー鍵）だけを Secret にし、ユーザー名・ログイン先・組織の情報は Variable（平文）にする。
接尾辞は段階（ブランチ）で決まる: `PROD` = main / `STG` = staging / `DEV` = develop（組織の種類とは結びつけない。本番組織は main のみ: 4.3）。
STG は段階が 2 つ以上、DEV は 3 つのとき（または `--add-tier` で段階を足したとき）だけ登録する。

| 名前 | 種別 | 共通/組織別 | 内容 | 登録元 |
|---|---|---|---|---|
| `SF_PRIVATE_KEY` | Secret | **プロジェクト共通（1つ）** | 秘密鍵 `server.key`（PEM）から CR を除き、`base64_oneline` で 1 行の Base64 にした値。全組織のアプリに同一の証明書を登録するため共通 | sf-init Phase 10（Step 3。毎回上書き）/ `sf-update-secret.sh` のメニュー 1・4 |
| `SF_CONSUMER_KEY_PROD` / `_STG` / `_DEV` | Secret | 組織別 | その組織のアプリ（ECA / 接続アプリ）のコンシューマー鍵 | Phase 10 / `sf-init.sh --add-tier`（`_STG`・`_DEV`）/ `sf-init.sh --reconnect` / `sf-update-secret.sh` のメニュー 2・4 |
| `SF_USERNAME_PROD` / `_STG` / `_DEV` | Variable | 組織別 | 接続ユーザー名 | Phase 10 / `--add-tier` / `--reconnect` / `sf-update-secret.sh` のメニュー 3・4 |
| `SF_INSTANCE_URL_PROD` / `_STG` / `_DEV` | Variable | 組織別 | ログイン先の URL（`sf org login jwt --instance-url` に渡す。2.3） | Phase 10 / `--add-tier` / `--reconnect` / `sf-update-secret.sh` のメニュー 4 のみ |
| `SF_ORG_ID_*` / `SF_ORG_NAME_*` / `SF_ORG_KIND_*` / `SF_ORG_CHECKED_*` | Variable | 組織別 | 組織 ID・組織名・種類（production / sandbox / developer / trial / unknown）・確認日時。`sf-init.sh --status` の表示と、`--reconnect` の「古い組織」の判定に使う（ワークフローは使わない） | `org_save`（`lib/org.sh`）。Phase 10 / `--add-tier` / `--reconnect` / `sf-update-secret.sh` のメニュー 2〜4。組織の情報を読み取れたときだけ（保存の失敗は WARNING で続行） |

> JWT のログインに使うのは、Secret 4 つ（`SF_PRIVATE_KEY` + `SF_CONSUMER_KEY_*` × 3）と Variable 6 つ（`SF_USERNAME_*` × 3 + `SF_INSTANCE_URL_*` × 3）。段階が main だけなら、Secret 2 つ・Variable 2 つ。

### 2.2 JWT 以外の Secrets / Variables（参考）

ワークフローが使う、JWT 以外の値。詳細は各 Phase と `templates/.github/workflows/wf-*.yml` の冒頭コメント。

| 名前 | 種別 | 用途 | 登録元 |
|---|---|---|---|
| `PAT_TOKEN` | Secret | wf-metasync・wf-propagate の checkout / push | sf-init Phase 6 |
| `SLACK_BOT_TOKEN` | Secret | Slack への通知（wf-release・wf-propagate・wf-sequence） | sf-init Phase 7 |
| `SLACK_CHANNEL_ID` | Variable | 通知先の Slack チャンネル ID | sf-init Phase 7 |
| `SF_TOOLS_BRANCH` | Variable | ワークフローが clone する sf-tools のブランチ（未設定なら `main`） | sf-init Phase 9（開発版 = `development` のときだけ） |

### 2.3 SF_CONSUMER_KEY が組織ごとに異なる理由

アプリ（ECA / 接続アプリ）は各 Salesforce 組織に個別に作成するため、コンシューマー鍵は組織ごとに固有の値となる。
ただし **証明書（公開鍵）は共通**なので、各組織のアプリに同一の `server.crt` を登録することで、秘密鍵 1 つで全組織に認証できる。

### 2.4 SF_INSTANCE_URL の値

ログイン先は、組織の種類ではなく **URL で選ぶ**（`org_choose_login_url`。`lib/org.sh`）。3 択で、Enter は [2]（Sandbox。本番に影響しない安全な既定）。

| 選択肢 | 値 | 目安 |
|---|---|---|
| [1] | `https://login.salesforce.com` | 本番・Developer Edition・Trial など（main 以外の段階では、本番は不可） |
| [2]（Enter） | `https://test.salesforce.com` | Sandbox |
| [3] | 組織の URL（My Domain。例: `https://会社名.my.salesforce.com`） | 入力した URL は、https で、ホストが `salesforce.com` / `force.com` のサブドメインであること（`org_validate_url`）。末尾の `/` は除く。正しい形式になるまで再入力（q で中断） |

環境変数 `SF_INIT_LOGIN_URL_<PROD|STG|DEV>`（`login` / `test` / URL）があれば、質問しない（URL が正しくなければ中断。自動実行・テスト用）。`sf-update-secret.sh` も同じ選び方をする。

---

## 3. 証明書の管理

### 3.1 生成場所

```
~/.sf-jwt/<REPO_NAME>/        ← フォルダの権限 700
  server.key   ← 秘密鍵（RSA 2048 ビット・PKCS#1。権限 600。Base64 にして Secret SF_PRIVATE_KEY に登録）
  server.crt   ← 公開鍵証明書（ECA: メタデータに入れて deploy で登録 / 接続アプリ: 利用者が各組織にアップロード）
```

- 秘密鍵はプロジェクトリポジトリには含めない（リポジトリの外、sf-init を実行した管理者の PC のホームに保管する）
- 各組織のアプリに同一の `server.crt` を登録する
- `--add-tier` / `--reconnect` / `sf-update-secret.sh`（メニュー 2〜4 の既定）も、このフォルダの鍵・証明書を使う（`--add-tier` / `--reconnect` は、なければ中断）

### 3.2 生成コマンド（openssl）

sf-init Phase 10 の Step 1 で自動実行する（`generate_jwt_cert`。`phases/init/init-common.sh`）。

```bash
openssl genrsa -out server.key.tmp 2048
openssl rsa -traditional -in server.key.tmp -out server.key   # OpenSSL 3.x の PKCS#8 を PKCS#1 にする（失敗したら 1.x とみなし、tmp をそのまま使う）
openssl req -new -x509 -days 3650 \
    -key server.key \
    -out server.crt \
    -subj "/CN=sf-jwt-${REPO_NAME}"     # Git Bash では "//CN=sf-jwt-${REPO_NAME}"
```

- 有効期限は 10 年（3650 日）。自己署名
- 発行先（subject）は `CN=sf-jwt-<REPO_NAME>` だけ。Git Bash は `-subj` の先頭の `/` を Windows のパスと取り違えるため `//` で書き、それ以外（macOS・Linux・WSL）は `/` で書く（`_jwt_cert_subject_arg`）。`//` を Git Bash 以外に渡すと、openssl は発行先が空の証明書を終了コード 0 で作り、Salesforce が「証明書ではありません」と拒否する
- そのため、生成後に発行先が空でないことを確かめる（空なら中断）。以前の sf-tools が作った発行先が空の証明書は、再利用時に、秘密鍵はそのままで証明書だけを作り直す（`ensure_jwt_cert_subject`。`SF_PRIVATE_KEY` はずれない）
- 鍵・証明書が両方あるときは、再利用するかを `ask_yn` で聞く（Y: 再利用 / N: 両方を削除して作り直す（秘密鍵も変わる）/ q: 中断）。どちらかがないときは、両方を作る

---

## 4. sf-init Phase 10 の処理フロー

### 4.1 フロー概要

正本は `phases/init/10_sf_auth.sh` の冒頭コメント。

```
[Step 1] 証明書の用意（共通）
  ├─ 両方あるとき: ask_yn「既存の証明書を再利用しますか？」
  │    Y: 再利用（発行先が空なら証明書だけ作り直す）/ N: 削除して作り直す / q: 中断
  └─ どちらかがないとき: generate_jwt_cert で作る（3.2）

[Step 1.5] アプリの種類（APP_TYPE）を決める（利用者には聞かない）
  ├─ 状態ファイルに APP_TYPE があれば、それを使う（--legacy-connected-app の指定があり、1 以外なら中断）
  └─ なければ: --legacy-connected-app なら 1（接続アプリ）、それ以外は 2（ECA）。状態ファイルに追記

[Step 2] アプリの案内（共通・1回）
  ├─ APP_TYPE=1: 接続アプリの作成手順を表示して Enter を待つ（q は中断）
  │    STEP A: アプリケーションマネージャ → 新規接続アプリケーション（名前 SF_TOOLS）→ OAuth 設定の有効化
  │            （コールバック URL）→ スコープ（full / refresh_token, offline_access）→ デジタル署名に server.crt を
  │            アップロード → 保存 → コンシューマー鍵をコピー → 2〜10 分待つ
  │    STEP B: 接続アプリケーションを管理 → ポリシー「管理者が承認したユーザーは事前承認済み」→ 接続ユーザーのプロファイルを追加
  └─ APP_TYPE=2: 自動で作成する旨を表示するだけ

[Step 3] SF_PRIVATE_KEY を GitHub Secrets に登録（共通・毎回上書き）
  └─ tr -d '\r' < server.key | base64_oneline | gh secret set SF_PRIVATE_KEY（秘密鍵をログに残さないため run を使わない）

[Step 4] 組織ごとの設定（PROD は常に / STG は BRANCH_COUNT ≥ 2 / DEV は BRANCH_COUNT ≥ 3）
  ├─ 前回完了済みの段階はスキップ（4.4）
  ├─ APP_TYPE=2: register_jwt_secret_eca（4.2）
  └─ APP_TYPE=1: register_jwt_secret
       ├─ ログイン先（URL）を選ぶ（2.4）
       ├─ コンシューマー鍵・接続ユーザー名を入力（read_or_quit）
       ├─ JWT 接続テスト（org_jwt_test。一時的なホームの中で、ログインと組織の種類の読み取り）
       │    sf org login jwt --client-id <鍵> --jwt-key-file ~/.sf-jwt/<REPO>/server.key \
       │      --username <ユーザー名> --instance-url <URL> --alias <prod|staging|develop>
       │    → 失敗時: ask_yn「接続テストをスキップして GitHub Secrets への登録のみ行いますか？」（N / q は中断）
       ├─ 本番は main のみ（org_guard。4.3）。違反は中断
       └─ gh secret set SF_CONSUMER_KEY_xxx / gh variable set SF_USERNAME_xxx・SF_INSTANCE_URL_xxx / org_save
```

接続アプリ（APP_TYPE=1）の注意（`10_sf_auth.sh` の冒頭コメント）: 作成した接続アプリを「外部クライアントアプリへの移行」または「削除」しないこと（OAuth の内部状態が壊れ、`client_identifier_invalid` が出る。問題が起きたら、別名で新規作成する）。Developer Edition 組織では事前承認の反映が遅れる・失敗する場合がある。

### 4.2 外部クライアントアプリの自動作成（register_jwt_secret_eca）

正本は `phases/init/init-common.sh` の `register_jwt_secret_eca` / `generate_eca_metadata` の説明コメント。

1. ログイン先（URL）を選ぶ（2.4）
2. 一時エイリアス `sf-tools-<接尾辞>` を `sf alias unset` で外してから（前回の古い認証で「ログイン済み」と誤判定しないため）、`sf org login web --instance-url <URL> --alias sf-tools-<接尾辞>`（接続ユーザー = 管理者権限のユーザー。約 2 分で時間切れ。失敗・時間切れ・ブラウザを閉じたときは中断）
3. `sf org display --json` からユーザー名を取得 → 組織の種類を読み取り（`org_read_info`）、本番は main のみの確認（`org_guard`。**アプリを作る deploy の前**）→ `sf data query`（`SELECT Profile.Name FROM User WHERE Username=...`）で接続ユーザーのプロファイル名（表示名。言語依存。日本語の組織では「システム管理者」）を取得
4. `generate_eca_metadata` で、一時フォルダにメタデータ（ソース形式）と `sfdx-project.json`（`sourceApiVersion` 64.0）を生成し、`sf project deploy start --source-dir force-app` でアプリを作成する。アプリ名は `SF_TOOLS_<REPO_NAME の英数字以外を _>`（名前が決まっているため、やり直しても重複しない）
5. `sf project retrieve start --metadata ExtlClntAppGlobalOauthSettings:<アプリ名>_glbloauth` で、`<consumerKey>` を取り出す（値はログに出さない）。そのあと、一時フォルダを消し、一時エイリアスを `sf alias unset` で外す（`sf org logout` は、同じユーザー名の全エイリアスの認証を消すため使わない）
6. JWT 接続テスト（`run_isolated_home sf org login jwt ... --alias <prod|staging|develop>`）。作成直後は反映待ちで失敗するため、最大 `SF_INIT_JWT_RETRIES`（既定 20）回、`SF_INIT_JWT_INTERVAL`（既定 30）秒おきに試す（待つのは試行の間だけ。既定で最大 19 × 30 = 570 秒 = 約 10 分）。最後まで失敗したら、スキップして登録だけ行うかを `ask_yn`（N / q は中断。アプリは作成済みのまま残る）
7. `SF_CONSUMER_KEY_<接尾辞>`（Secret）/ `SF_USERNAME_<接尾辞>`・`SF_INSTANCE_URL_<接尾辞>`（Variable）を登録し、`org_save` で `SF_ORG_*_<接尾辞>`

手順 2 のログインのあと、手順 3〜5 のどこで失敗しても、一時エイリアスを外してから中断する（`_eca_abort`。トラップは使わない。Ctrl+C などのシグナルで止めたときは外さず、次回の手順 2 の最初に外す）。

メタデータ（5 ファイル。`force-app/main/default/` 配下）:

| フォルダ / ファイル | 種類 | 主な設定 |
|---|---|---|
| `externalClientApps/<名前>.eca-meta.xml` | ExternalClientApplication | 連絡先メール（接続ユーザー名）・`distributionState` Local |
| `extlClntAppGlobalOauthSets/<名前>_glbloauth.ecaGlblOauth-meta.xml` | ExtlClntAppGlobalOauthSettings | コールバック URL・**証明書**（`server.crt` の BEGIN/END 行を除いた本文）。`consumerKey` は出力項目のため書かない（deploy 後に retrieve で取得） |
| `extlClntAppOauthSettings/<名前>_oauth.ecaOauth-meta.xml` | ExtlClntAppOauthSettings | スコープ `Full, RefreshToken` |
| `extlClntAppOauthPolicies/<名前>_oauthPlcy.ecaOauthPlcy-meta.xml` | ExtlClntAppOauthConfigurablePolicies | `permittedUsersPolicyType` AdminApprovedPreAuthorized（管理者が承認したユーザーは事前承認済み）・事前承認するプロファイル（手順 3 のプロファイル名） |
| `extlClntAppPolicies/<名前>_plcy.ecaPlcy-meta.xml` | ExtlClntAppConfigurablePolicies | 有効化（`isEnabled`・`isOauthPluginEnabled`） |

### 4.3 本番は main のみ（org_guard）

段階と組織の種類は、基本的に独立している（ログイン先は URL で選ぶ）。ただし、**Salesforce の本番組織は main（`PROD`）にしかつなげない**（`org_guard`。`lib/org.sh`）。

- 組織の種類は、ログインした組織の `Organization`（`Id`・`Name`・`IsSandbox`・`OrganizationType`・`TrialExpirationDate`）を読み取って判定する（`org_read_info` / `org_jwt_test` → `org_kind`）。上から順に: 読み取れない → unknown / `IsSandbox` が true → sandbox / `OrganizationType` に Developer → developer / `TrialExpirationDate` あり → trial / `OrganizationType` が空 → unknown / それ以外 → production（推測しない）
- staging・develop に production または unknown をつなごうとしたら、登録する前に中断する。main は、unknown でも WARNING を出して続行する
- 確認のタイミング: ECA は deploy の前（誤って本番にアプリを作らないため）。接続アプリ・`sf-update-secret.sh` は JWT 接続テストのあと、登録の前（接続テストをスキップしたときは unknown として扱う）

### 4.4 再開（--resume）時の考慮

- Phase 10 を再実行する（中断後の「続きをやる」・`--resume N`）と、Step 1 から実行する（鍵・証明書の再利用の確認、Step 3 の `SF_PRIVATE_KEY` の上書きも、毎回行う）
- Step 4 は段階ごとに再開できる。段階が完了するたびに、進捗ファイル（`admin/.sf-init-XXXX.progress`）に `SF_INIT_DONE_TIER_<接尾辞>=1` を追記し、再実行では、その記録があり、かつ `gh secret list` に `SF_CONSUMER_KEY_<接尾辞>` がいまもあるときだけ、その段階をスキップする（ブラウザのログインをやり直さなくてよいように。一覧を取得できなければスキップしない）
- 記録とスキップは `SF_INIT_TIER_RESUME=1`（`sf-init.sh` が `--only` 以外のときに export する）のときだけ。`--only 10` では、記録も、スキップもしない
- Step 1 で N（鍵の作り直し）を選んだ実行では、スキップしない（`SF_PRIVATE_KEY` が新しい鍵に置き換わり、古い証明書が残る組織が JWT 接続できなくなるため）
- Phase 10 が成功すると、`sf-init.sh` が進捗ファイルを書き直すため、段階の記録は消える
- アプリの種類は、状態ファイルの `APP_TYPE` を再利用する（4.1 の Step 1.5）

### 4.5 段階の追加・接続先の付け替え（--add-tier / --reconnect）

セットアップ後に、1 つの段階だけを Phase 10 と同じ関数で設定する（force-* の中で実行する管理者向けのモード。管理者向けの警告・`check_gh_owner`・確認のあと）。どちらも、既定は `register_jwt_secret_eca`、`--legacy-connected-app`（`SF_INIT_LEGACY_CONNECTED_APP=1`）のときは `register_jwt_secret`。鍵・証明書は `~/.sf-jwt/<REPO_NAME>/` のものを使う（新しくは作らない）。

| モード | スクリプト | 登録するもの | 補足 |
|---|---|---|---|
| `sf-init.sh --add-tier staging\|develop` | `phases/init/add_tier.sh` | `*_STG` または `*_DEV` | 組織への接続を先に行い、そのあとブランチを作り、`branches.txt` の変更を PR にする。接続で中断したときは、ブランチ・`branches.txt` は変更しない（deploy 済みの ECA は組織に残る） |
| `sf-init.sh --reconnect main\|staging\|develop` | `phases/init/reconnect.sh` | その段階の `*_<接尾辞>` | いまの接続（Variables）を表示してから付け替える。以前の組織 ID と違う組織につないだときは、古い組織に残るアプリ（ECA `SF_TOOLS_<…>` / 手動の接続アプリ）と削除の場所を表示する（自動では削除しない）。登録は 1 つずつ行うため、途中で止まると新旧の値が混在する（もう一度 `--reconnect` でそろえる） |

鍵・ユーザー名だけの部分的な更新は `sf-update-secret.sh`（6）。

---

## 5. GitHub Actions の変更

### 5.1 セルフコンテインド WF（force-XXXX 側）

`wf-validate.yml` / `wf-release.yml` 等は CI/CD ロジックを完全内包（reusable WF パターンは廃止済み）。
認証ステップは JWT Bearer Flow を使用する（wf-validate の例）。

```yaml
# 認証ステップ（実装済み）
- name: Salesforce 組織にログイン
  run: |
    # 秘密鍵は、本人だけが読める権限で作り、ログインの成否にかかわらず（失敗しても）、必ず消す
    umask 077
    trap 'rm -f /tmp/server.key' EXIT
    echo "${{ secrets.SF_PRIVATE_KEY }}" | base64 -d > /tmp/server.key
    sf org login jwt \
      --client-id    "$SF_CONSUMER_KEY" \
      --jwt-key-file /tmp/server.key \
      --username     "$SF_USERNAME" \
      --instance-url "$SF_INSTANCE_URL" \
      --set-default \
      --alias ci-org
    rm -f /tmp/server.key
```

- `SF_PRIVATE_KEY` は 1 行の Base64（2.1）のため、`base64 -d` で PEM に戻す
- `--instance-url` には Variable `SF_INSTANCE_URL_*`（ログイン先。2.4）を渡す

| ワークフロー | ログインする組織 | エイリアス |
|---|---|---|
| `wf-validate.yml` | PR のマージ先で選ぶ: main → `*_PROD`、staging → `*_STG`、それ以外 → `*_DEV`（前のステップで `SF_CONSUMER_KEY`・`SF_USERNAME`・`SF_INSTANCE_URL` を `GITHUB_ENV` に書く） | `ci-org` |
| `wf-release.yml` | マージ先のブランチに対応する組織だけ（main → `*_PROD` / staging → `*_STG` / develop → `*_DEV`） | `prod` / `staging` / `develop` |
| `wf-metasync.yml` | main の組織（`*_PROD`）のみ | `prod` |
| `wf-propagate.yml` / `wf-sequence.yml` | Salesforce にはログインしない | — |

どれも `--set-default` で既定の組織にする。sf-tools は、公開リポジトリから Variable `SF_TOOLS_BRANCH` のブランチ（未設定なら `main`）を Token なしで clone する。

`sf-tools/templates/.github/workflows/` が正本。変更時は `sf-sync-wf.sh` で各プロジェクトへ反映する（管理者が手動で実行する）。

---

## 6. sf-update-secret.sh の全面改修

### 6.1 処理フロー

正本は `bin/sf-update-secret.sh` の冒頭コメント（`doc/dev-reference.md` 4.11）。force-* で実行する管理者向けのコマンド。

```
前処理: sf・gh・git・openssl の確認 → 管理者向けの警告と確認（GitHub Actions 上では省略）
        → origin からリポジトリ名 → check_gh_owner → check_sf_cli --cache

選択メニュー:
  1. 秘密鍵を更新（SF_PRIVATE_KEY）
     → ファイルパスを入力（常に入力。~ は展開）→ 確認（Y/N）→ Secret 登録（接続テストは行わない）
  2. コンシューマーキーを更新（SF_CONSUMER_KEY_xxx）
     → 組織を選択 → コンシューマー鍵を入力 → 接続ユーザー名（SF_USERNAME_xxx があれば使うかを確認）
     → ログイン先を選ぶ → JWT 接続テスト → Secret 登録
  3. ユーザー名を更新（SF_USERNAME_xxx）
     → 組織を選択 → コンシューマー鍵（接続テスト用。登録しない）・新しいユーザー名を入力
     → ログイン先を選ぶ → JWT 接続テスト → Variable 登録
  4. すべて更新
     → 確認（Y/N）で Y なら SF_PRIVATE_KEY を先に登録（接続テストより前）
     → 組織ごとに: コンシューマー鍵・ユーザー名を入力 → ログイン先を選ぶ → JWT 接続テスト
       → SF_CONSUMER_KEY_xxx（Secret）・SF_USERNAME_xxx・SF_INSTANCE_URL_xxx（Variable）を登録
```

- 組織の選択肢は `sf-tools/config/branches.txt` の有効な行数で決まる（1 行: PROD / 2 行: + STG / 3 行以上: + DEV。ファイルがなければ PROD のみ）
- 秘密鍵ファイルは、メニュー 2〜4 では `~/.sf-jwt/<リポジトリ名>/server.key` があればそれを使う（なければパスを入力）
- メニュー 2・3 で選んだログイン先は接続テストにだけ使い、`SF_INSTANCE_URL_xxx` は更新しない

### 6.2 JWT 接続テスト（更新前に必ず実施）

```bash
# org_jwt_test（lib/org.sh）が、run_isolated_home（一時的なホーム）の中で実行する
sf org login jwt \
  --client-id    <CONSUMER_KEY> \
  --jwt-key-file <KEY_FILE> \
  --username     <USERNAME> \
  --instance-url <INSTANCE_URL> \
  --alias        <prod|staging|develop>
# 続けて、同じ一時的なホームの中で、組織の種類（Organization）を読み取る
```

- テストに失敗したら、その組織の値を更新せず die で終了する（スキップの確認はない。それより前に登録した値（メニュー 4 の `SF_PRIVATE_KEY`・前の組織の値）は、そのまま残る）
- 成功したら、本番は main のみの確認（`org_guard`。4.3）をし、違反なら更新せずに中断する。続けて `org_save` で `SF_ORG_*_<接尾辞>` を保存してから、Secret / Variable を更新する

---

## 7. 変更ファイル一覧（実装済み）

| ファイル | 変更種別 | 内容 |
|---|---|---|
| `phases/init/10_sf_auth.sh`（旧 `06_sf_auth.sh`） | 全面書き換え | JWT フローに変更 |
| `phases/init/init-common.sh` | 関数差し替え | `register_sf_secret` 削除・`register_jwt_secret` 追加 |
| `bin/sf-update-secret.sh` | 全面書き換え | JWT Secrets 対応 |
| `templates/.github/workflows/wf-validate.yml` | 認証ステップ変更・自己完結化 | sfdxAuthUrl → JWT、reusable WF パターン廃止 |
| `templates/.github/workflows/wf-release.yml` | 同上 | 同上 |
| `templates/.github/workflows/wf-metasync.yml` | 同上 | 同上 |
| `templates/.github/workflows/wf-propagate.yml` | 自己完結化 | reusable WF パターン廃止 |
| `templates/.github/workflows/wf-sequence.yml` | 自己完結化 | 同上 |

> `sf-tools/.github/workflows/wf-*-reusable.yml` は全削除済み（セルフコンテインド WF への移行完了）。
>
> 移行のあとに加わった主なもの: `phases/init/init-common.sh` の `register_jwt_secret_eca` / `generate_eca_metadata`（ECA の自動作成。既定）・`generate_jwt_cert` / `ensure_jwt_cert_subject`（証明書の生成と発行先の確認）、`lib/org.sh`（ログイン先の選択・組織の種類・`org_guard`・`org_jwt_test`・`org_save`）、`phases/init/add_tier.sh`（`--add-tier`）・`phases/init/reconnect.sh`（`--reconnect`）。

---

## 8. ローカル環境への影響

**変更なし。**
`sf-start.sh` のローカルログイン（`sf org login web`）はそのまま維持する。
JWT でのログインは GitHub Actions（CI/CD）側のみで使用する。

- `sf-start.sh`: 未接続（または `FORCE_RELOGIN=1`）のとき、利用者が入力したエイリアスで、`sf org logout --target-org <エイリアス>`（失敗は無視）→ `sf org login web --set-default --alias <エイリアス> --instance-url <ログイン先>`。ログイン先は 2.4 と同じ 3 択（環境変数 `SF_INIT_LOGIN_URL_START`）。JWT の鍵・Secrets は使わない
- 管理者の PC で JWT を使うのは、接続テストだけ（Phase 10・`--add-tier`・`--reconnect`・`sf-update-secret.sh`）。一時的なホームの中で実行するため、利用者の `sf` の認証・エイリアスは変わらない
- ECA の自動作成のための `sf org login web` は、一時エイリアス `sf-tools-<接尾辞>` で行い、終わったら外す（4.2）
