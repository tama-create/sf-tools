# JWT 認証方式 実装仕様書

> **本ドキュメントの範囲:** JWT 認証への移行設計・仕様・実装方針。実装の詳細（コマンド引数等）はコードを正とします。
>
> **補足（sf-init Phase 10）:** Salesforce 側のアプリは「接続アプリケーション（Connected App）」と「外部クライアントアプリケーション（External Client App）」のいずれかを選択できます。本書は Connected App 前提で記述していますが、外部クライアントアプリでも同様の JWT Bearer Flow で動作します。
>
> **外部クライアントアプリ（External Client App）を選んだ場合は自動作成です。** Step 2 の手動案内は出ず、Step 4 の組織ごとの設定で、`sf org login web`（ブラウザでログイン）→ 接続ユーザー名とプロファイル名（表示名）の取得 → メタデータ（5 ファイル）の `sf project deploy` でアプリ作成（証明書の登録、JWT Bearer、フルアクセス + refresh_token、管理者が承認したユーザーは事前承認済み）→ `sf project retrieve` でコンシューマー鍵を自動取得 → JWT 接続テスト（反映待ちのためリトライ）→ Secrets / Variables を登録、までを `sf-init` が行います（コンシューマーキー・ユーザー名の手入力は不要です）。ログイン用の一時エイリアスは `sf-tools-PROD` / `sf-tools-STG` / `sf-tools-DEV` で、ユーザーが運用中のエイリアスと重ならない名前にしています。`sf` は npm 版が前提のため、ログイン（`sf org login web`）・接続情報の取得（`sf org display`）・JWT 接続テストの成否は、すべて `sf` の終了コードで判定します（0 以外なら中断します。出力の文言では判定しません）。**JWT 接続テストは、一時的なホームフォルダの中で実行します**（`run_isolated_home`）。`sf` の認証はユーザー名単位のため、そのまま実行すると、エイリアスが増える上に、同じユーザーの既存の認証が JWT の認証に置き換わってしまうからです。このため、`sf` の接続テストの `--alias`（`prod` / `staging` / `develop`）は、一時フォルダの中だけで有効で、ユーザーの `sf` には残りません（`sf-update-secret.sh` の接続テストも同様です）。実装は `phases/init/init-common.sh` の `register_jwt_secret_eca` / `generate_eca_metadata` を参照してください。

---

## 1. 目的・背景

### 1.1 現状（sfdxAuthUrl 方式）の課題

現行の認証方式は `sf org login web`（ブラウザ認証）で取得した OAuth リフレッシュトークンを `sfdxAuthUrl` として GitHub Secrets に登録している。

| 課題 | 内容 |
|---|---|
| トークン失効 | リフレッシュトークンには有効期限があり、期限切れ時に手動再登録が必要 |
| 再登録の手間 | 組織ごとにブラウザログインが必要 |
| セキュリティ | リフレッシュトークンは汎用的な認証情報であり、漏洩リスクがある |

### 1.2 JWT 方式のメリット

| 項目 | 内容 |
|---|---|
| 有効期限なし | 秘密鍵は期限がないため再登録不要 |
| ヘッドレス認証 | ブラウザ不要で CI/CD に最適 |
| 最小権限 | Connected App で権限を明示的に制限可能 |
| 業界標準 | OAuth 2.0 JWT Bearer Flow（RFC 7523） |

### 1.3 移行方針

- **CI/CD（GitHub Actions）**: sfdxAuthUrl → JWT に完全移行
- **ローカル環境（sf-start.sh）**: 変更なし（引き続き `sf org login web` を使用）
- **既存プロジェクトの移行スクリプト**: 作成しない（新規セットアップから JWT を使用）

---

## 2. GitHub Secrets の設計

### 2.1 Secrets 一覧

| Secret 名 | 共通/組織別 | 内容 |
|---|---|---|
| `SF_PRIVATE_KEY` | **プロジェクト共通（1つ）** | 秘密鍵（PEM 形式）。全組織の Connected App に同一の公開鍵証明書を登録するため共通 |
| `SF_CONSUMER_KEY_PROD` | 組織別 | 本番組織の Connected App コンシューマーキー |
| `SF_CONSUMER_KEY_STG` | 組織別 | ステージング組織の Connected App コンシューマーキー |
| `SF_CONSUMER_KEY_DEV` | 組織別 | 開発組織の Connected App コンシューマーキー |
| `SF_USERNAME_PROD` | 組織別 | 本番組織の接続ユーザー名 |
| `SF_USERNAME_STG` | 組織別 | ステージング組織の接続ユーザー名 |
| `SF_USERNAME_DEV` | 組織別 | 開発組織の接続ユーザー名 |
| `SF_INSTANCE_URL_PROD` | 組織別 | `https://login.salesforce.com` or `https://test.salesforce.com` |
| `SF_INSTANCE_URL_STG` | 組織別 | 同上 |
| `SF_INSTANCE_URL_DEV` | 組織別 | 同上 |

> 合計: 1 + 3 + 3 + 3 = **10 secrets**（現行 3 から変更）

### 2.2 SF_CONSUMER_KEY が組織ごとに異なる理由

Connected App は各 Salesforce 組織に個別に作成するため、コンシューマーキーは組織ごとに固有の値となる。
ただし **証明書（公開鍵）は共通**なので、各組織の Connected App に同一の `server.crt` を登録することで、秘密鍵 1 つで全組織に認証できる。

### 2.3 SF_INSTANCE_URL の値

| 組織種別 | 値 |
|---|---|
| 本番組織 / Developer Edition | `https://login.salesforce.com` |
| Sandbox | `https://test.salesforce.com` |

sf-init の Sandbox 確認プロンプト（Y/N）で自動設定する。

---

## 3. 証明書の管理

### 3.1 生成場所

```
~/.sf-jwt/<REPO_NAME>/
  server.key   ← 秘密鍵（GitHub Secrets: SF_PRIVATE_KEY に登録）
  server.crt   ← 公開鍵証明書（各組織の Connected App にアップロード）
```

- 秘密鍵はプロジェクトリポジトリには含めない
- `~/.sf-jwt/` は gitignore 対象外のホームディレクトリに保管
- 各組織の Connected App に同一の `server.crt` を登録する

### 3.2 生成コマンド（openssl）

sf-init 内で自動実行する。

```bash
openssl genrsa -out server.key 2048
openssl req -new -x509 -days 3650 \
    -key server.key \
    -out server.crt \
    -subj "/CN=sf-jwt-${REPO_NAME}/O=sf-cicd"
```

有効期限は 10 年（3650 日）。

---

## 4. sf-init Phase 10 の処理フロー

### 4.1 フロー概要

```
[Step 1] 証明書の生成（共通・1回のみ）
  ├─ ~/.sf-jwt/<REPO_NAME>/ を作成
  ├─ openssl で server.key / server.crt を生成
  └─ server.crt の内容を表示（Connected App に貼り付け用）

[Step 2] Connected App 設定案内（共通・1回）
  ├─ Salesforce 管理画面での操作手順を表示
  │    1. 設定 → アプリケーション → 接続アプリケーションを作成
  │    2. OAuth 設定を有効化
  │    3. 「デジタル署名を使用」→ server.crt をアップロード
  │    4. 適切なプロファイル/権限セットに接続ユーザーを追加
  │    5. 「コンシューマーキーとシークレット」でキーをコピー
  └─ press_enter「設定が完了したら Enter を押してください」

[Step 3] SF_PRIVATE_KEY を GitHub Secrets に登録（共通・1回）
  └─ gh secret set SF_PRIVATE_KEY（server.key の内容）

[Step 4] 組織ごとの設定（BRANCH_COUNT 回繰り返し）
  ├─ 「Sandbox ですか？ [Y/N]」→ SF_INSTANCE_URL を決定
  ├─ コンシューマーキーを入力（read_or_quit）
  ├─ 接続ユーザー名を入力（read_or_quit）
  ├─ JWT 接続テスト
  │    sf org login jwt \
  │      --client-id    <CONSUMER_KEY> \
  │      --jwt-key-file ~/.sf-jwt/<REPO>/server.key \
  │      --username     <USERNAME> \
  │      --instance-url <INSTANCE_URL> \
  │      --alias        <prod|staging|develop>
  │    → 失敗時: die「認証テストに失敗しました。Connected App の設定を確認してください。」
  └─ gh secret set SF_CONSUMER_KEY_xxx / SF_USERNAME_xxx / SF_INSTANCE_URL_xxx
```

### 4.2 再開（--resume）時の考慮

Phase 10 は Step 3（SF_PRIVATE_KEY 登録）まで完了していれば、`--resume 10` で Step 4 から再開できるよう設計する。

---

## 5. GitHub Actions の変更

### 5.1 セルフコンテインド WF（force-XXXX 側）

`wf-validate.yml` / `wf-release.yml` 等は CI/CD ロジックを完全内包（reusable WF パターンは廃止済み）。
認証ステップは JWT Bearer Flow を使用する。

```yaml
# 認証ステップ（実装済み）
- name: Salesforce 組織にログイン
  run: |
    echo "${{ secrets.SF_PRIVATE_KEY }}" > /tmp/server.key
    sf org login jwt \
      --client-id    "$SF_CONSUMER_KEY" \
      --jwt-key-file /tmp/server.key \
      --username     "$SF_USERNAME" \
      --instance-url "$SF_INSTANCE_URL" \
      --set-default \
      --alias ci-org
    rm -f /tmp/server.key
```

`sf-tools/templates/.github/workflows/` が正本。変更時は `sf-sync-wf.sh`（未実装）で各プロジェクトへ配布する。

---

## 6. sf-update-secret.sh の全面改修

### 6.1 処理フロー

```
選択メニュー:
  1. 秘密鍵を更新（SF_PRIVATE_KEY）
     → ファイルパスを入力 → JWT 接続テスト → Secret 登録
  2. コンシューマーキーを更新（SF_CONSUMER_KEY_xxx）
     → 組織を選択 → テキスト入力 → JWT 接続テスト → Secret 登録
  3. ユーザー名を更新（SF_USERNAME_xxx）
     → 組織を選択 → テキスト入力 → JWT 接続テスト → Secret 登録
  4. すべて更新
     → 上記を順番に実行
```

### 6.2 JWT 接続テスト（更新前に必ず実施）

```bash
sf org login jwt \
  --client-id    <CONSUMER_KEY> \
  --jwt-key-file <KEY_FILE> \
  --username     <USERNAME> \
  --instance-url <INSTANCE_URL> \
  --alias        <alias>
```

テスト失敗時は Secret を更新せず die で終了する。

---

## 7. 変更ファイル一覧（実装済み）

| ファイル | 変更種別 | 内容 |
|---|---|---|
| `phases/init/06_sf_auth.sh` | 全面書き換え | JWT フローに変更 |
| `phases/init/init-common.sh` | 関数差し替え | `register_sf_secret` 削除・`register_jwt_secret` 追加 |
| `bin/sf-update-secret.sh` | 全面書き換え | JWT Secrets 対応 |
| `templates/.github/workflows/wf-validate.yml` | 認証ステップ変更・自己完結化 | sfdxAuthUrl → JWT、reusable WF パターン廃止 |
| `templates/.github/workflows/wf-release.yml` | 同上 | 同上 |
| `templates/.github/workflows/wf-metasync.yml` | 同上 | 同上 |
| `templates/.github/workflows/wf-propagate.yml` | 自己完結化 | reusable WF パターン廃止 |
| `templates/.github/workflows/wf-sequence.yml` | 自己完結化 | 同上 |

> `sf-tools/.github/workflows/wf-*-reusable.yml` は全削除済み（セルフコンテインド WF への移行完了）。

---

## 8. ローカル環境への影響

**変更なし。**
`sf-start.sh` のローカルログイン（`sf org login web`）はそのまま維持する。
JWT 認証は GitHub Actions（CI/CD）側のみで使用する。
