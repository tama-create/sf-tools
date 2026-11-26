# 一方通行のリリース（develop → staging → main） 設計書

> **ステータス: 設計は Codex のレビュー 4 回で承認（2026-11-26。9 章）。実装済み（2026-11-26。development。rr 待ち）。** 実装の正本は、`bin/sf-promote-check.sh`・`lib/manifest.sh`・`bin/sf-next.sh`・雛形の `wf-sequence.yml`・`wf-validate.yml`・`wf-release.yml` の冒頭コメント。e2e は `tests/e2e/run.sh`（印・伝播しないこと・削除も段階順）と `tests/e2e/scenario.sh one-way`（R1・R2・最後の守り）。既存の force-* への反映（`sf-sync-wf.sh` と `--remove wf-propagate.yml`）は、管理者が行う（5 章）。
> 目的: 開発物は一方通行で、開発環境 → develop → staging → main と、**同じものを**順に上げる。この大原則（TAMAさん・2026-11-26）を、警告ではなく、**仕組みで破れないようにする**。
> きっかけ: force-test-win の備品アプリ（JOB-EQL-1）で、develop・staging に段階を重ね、main を止めた。main には最後の段階の一覧だけが 1 回で出て、段階 1 のオブジェクトの本体が抜け、64 件の失敗になった（PR #18。本番は無変更）。順序の確認（wf-sequence）は警告だけで、tamashimon-org は無料プラン・非公開のため Ruleset も効かず、検証の途中でマージされた。
> 守る相手: 開発者の**誤操作**（CLAUDE.md 1.1）。書き込みの権限を持つ人の悪意までは防がない（権限のある人は、ワークフローの雛形そのものも書き換えられるため）。ただし、手で付けた印などの、うっかりの抜け道はふさぐ（3.1）。

## 1. 原則

1. 開発物は、開発環境 → develop → staging → main の順に、**同じコミットのまま**上げる
2. develop で障害が出たら、開発環境と develop を行き来して直す（develop には何度出してもよい）。直してから staging へ
3. staging で問題が出たら、staging では直さない。開発環境で直し、develop → staging とやり直す
4. 1 周（main まで）が終わる前に、同じブランチから develop に出し直すときは、あとの一覧が、前の一覧の項目を全部含む（消すものは remove-target.txt へ移す）。上の段階には、最後の一覧だけが 1 回で出るため
5. 禁止: develop に出したあとに改変して staging に出す・前の段階を飛ばす・段階を重ねて main だけまとめて出す・main の変更を下の段階のブランチへ直接流す

## 2. 現状と問題（2026-11-26 にコードで確認）

| 場所 | 今の動き | 問題 |
|---|---|---|
| `wf-sequence.yml`（staging・main への PR） | PR の先頭のコミットが、前の段階のブランチに入っているか（`git merge-base --is-ancestor`）。入っていなければ**警告だけ**（緊急の Hotfix を妨げないため）。環境ブランチからの PR は失敗。`branches.txt` がなければ素通り | 順序外でもマージできる。ブランチに入ったことは見るが、**組織へのリリースが成功したか**は見ない |
| `wf-validate.yml` | 検証の dry-run だけ | 積み重ねの抜け（原則 4）を見ない |
| `wf-release.yml` | マージされたら、そのまま組織へ出す。手動の実行（workflow_dispatch）もある | 順序外の PR がマージされても、組織へ出してしまう（Ruleset が効かない組織では、最後の守りがない） |
| `sf-next.sh` | マージ済みの段階の次を勧める（`merged_stale`: マージのあとの変更があれば、その段階へ出し直しを勧める） | 組織へのリリースの成否は見ない |
| `wf-propagate.yml`・`sf-metasync.sh` の手順 12 | main の変更を、staging・develop のブランチへ、PR も検証も通さずに直接マージする（PAT で Ruleset を迂回） | **下りの流れ**（原則 5 に反する）。ブランチには入るが、その組織には出していないものができる |
| Ruleset | sf-init の Phase 9 が作る（必須チェック） | 無料プランの非公開リポジトリでは使えない（`Upgrade to GitHub Pro or make this repository public`。2026-11-26 に tamashimon-org で確認） |

## 3. 方針

### 3.1 「どの段階に出したか」を、コミットに記録する（リリースの印）

- wf-release は、組織へのリリースが**成功したとき**、PR の先頭のコミット H（`pull_request.head.sha`）に、コミットの状態（commit status）を付ける
  - context: `sf-tools/released-develop`・`sf-tools/released-staging`・`sf-tools/released-main`、state: `success`
  - target_url: その wf-release の実行の URL（`${server}/${repo}/actions/runs/${run_id}`）。description: PR 番号・日時
  - 権限: `statuses: write`（自動の GITHUB_TOKEN）。付けるのに失敗したら、3 回まで試し、だめならジョブを失敗にする（組織には出ているが、印がない状態。次の段階が R1 で止まる側に倒れる。やり直しは 3.5）
- 判定の本体は、マージ方式（merge / squash / rebase）によらない。ブランチの履歴（祖先）ではなく、**先頭のコミット H に付いた印**だけを見る。同じブランチの同じコミットを、次の段階の PR でも先頭として出すため
- **印を信じる条件**（すべて満たすときだけ、印があるとみなす）:
  1. 付けたのが `github-actions[bot]`（status の `creator.login`）
  2. target_url から実行の ID が取り出せ（取り出せなければ R0 で止める）、その実行（`gh api repos/{o}/{r}/actions/runs/{id}`）が、**このリポジトリ**の実行で、`path` が `.github/workflows/wf-release.yml`、`event` が `pull_request`、`conclusion` が `success`、**`head_sha` が H と同じ**（別のコミットの成功した実行を、H の印と取り違えないため）
  3. 同じ context の状態の一番新しいものが `success`（古い success と新しい failure が混ざっていれば、印なし）
  - 確認済み（2026-11-26・force-test-win の PR #21 のマージで動いた wf-release の実行 45801806874）: `head_sha` = 8d0a002 = PR の先頭のコミット（マージのコミット 9ca399b ではない）、`path` = `.github/workflows/wf-release.yml`、`event` = `pull_request`
  - 人が PAT や画面で付けた印、ほかのワークフローが付けた印は、無視する（うっかりの抜け道をふさぐ）
- 名前は、必須チェックの名前（「対象ファイル確認」など）と重ならない（同じコミットの次の段階の PR で、先の成功が必須チェックを満たしてしまわないため。wf-release の「リリース対象確認」の命名と同じ考え）

### 3.2 確かめる規則

ブランチ B の先頭のコミット H を、段階 T へ出すとき。段階の並びは、**origin/main の `branches.txt`**（有効な段階。`get_tier_list`）で決める。P = T の 1 つ前の段階（なければ「なし」）、TOP = 一番上の段階（main）。

| 規則 | 内容 | 破ったとき |
|---|---|---|
| R0 前提 | origin/main と `branches.txt` が読める・段階の並びが正しい（`get_tier_list` の規則）・B がフォークでない（`head.repo` と `base.repo` が同じ） | 失敗（判断できないときは止める） |
| R1 順序 | P があるなら、H に P のリリースの印（3.1 の条件を満たすもの）がある | 失敗 |
| R2 積み重ね | B から T へ前に出したリリースのうち、**まだ TOP まで届いていないもの**の部品が、すべて、今回の反映（package.xml）か削除（destructiveChanges.xml）に入っている。前のリリース＝マージ済みの PR で、`head.ref` が B・`base.ref` が T・同じリポジトリのもの、かつ、その PR の先頭のコミット（`headRefOid`）に T の印（3.1 の条件）があり、TOP の印がないもの（別のブランチのリリースは、対象にしない） | 失敗（抜けた部品を一覧で出す） |
| R3 環境ブランチ | B が `branches.txt` のブランチなら失敗（今の wf-sequence と同じ） | 失敗 |

- 対象が空のとき（deploy-target.txt・remove-target.txt の両方に実質的な行がない）: どの規則も確かめず、リリースもせず、印も付けない（今の「対象ファイル確認」「リリース対象確認」のスキップと同じ。何も組織に出ないので害がない）。次の段階でも同じくスキップされる
- R2 の「TOP まで届いていないもの」に絞る理由: 1 周が終わった分は、上の段階にも出ているので、次の一覧に含める必要がない。ブランチ名を後で使い回したとき、前の別の開発のリリースが、ほぼ必ず TOP まで届いているので、対象にならない（Codex の指摘 3・8）
- R2 は、ファイルの行ではなく、**部品（種類:メンバー）で比べる**。前のリリースの先頭のコミットの作業ツリー（`git worktree add --detach`。一時フォルダ。終わったら必ず消す）で、そのときの deploy-target.txt・remove-target.txt から、sf-release と同じ方法でマニフェストを作って比べる。前のコミットには、そのときのファイルが全部あるので、同じものが作れる。作れない・空になる・`*` しか入っていないときは、止める（判断できないときは止める）。`*` のメンバーは、種類ごとに「全部」として扱う（今回に同じ種類の `*` があれば含む、とみなす）
- R1 と R2 で、原則 1〜4 が守られる: develop の中では、あとの一覧が前の一覧を含む（R2）。上の段階には、前の段階に出したものと同じコミットしか出せない（R1）。今回の失敗は、develop への 2 回目の PR（#16）の時点で、R2 で止まっていた
- マニフェストの生成は、sf-release.sh の `process_list`・`generate_manifest` を `lib/manifest.sh`（新規）へ移し、sf-release.sh と共有する。公開する関数は 1 つ: `manifest_build <リリースのフォルダ> <出力のフォルダ>`（deploy-target.txt・remove-target.txt を読み、package.xml・destructiveChanges.xml を作る。戻り値 0 = 作れた／`RET_NO_CHANGE` = 対象が空／1 = 作れない）。sf-release.sh と R2 は、これだけを使う（`[files]` と `[members]` を別々に作って統合する・メンバーが空なら失敗・削除だけのときの空の package.xml、の今の決まりを、そのまま移す）。反映と削除の重なりの確認・組織にない削除の対象を外す処理・`@ignore-missing` は、組織に出すときの処理なので、sf-release.sh に残す（R2 は、組織に出す前の「一覧」だけを比べる）。sf-release.sh の出力が、移す前と同じになることを、今の test_sf-release.sh の全件で確かめる
- 段階の並びは、厳密に読む（`get_tier_list --strict`。新設）。今の `get_tier_list` は、`branches.txt` がないとき WARNING を出して main だけを返す（`lib/project.sh`。fail-open）。そのまま使うと、判断の材料がないのに通してしまうため、`--strict` を作る。`--strict` を付けないときの動きは、今のまま（sf-metasync・status.sh などは変えない）

  | `branches.txt` の中身 | `get_tier_list`（今のまま） | `get_tier_list --strict` |
  |---|---|---|
  | ファイルがない・読めない | main だけ（WARNING） | **戻り値 1** |
  | 段階の行が 1 つもない（空・コメントだけ） | main だけ（WARNING） | **戻り値 1** |
  | main の行がない（staging・develop はある） | main は有効とみなす | **戻り値 1** |
  | develop はあるが staging がない | develop を無効にする（WARNING） | **戻り値 1**（構成の誤り） |
  | 段階の名前でない行（保護だけのブランチ） | WARNING を出して無視 | 無視する（段階ではないため。保護の判定 `get_branch_list` は今のまま） |
  | 同じ名前が 2 行 | 1 つにする | 1 つにする |
  | main・main＋staging・main＋staging＋develop | その段階を、main → staging → develop の順に出す | 同じ（戻り値 0） |

- **R2 が比べる部品の集合は、両方とも「宣言した対象」**（`manifest_build` の出力。組織への問い合わせをしない）。前のリリースの宣言（そのときの deploy-target.txt・remove-target.txt）が、今回の宣言（今の deploy-target.txt・remove-target.txt）に含まれるかを見る。組織にない削除の対象を外す処理（`phase_prune_destructive`）は、組織に出すときの処理なので、R2 では使わない（使うと、組織の状態で結果が変わるため）
- 用語: 「先頭のコミット」は、PR の head のブランチの**先端（tip）のコミット**のこと（`pull_request.head.sha` = `headRefOid` = 3.1 の H）。最初のコミットではない

### 3.3 段階の構成ごとの決まり

| 構成（`branches.txt`） | develop への PR | staging への PR | main への PR |
|---|---|---|---|
| main だけ | ―（段階でない。今の wf-release・wf-validate の決まりのまま、出さない） | ― | R0・R2・R3（R1 は P がないので確かめない） |
| main・staging | ―（同上） | R0・R2・R3 | R0・R1（staging の印）・R2・R3 |
| main・staging・develop | R0・R2・R3 | R0・R1（develop の印）・R2・R3 | R0・R1（staging の印）・R2・R3 |

- `sf-init.sh --add-tier` で段階を足した直後: 進行中のブランチは、新しい段階の印を持たないので、新しい段階から出し直す（原則どおり）。`--remove-tier` で段階を外した直後: 外した段階は P として数えない（origin/main の `branches.txt` だけで決まる）
- `branches.txt` がない: 今は「今までの動き（3 つとも有効）」にしているが、R0 で止める（判断の材料がないため）。sf-init が必ず作るので、通常は起きない

### 3.4 確かめる場所

判定の本体は `bin/sf-promote-check.sh`（新規。3.6）の 1 か所。ワークフローは、sf-tools（公開リポジトリ）を clone して呼ぶ。

| 場所 | 規則 | 破ったとき | 守るもの |
|---|---|---|---|
| `wf-sequence.yml`（staging・main への PR） | R0・R1・R3（git と gh で足りる） | ジョブ「順序チェック」を失敗にする（**警告だけをやめる**）。PR へのコメント・Slack は今のまま（補助） | Ruleset が効く組織では、マージを止める |
| `wf-validate.yml`（すべての段階への PR） | R2（sf が要る。dry-run の前） | ジョブ「デプロイ検証」を失敗にする | 同上。develop への PR でも効く |
| `wf-release.yml`（マージのあと） | R0〜R3（すべて） | **組織へ出さない**。ジョブを失敗にし、Slack に「❌ リリースを止めました（理由）」 | Ruleset が効かない組織でも、組織を守る（**最後の守り**。マージは止められないが、組織は変わらない） |
| `sf-next.sh`（ランチャーの Next） | R1・R2 の結果を `sf-promote-check.sh --plan --json` から受け取って表示する（自分では計算しない） | 原則に反する出し先を勧めない（例: develop に出したあと変えたら「次は develop」）。勧める先で R2 を破るなら、PR を作る前に止める | 開発者が迷わない（補助。強制は CI がする） |

- 必須チェックの名前（`lib/project.sh` の `required_status_check_names`。「対象ファイル確認」「デプロイ検証」「順序チェック」）は変えない
- wf-release は、マージのあとに動くため、マージを止めることはできない。Ruleset が効かない組織では、「マージはされたが、組織には出ていない」状態がありうる。その状態は、印がないので、次の段階でも R1 で止まる（先へは進まない）

### 3.5 なくすもの・変えるもの

- wf-release の手動の実行（workflow_dispatch）: PR を通らずに組織へ出せるため、**なくす**（6 章の決定）。失敗したリリースのやり直しは、その実行の「Re-run jobs」で行う（同じイベント・同じコミットのため、R0〜R3 も同じく確かめられる）
  - やり直しで二重に出す危険は小さい: Salesforce のデプロイは「全部成功するか、何もしないか」（途中まで出ない）。削除は、組織にない対象を外す処理（sf-release.sh・dbb651b）があるため、やり直しても「No … named」で失敗しない
- wf-sequence の「緊急の Hotfix を妨げない」例外: **なくす**（6 章の決定）。Hotfix も develop → staging → main の順に上げる
- フォークからの PR: R0 で止める（force-* は組織の非公開リポジトリで、フォークからの PR は想定しない）

### 3.6 `bin/sf-promote-check.sh`（新規）の使い方

```
sf-promote-check.sh --pr <PR 番号> [--only sequence|stack] [--json]            # ワークフロー用
sf-promote-check.sh --plan [--json]                                            # sf-next 用（手元のブランチの次の出し先を計算）
```

- `--pr`: PR の情報（先頭のコミット H・`head.ref`（B）・`base.ref`（T）・フォークか）は、引数でなく、`gh pr view <番号>` で GitHub から読む（呼ぶ側が違う H や T を渡して通すことができないように）。リポジトリは、作業ツリーの `origin` から決め、GitHub の応答のリポジトリと一致することを確かめる（違えば R0 で止める）
- `--only`: 利用者が規則を選ぶ機能ではなく、**ワークフローの間の分担**（sf がない wf-sequence で R2 を省くため）だけ。値は `sequence`（R0・R1・R3。wf-sequence）と `stack`（R0・R2。wf-validate）の 2 つに限る。ほかの値・複数の指定・空は、終了コード 2 で拒否する。R0 は必ず確かめる。wf-release は、`--only` を付けずに、すべて（R0〜R3）を確かめる（雛形の静的テストで確かめる。7 章）
- `--plan`: 手元のブランチについて、次に出してよい段階を返す。PR は作らない（sf-next が作る）。sf-next は、表示と PR の作成だけを行い、R1・R2 を自分では計算しない（判定の本体は 1 か所）
  - 前提（満たさなければ、終了コード 2 = 判断できない。sf-next は、理由を出して止める）: `origin` を取得できる・HEAD とその `origin` の先端が同じ（違えば「push していない変更がある」）・PR の一覧を取得できる・`get_tier_list --strict` が通る
  - `next_tier`: 段階を下から順に（develop → staging → main。構成にある段階だけ）見て、H にその段階の印（3.1）がない最初の段階。全部にあれば `none`（1 周が済んだ）。上の段階に印があるのに下の段階にない（原則に反する状態）は、終了コード 2
  - `next_tier` に R2 を当てた結果も返す（破っていれば、sf-next は PR を作らずに、抜けた部品を出す）
  - 今の sf-next の表示との対応: 「マージ済み」= その段階の印がある／「マージ済み・その後の変更が未反映（`merged_stale`）」= その段階へ出した PR はマージ済みだが、今の H には印がない（次の出し先はその段階になる）／「PR あり（`pr_open`）」= `next_tier` へ開いている PR がある（新しく作らず、その PR を表示する）／「順序外（`out_of_order`）」= 表示しない（`--plan` は、順序外の出し先を返さないため）
- 実行する場所: force-* のプロジェクトのルート（ワークフローでは、PR のマージ結果ではなく、PR の先頭のコミット H を取得した作業ツリー。H と作業ツリーの HEAD が同じことを確かめる）
- 依存: git・gh（`GH_TOKEN`）・R2 だけ sf（npm 版）
- 終了コード: 0 = すべて満たす（または対象が空でスキップ）／ 1 = 破った（理由を ERROR で出す。事実だけ。CLAUDE.md の die の決まり）／ 2 = 判断できない（R0。止める側として扱う）
- `--json`: `{"ok":…, "skipped":…, "violations":[{"rule":"R1","detail":…}], "next_tier":…}`。sf-next が使う
- 管理者向けのコマンドではない（読み取りのみ。組織・GitHub を変えない）。手元でも動かせる（sf-next が呼ぶ）

### 3.7 下りの伝播をやめる

- `wf-propagate.yml` を雛形から消す。既存の force-* は `sf-sync-wf.sh --remove wf-propagate.yml` で消す
- `sf-metasync.sh` の手順 12（main → staging・develop の伝播）を消す。main への同期（手順 11 まで）は今のまま
- main の最新は、開発者の PC で、`sf-push.sh` が push のたびに取り込む（今のまま。手順 2）。サーバーで全員のブランチへ一斉にマージはしない（作業中の手元と食い違い、コンフリクトを解けないため）。これは利便のためで、整合性は R1・R2 が守る（GitHub の画面で直接 push しても、R1・R2 で確かめられる）
- 注意: develop に出したあとで push すると、main の新しい変更が入り、先頭のコミットが変わる。R1 で、develop から出し直しになる（原則どおり。sf-next がそう案内する）
- 環境のブランチ（develop・staging）は、PR で上がってくる開発のブランチだけで更新される。main とずれてよい（ずれは、組織とブランチの一致を崩さない。上り PR の R1・R2 で確かめる）。main の手での変更（本番の画面での変更を sf-metasync が取り込んだもの）は、開発のブランチ経由で上がる
- 伝播を前提にしているもの: `phases/init/add_tier.sh`・`remove_tier.sh`・`status.sh`・`verify.sh`・`lib/diag.sh`（ワークフローの数・`wf-propagate` の存在の確認）・e2e（`run.sh` の「wf-propagate: staging・develop に main の最新が入った」・`scenario.sh` の伝播のシナリオ）。それぞれ、伝播の確認を消し、「伝播しないこと」を確かめる形に変える

## 4. 変更の対象

| ファイル | 変更 |
|---|---|
| `bin/sf-promote-check.sh`（新規）・`lib/manifest.sh`（新規） | R0〜R3 の判定。マニフェストの生成の共有。冒頭コメント・`--help`・テスト・`doc/doc-stamps.txt`（CLAUDE.md 3.2） |
| `bin/sf-release.sh` | マニフェストの生成を `lib/manifest.sh` へ移す（動きは変えない） |
| `templates/.github/workflows/wf-sequence.yml` | 順序外を失敗に。sf-tools を clone して R0・R1・R3。`branches.txt` がないときも止める |
| `templates/.github/workflows/wf-validate.yml` | dry-run の前に R2 |
| `templates/.github/workflows/wf-release.yml` | リリースの前に R0〜R3。成功したら印（3.1）。workflow_dispatch をなくす。`statuses: write`・`actions: read` |
| `templates/.github/workflows/wf-propagate.yml` | 削除 |
| `bin/sf-metasync.sh`・`templates/.github/workflows/wf-metasync.yml` | 手順 12（伝播）を削除 |
| `bin/sf-next.sh` | 出し先を `sf-promote-check.sh --plan --json` で決める（今の `get_branch_list`・`origin/<段階>` での判定をやめる。3.6） |
| `lib/project.sh` | `get_tier_list --strict` を足す（3.2 の表。`--strict` なしは今のまま） |
| `phases/init/*`（add_tier・remove_tier・status・verify）・`lib/diag.sh` | 伝播への言及・確認を削除 |
| `tests/`・`tests/e2e/`（run.sh・scenario.sh） | 7 章 |
| 文書 | `doc/sf-cicd-strategy.md`・`doc/tier-scaling-design.md`・`doc/wf-distribution-strategy.md`・`doc/dev-reference.md`・`doc/sf-metasync-redesign.md`・文書サイト（`admin/workflows`・`design/cicd`・`reference/commands-auto`・`reference/structure`・`admin/setup`・`admin/maintenance`・`admin/troubleshooting`・`admin/verify`・`index`）。印を付け直す |

## 5. 移行

- sf-tools は公開前のため、利用者への移行の配慮は要らない（2026-11-01 の決定）
- force-test-win・force-test-mac・e2e のリポジトリは、`sf-sync-wf.sh` で新しいワークフローにし、`--remove wf-propagate.yml` で伝播を消す
- 移行の前に出したリリースには印がない。進行中のブランチは、develop から出し直す（JOB-EQL-1 は main まで済んでいる）

## 6. 決めたこと（2026-11-26・TAMAさん）

1. Hotfix の例外は、なくす（3.5）
2. wf-release の手動の実行（workflow_dispatch）は、なくす（3.5）
3. R2 は、部品の単位（マニフェスト）で比べる。前のリリースごとにマニフェストを作る（1 回 数秒〜十数秒）

## 7. テスト

**単体テスト**（`tests/test_sf-promote-check.sh`。偽の gh・git の作業ツリー・偽の sf）:

- R1: 印あり → 通る／印なし → 失敗／人（`creator` が bot でない）が付けた印 → 無視して失敗／target_url が、ほかのワークフロー（同じ名前の別のパスを含む）・ほかのリポジトリ・失敗した実行・`head_sha` が H と違う成功した実行 → 無視して失敗／target_url が壊れている・実行の ID が取れない → 止める（2）／古い success と新しい failure が混ざる → 失敗
- R2: 前のリリースの部品が全部ある → 通る／本体が抜けた（今回の #16 の再現: フォルダの行を項目の行に書き換え）→ 失敗し、抜けた部品を出す／抜けた部品が remove-target にある → 通る／前のリリースが TOP まで届いている → 対象外／ブランチ名の使い回し（前の開発は main まで届いている）→ 対象外／**別のブランチ**から T へ出た、まだ TOP に届いていないリリースが混ざる → 対象外／`base.ref` が T と違う前の PR → 対象外／`*`／マニフェストが作れない・空 → 止める（終了コード 2）
- R0: main を取得できない・`branches.txt` がない・並びが不正（`get_tier_list --strict`）・フォーク・作業ツリーの HEAD が H と違う・`origin` と GitHub の応答のリポジトリが違う → 止める
- `--only`: `sequence` で R2 を見ない・`stack` で R1・R3 を見ない・どちらでも R0 は見る。ほかの値・複数・空は終了コード 2（`tests/test_cli_args.sh`）
- `--plan`: 下から順に印のない最初の段階を返す・全部にあれば `none`・上にあって下にない → 2・push していない変更 → 2・`origin` や PR の一覧が取れない → 2・R2 を破る段階 → 破った部品を返す
- `get_tier_list --strict`: 3.2 の表のすべての行（`--strict` なしの動きが変わらないことも）
- `lib/manifest.sh`: `manifest_build` の出力が、移す前の sf-release.sh と同じ（混在・`[members]` のみ・`[files]` のみ・削除のみ・空・`*`）
- R3: 環境ブランチ → 失敗
- 構成: main だけ・main＋staging・3 段階（3.3 の表のとおり）
- 対象が空 → スキップ（0）
- `--json` の形・終了コード

**ワークフローの雛形の静的テスト**（`tests/test_workflows.sh` など、今のテストに足す）: wf-release に workflow_dispatch がない・`statuses: write` がある・印を付けるのは成功のあとだけ・wf-release は `sf-promote-check.sh --pr` を `--only` なしで呼ぶ・wf-sequence は `--only sequence`・wf-validate は `--only stack`・wf-propagate がない・wf-sequence が順序外で `exit 1`

**そのほかの単体テスト**: sf-release.sh（マニフェストの生成を lib へ移しても、出力が同じ）・sf-next.sh（develop に出したあと変えたら develop を勧める・R2 を破るなら PR を作らない）・sf-metasync.sh（伝播しない）・sf-init の status・verify・`lib/diag.sh`（伝播を前提にしない）

**e2e**（rr の前に 1 回。CLAUDE.md 1.3.2）:

- 伝播の確認（`run.sh` の「wf-propagate: … main の最新が入った」）を消し、「main へのマージのあと、staging・develop のブランチが変わらない」を確かめる
- 正常系: develop → staging → main の各 PR で、印が付き、次の段階の R1 が通る
- 順序外: develop に出したあと変えて staging へ PR → wf-sequence の「順序チェック」が失敗する（今は警告だけを確かめている ② を、失敗に変える）
- 最後の守り: 順序外の PR をマージする（Ruleset がなければそのまま、あれば管理者のバイパスで）→ wf-release が組織へ出さない（組織に Hello World が増えない）
- 積み重ね: develop に 2 回出し、2 回目で 1 回目の部品を抜く → wf-validate の「デプロイ検証」が失敗する

## 8. 未決

- なし（6 章で決めた。9 章のレビューの指摘は、本文に反映した）

## 9. 検討の記録

- 2026-11-26: TAMAさんの原則（一方通行）と、PR #18 の失敗から起こした。下りの伝播をやめる案は、TAMAさんの提案（「main の変更は、開発のブランチを最新化して取り込むのが正しい。サーバーで一斉にやるのは危険で意味がない」）
- Codex のレビュー（1 回目・13 件）:
  - 取り入れた: 印を信じる条件（付けた者・実行・結果を API で確かめる。3.1）／判断できないときは止める（R0。3.2）／R2 を「TOP まで届いていないもの」に絞る（ブランチ名の使い回しの誤検知。3.2）／対象が空の扱い（3.2）／段階の構成ごとの表（3.3）／フォークからの PR を止める（3.5）／伝播をやめたあとに直すもの（3.7）／コマンドの使い方（3.6）／テストの一覧（7 章）
  - 一部だけ: マニフェストを保存して使う案 → 作り直しを残す（前のコミットにそのときのファイルが全部ある。Actions の成果物は期限で消える）。代わりに、作れないときは止める（3.2）／やり直しで二重に出す危険 → 小さい（デプロイは全部か無か・削除は組織にない対象を外す。3.5）
  - 取り入れなかった（2 回目で了承）: squash / rebase のマージで壊れる（この設計は、祖先でなく先頭のコミットの印で判断するため、マージ方式に依らない。3.1）／順序外が警告だけの道が残る（2 章の「今の動き」の読み違え。3.4 で失敗にする）／R2 では同じものを証明できない（同じものは R1 が保証する。R2 は積み重ねの抜けだけを見る）／リリースのフォルダを一意の ID にする（範囲が大きい。使い回しは R2 の絞り込みで解ける）／「10 章の未決」（存在しない章）
- Codex のレビュー（2 回目・条件付き承認・新しい指摘 6 件。すべて取り入れた）: 印の実行の `head_sha` が H と同じこと・`path` が wf-release.yml であること（3.1）／R2 の前のリリースを `head.ref` = B・`base.ref` = T に限る（3.2）／`--rules` で規則を外せる道をなくす（`--pr` で PR の情報を GitHub から読む・`--only` は sf のない場所の分担だけで R0 は必ず。3.6）／`get_tier_list` が `branches.txt` のないとき main だけを返す（fail-open）ため、`--strict` を作る（3.2）／印の検証のテストを足す（7 章）／`lib/manifest.sh` の公開の関数と、sf-release.sh に残すものを決める（3.2）
- Codex のレビュー（3 回目・条件付き承認・指摘 5 件。すべて取り入れた）: `get_tier_list --strict` の入力ごとの表（3.2）／`--only` は `sequence`・`stack` だけで、ほかは拒否・wf-release は付けない（3.6・7 章）／`--plan` の `next_tier` の決め方と、今の sf-next の表示との対応・判断できないときは止める（3.6）／R2 が比べるのは、両方とも宣言した対象（組織に問い合わせない。3.2）／「先頭のコミット」は先端（tip）のこと（3.2）
- Codex のレビュー（4 回目）: 3 回目の 5 件はすべて解決。設計の新しい誤りはなし（言い回し 1 件「sf-next は R1・R2 を先に計算」→「結果を受け取って表示する」を直した。3.4）。重要度「高」「中」とされた 3 件は、まだ実装していないこと（`get_tier_list --strict`・sf-next の `--plan` への置き換え・`lib/manifest.sh` への切り出し）で、設計の誤りではない。判定は「条件付き承認（実装して、古い判定が残らないことをテストで確かめてから完了）」。設計としては承認と扱い、条件は実装の完了の条件にする
