# 段階（tier）の増減 設計書

> **ステータス: 実装済み（2026-11-22。development へ未反映・rr 待ち）。** 設計の正本は本書、処理の流れの正本は各スクリプトの冒頭コメント（`phases/init/remove_tier.sh`・`add_tier.sh`・`status.sh`・`lib/project.sh` の `get_tier_list`・3 つの workflow）。
> 目的: `sf-tools/config/branches.txt` を、段階（main / staging / develop）の**唯一のスイッチ**にする。行を足せば段階が動き、消せば止まる。減らすための `sf-init.sh --remove-tier` を作る（足すための `--add-tier` は既存）。
> きっかけ: TAMAさんが、検証環境（force-test-win・force-test-mac）を 3 段階から 2 段階にして、develop の組織を開発用（AI の開発サイクル。`doc/sf-log-design.md`）に回したい。セットアップのやり直しなしに、増やしたり減らしたりできる設計にしたい。

## 1. 現状の問題

段階を決めている場所が、3 つに分かれている（2026-11-22 にコードで確認）。

| 場所 | 段階の決め方 | develop の行を `branches.txt` から消したとき |
|---|---|---|
| `branches.txt`（force-* の `sf-tools/config/`） | 表の行 | 消える |
| `sf-metasync.sh`（main の伝播）・`wf-sequence.yml`（マージの順序）・`get_branch_list`（手元のスクリプト）・`status.sh` | `branches.txt`（origin/main か手元） | 止まる（すでに対応済み） |
| `wf-propagate.yml`（main → 下の段階への伝播） | **ブランチがあるか**（`origin/staging`・`origin/develop`） | ❌ ブランチがあれば、伝播を続ける |
| `wf-release.yml`（マージで組織へリリース） | **固定の 3 つ**（`main` / `staging` / `develop`） | ❌ develop への PR のマージで、develop の組織へリリースを続ける |
| `wf-validate.yml`（PR の検証の dry-run） | main → PROD・staging → STG・**それ以外はすべて DEV** | ❌ develop・feature への PR を、develop の組織で検証し続ける（Secrets が残っていれば） |
| GitHub の Secrets / Variables（`*_STG`・`*_DEV`） | ― | 残る（接続できる状態のまま） |

減らすモードはない（`sf-init.sh` にあるのは `--add-tier` / `--reconnect` / `--status` / `--verify`）。

---

## 2. 方針

1. **段階の正本は、origin/main の `branches.txt` だけにする。** workflow は、すべて origin/main の `branches.txt` を読んで、段階が有効かを決める（`wf-sequence.yml` と同じ読み方。PR のマージ結果ではなく、常に main から読む）
   - main は、常に有効（`branches.txt` の規則で main は必須）
   - `branches.txt` にない段階は、**ブランチや Secrets が残っていても、伝播・リリース・検証をしない**
2. **`--remove-tier` は、`branches.txt` から行を消す PR を作るだけ。** ブランチも Secrets / Variables も、既定では残す（残しても、段階が無効なら使われない。残しておけば、戻すときに行を足すだけで済む）。ブランチを消さないのは、まだ main に入っていない変更を失わないため
3. **戻すときは `--add-tier`。** ブランチと接続情報が残っていれば、**つなぎ直さずに、`branches.txt` に行を戻す PR だけを作れる**（6 章）。残っていなければ、今までどおりつなぎ直す
4. 接続情報を本当に消したいとき（組織を別の用途に回すなど）は、**行を消す PR をマージしたあとに**、`--remove-tier <段階> --purge-secrets` で消す（5.3）。PR のマージ前に消すと、PR をやめたときに接続情報だけが失われるため
5. **段階は、最初に作った構成に縛られない。** 1 段階で作ったプロジェクトも、`--add-tier` で 2・3 段階に増やせる（今もできる）。増やせる上限は 3 段階（名前は main / staging / develop の固定）。順番の決まり（develop には staging が要る）と、段階ごとに別の Salesforce 組織が要ることだけが条件
6. workflow の変更は、雛形（`templates/.github/workflows/`）を直し、各 force-* には `sf-sync-wf.sh` で配る（今の配り方のまま）

**不変条件**（実装とテストで守る）:
- 無効の段階へは、**どの経路でも**（PR のマージ・手動の実行・伝播）、組織に書き込まない。ブランチへの伝播もしない
- main は、常に有効
- 段階を判定できない（main を取得できない）ときは、書き込む側に倒さない（ジョブを失敗にする）

---

## 3. workflow の変更

### 3.1 段階の判定（3 つの workflow に共通）

```bash
# >>> sf-tools: tier-switch v1（この印の間は、3 つの workflow で同じ中身にする。--remove-tier・テストが比べる）
# origin/main の branches.txt から、有効な段階を読む（# の行・空行を除く。CR を除く。行の前後の空白を除く）
git fetch origin main --depth=1 -q || { echo "::error::main を取得できません。段階を判定できないため、止めます。"; exit 1; }
if TIERS_RAW=$(git show FETCH_HEAD:sf-tools/config/branches.txt 2>/dev/null); then
  TIERS=$(printf '%s\n' "$TIERS_RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^#' | grep -v '^$' || true)
  TIERS_KNOWN=1
else
  TIERS=""; TIERS_KNOWN=0
  echo "::warning::main に sf-tools/config/branches.txt がありません。段階の切り替えを使わず、今までの動きにします。"
fi
# 段階として扱う名前は main / staging / develop だけ。ほかの名前の行は無視する（::warning）
for _t in $TIERS; do case "$_t" in main|staging|develop) ;; *) echo "::warning::branches.txt の「${_t}」は、段階の名前ではないため、無視します。" ;; esac; done
tier_enabled() {
  [ "$1" = "main" ] && return 0
  [ "$TIERS_KNOWN" = 1 ] || return 0          # branches.txt がないときは、今までの動き（有効とみなし、各 workflow の今の判定に任せる）
  case "$1" in staging|develop) ;; *) return 1 ;; esac
  printf '%s\n' "$TIERS" | grep -qxF -- "$1" || return 1
  # develop は、staging も有効なときだけ有効（branches.txt の規則。develop があって staging がない誤った構成では、develop を止める）
  if [ "$1" = "develop" ]; then printf '%s\n' "$TIERS" | grep -qxF -- staging || return 1; fi
  return 0
}
# <<< sf-tools: tier-switch v1
```

- **`branches.txt` の中身の規則**（段階の有効・無効を決めるところは、すべてこの規則で読む）:
  - 段階の名前は `main` / `staging` / `develop` だけ。ほかの名前の行は、段階としては無視する（`::warning`・WARNING）
  - 同じ名前が 2 行あっても 1 つとして扱う。`main` の行がなくても main は有効
  - **develop は、staging が有効なときだけ有効。** develop があって staging がない誤った構成では、develop を止める（`status.sh` は ERROR を出す）。止める側に倒すのは、2 章の不変条件（迷ったら書き込まない）のため
- **段階を決めるところ**（この規則で読む）: 3 つの workflow（3.1 の関数）・`sf-metasync.sh` の伝播（`bin/sf-metasync.sh` の `phase_propagate_downstream`。今は `get_branch_list` の main 以外のすべてに伝播する）・`status.sh`・`--add-tier` / `--remove-tier`
  - シェルの側には、新しい関数 `get_tier_list`（`lib/project.sh`。この規則で有効な段階を、main・staging・develop の順で、1 行に 1 つ返す）を作り、`sf-metasync.sh` の伝播と `status.sh` は、これを使う。入力ごとの戻り値（テストの共通の期待値にする）:

    | `branches.txt` | 戻り値 | 表示 |
    |---|---|---|
    | ない・空（ブランチの行がない） | `main` だけ（今の `get_branch_list` と同じ。伝播先なし） | WARNING（今と同じ文言） |
    | main / staging / develop | `main` `staging` `develop` | ― |
    | main / staging | `main` `staging` | ― |
    | main / develop（staging がない） | `main` だけ（develop は無効） | WARNING「develop は、staging がないため、段階として無効です」 |
    | 名前でない行（例: `uat`）を含む | その行を除いたもの | WARNING「uat は段階の名前ではないため、無視します」 |
    | 同じ名前が 2 行 | 1 つ | ― |
    | main の行がない（staging だけなど） | `main` を先頭に足したもの | ― |

    - workflow の 3.1 の関数（`tier_enabled`）と違い、ファイルがないときは「main だけ」になる。これは、今の `sf-metasync.sh`（`get_branch_list`）の動きと同じで、「今までの動き」に合わせている（workflow 側の「今までの動き」は、ブランチの有無・固定の 3 つ）
    - 戻り値は main・staging・develop の順に並べ直す（`branches.txt` の並びには頼らない）
  - **wf-metasync.yml は例外**（3.1 の関数を入れない）。判定するのは、workflow ではなく `sf-metasync.sh` だけ。理由:
    - wf-metasync.yml は、main を取得してから、sf-tools を**実行のたびに公開リポジトリから取得して**（Variable `SF_TOOLS_BRANCH`。未設定なら main）、`sf-metasync.sh` を動かす。伝播（ほかのブランチへの push）は、`sf-metasync.sh` の中だけで行い、workflow 自体はしない
    - そのため、判定の規則は、sf-tools の取得元のブランチに入った時点で、そのブランチを使うすべての force-* に届く。force-* の wf-metasync.yml を配り直す必要はない
      - Variable `SF_TOOLS_BRANCH` が未設定（`main`）のプロジェクト → rr（main へのマージ）で届く
      - `SF_TOOLS_BRANCH=development`（検証環境。sf-init の Phase 9 が登録するのは development だけ）のプロジェクト → mm（development への push）で届く。development は main より先に進むので、main を使うプロジェクトより遅れることはない
      - それ以外のブランチを設定したプロジェクトは、想定しない（`--status` で、`SF_TOOLS_BRANCH` が main・development 以外なら WARNING を出す。7 章）
    - 今の版の `sf-metasync.sh` でも、伝播先は main の `branches.txt` の行（`get_branch_list`）なので、行を消せば伝播しない。新しい `get_tier_list` で増えるのは、名前でない行の無視と、develop の staging の条件だけ
  - `--remove-tier` は、wf-metasync.yml について、「伝播を `sf-metasync.sh` に任せている（workflow の中に、ほかのブランチへの push がない）」ことだけを確かめる（5.2 の 3）
- **保護するブランチの判定**（`is_protected_branch`。`sf-push.sh`・pre-push フックなど）は、今のまま `get_branch_list`（`branches.txt` の全行）を使う。段階を外したブランチも、誤って直接 push しないよう、保護は外さない（保護を緩めない側に倒す）

- 判定を呼ぶ箇所（3.2〜3.4）には、コメントの印 `# sf-tools: tier-check` を付ける（`--remove-tier`・`--status`・テストが、判定を使っているかを確かめるため）
- **`branches.txt` がない・読めない**（main にファイルがない）とき: 今までの動き（伝播はブランチの有無・リリースは固定の 3 つ・検証は今の振り分け）にし、`::warning` を出す。古いプロジェクトを壊さないため
- **main を取得できない**とき: 段階を判定できないので、そのジョブを失敗にする（`::error`）。有効か分からないまま、組織に書き込まない
- 3 つの workflow に、同じ判定の関数を置く（workflow は、ほかのファイルを読み込めないため、写しになる。テストで、3 つが同じ中身であることを確かめる。9 章）
- 印のコメント `sf-tools: tier-switch v1` を、3 つの workflow のそれぞれに入れる

#### 3.1.1 起動の経路ごとの判定（すべての経路が、判定を通ること）

| workflow | 起動の経路 | 判定する段階 | 無効のとき |
|---|---|---|---|
| wf-propagate.yml | PR のマージ（マージ先 main） | 伝播先（staging・develop のそれぞれ） | その伝播先だけ飛ばす |
| | 手動の実行（main で） | 同上 | 同上 |
| wf-release.yml | PR のマージ（マージ先 main / staging / develop） | マージ先 | リリースしない |
| | 手動の実行（main / staging / develop で） | 実行したブランチ | リリースしない |
| wf-validate.yml | PR の作成・更新 | マージ先（3.4 の表） | 検証しない |
| wf-metasync.yml | schedule・手動の実行 | 伝播先（`sf-metasync.sh` が `get_tier_list` で決める） | その伝播先だけ飛ばす |
| wf-sequence.yml | PR の作成・更新（マージ先 main / staging） | 順序の判定に使う段階（今も `branches.txt` を読む） | 変えない（今も、`branches.txt` にない段階は、順序の対象外） |

- **wf-sequence.yml は、本書の変更の対象外**（3.1 の関数・印を入れない）。今の判定（origin/main の `branches.txt` を読み、順序を確かめる）のままで、組織にもブランチにも書き込まないため。`--remove-tier` も、wf-sequence.yml は確かめない
- 本書で workflow に 3.1 の関数と印を入れるのは、**wf-propagate.yml・wf-release.yml・wf-validate.yml の 3 つだけ**。wf-metasync.yml は 3.1 の例外（`sf-metasync.sh` が判定する）

- テストでは、この表の行ごとに、無効の段階でジョブ（またはステップ）が、組織にも、ブランチにも、書き込まないことを確かめる（9 章）

### 3.2 wf-propagate.yml（伝播）

- 手順 3（main → staging）・4（main → develop）の最初に、`tier_enabled staging` / `tier_enabled develop` を確かめる
  - 無効 → `result=skipped`・`::notice`（「staging は branches.txt にないため、段階として無効です。伝播しません」）
  - 有効で、ブランチがない → 今までどおり `skipped`（`::notice`）
  - 有効で、ブランチがある → 今までどおり伝播する
- Slack の通知・ジョブの失敗の条件（コンフリクト）は変えない

### 3.3 wf-release.yml（リリース）

- ジョブ「リリース対象確認」（check-branch）の**最初に**、リリース先（PR のマージ先。手動の実行では、実行したブランチ）が有効かを確かめる。**PR のマージ・手動の実行の、どちらの経路も、必ずこの判定を通る**（今の「手動の実行は判定せずに skip=false」の分岐より前に置く）
  - 無効 → `skip=true`・`::notice`（「develop は branches.txt にないため、段階として無効です。リリースしません」）。ジョブ「リリース実行」は動かない
  - 有効 → 今までどおり（デプロイ対象の有無で判定。手動の実行は skip=false）
  - main を取得できない → ジョブを失敗にする（「リリース実行」は `needs` のため動かない）
  - `branches.txt` がない → 今までどおり（`::warning`）
- `on.pull_request.branches` の 3 つと、手動の実行を 3 つに限る条件は、**残す**（「段階になりうる名前」の上限。段階が有効かは、上の判定で決める）

### 3.4 wf-validate.yml（PR の検証）

ジョブ「対象ファイル確認」（check-branch）で、PR のマージ先から、検証に使う段階を決める。

| マージ先 | 使う組織 | 無効のとき |
|---|---|---|
| main | PROD | （常に有効） |
| staging | STG | `skip=true`・`::notice`（検証しない） |
| それ以外（develop・feature など） | DEV（今と同じ） | develop が無効なら、`skip=true`・`::notice`（「develop の段階がないため、この PR は検証しません」） |

- ジョブ「デプロイ検証」は、check-branch の `skip` で動かない（今の仕組みのまま）
- 必須チェック（main・staging への PR）への影響: main への PR は、判定で止まらない。staging への PR は、staging が有効なら今までどおり。staging が無効なのに staging への PR が出たときは、検証が skip され、必須チェックは GitHub の仕様で「スキップ」の扱いになる（staging を外したあとは、staging への PR を出さない運用。`sf-next.sh` は `branches.txt` で次の PR 先を案内するので、staging を案内しない）

---

## 4. 配る順番（大事）

`--remove-tier` で行を消しても、force-* の workflow（wf-propagate・wf-release・wf-validate）が古いままだと、伝播・リリース・検証が止まらない（1 章）。そのため、次の順にする。wf-metasync の伝播は、sf-tools の `sf-metasync.sh` が決める（3.1 の例外）ので、配り直しは要らない（`SF_TOOLS_BRANCH` が main のプロジェクトは 1 の rr で、development のプロジェクトはその前の mm で届く）。

1. sf-tools を rr する（雛形の workflow が新しくなる）
2. 各 force-* で `sf-sync-wf.sh` を実行し、新しい workflow を、通常の変更と同じ順序（feature → staging → main など）で main まで入れる
3. `sf-init.sh --remove-tier develop` を実行する。**origin/main の workflow に印（3.1）がなければ、止める**（5.2 の 3）
4. できた PR（`branches.txt` から develop を消す）をマージする。この時点から、develop の伝播・リリース・検証が止まる

---

## 5. sf-init.sh --remove-tier

### 5.1 使い方

```bash
cd {作業フォルダ}/admin/force-XXXX
~/sf-tools/bin/sf-init.sh --remove-tier develop     # develop の段階を外す
~/sf-tools/bin/sf-init.sh --remove-tier staging     # staging の段階を外す（develop がないときだけ）
```

- 実体は `phases/init/remove_tier.sh`（`add_tier.sh` と同じ形。`sf-init.sh` が環境変数 `REMOVE_TIER`（段階）と `REMOVE_TIER_PURGE`（`--purge-secrets` のとき 1）を export して呼ぶ）
- 管理者向けのコマンド（CLAUDE.md 2.4 の警告ボックス＋確認。`GITHUB_ACTIONS=true` でも省略しない）

**引数の決まり**（`bin/sf-init.sh` の引数の解析）:

| 指定 | 扱い |
|---|---|
| `--remove-tier <段階>` | 値は、次の引数（`-` で始まらないもの）。値なしは die（`--add-tier` と同じ）。staging / develop かどうかは、`remove_tier.sh` が確かめる |
| `--remove-tier <段階> --purge-secrets`（順は問わない） | 接続情報を消すモード（5.3） |
| `--purge-secrets` だけ（`--remove-tier` なし） | die（「--purge-secrets は --remove-tier と一緒に指定してください」） |
| `--remove-tier` と `--add-tier` を両方 | die（逆の操作のため。ほかのモードのように、片方を黙って無視しない） |
| `--remove-tier` と、`--verify` / `--status` / `--reconnect` / `--resume` / `--only` | `--remove-tier` だけを行う（今の「最初に該当した 1 つだけ」の決まりに足す。判定の順は `--add-tier` → `--remove-tier` → `--verify` → `--status` → `--reconnect`） |

- `--purge-secrets` のときは、workflow の確かめ（5.2 の 3）をしない。段階は、すでに branches.txt から外れている（5.3 の 1 で確かめる）。古い workflow のままでも、接続情報を消せば、その段階への書き込みは、むしろ止まる側になる
- `sf-init.sh` の冒頭コメント（【使い方】【オプション】【処理の流れ】）と、`--help` の例に、`--remove-tier` を足す（CLAUDE.md 2.5。`tests/test_cli_args.sh` が、書いたオプションを受け付けるかを確かめる）

### 5.2 処理の流れ

```
 1. REMOVE_TIER が staging / develop でなければ die。force-* でなければ die。origin から REPO_FULL_NAME を求める（parse_github_remote）
 2. git fetch origin main。origin/main の branches.txt を読む（読めなければ die）
      その段階の行がない → die（すでに外れている）
      staging を外すのに、develop の行がある → die（develop を先に外す。--add-tier の「develop には staging が要る」の逆）
 3. origin/main の .github/workflows/ の wf-propagate.yml・wf-release.yml・wf-validate.yml のそれぞれで、段階の判定が、
    この sf-tools の雛形と同じかを確かめる（印 >>> sf-tools: tier-switch v1 と <<< の間を取り出し、雛形の同じ部分と比べる。
    さらに、その判定を使う箇所（3.2〜3.4 の判定の呼び出し）の印 sf-tools: tier-check があるか）
      ない・違う → INFO で「workflow が段階の切り替えに対応していません（または、雛形と違います）。sf-tools を更新し、sf-sync-wf.sh で
             workflow を main まで入れてから、実行してください」と、該当するファイル名を出し、die（die のメッセージは事実だけ。CLAUDE.md 2.2）
      ファイル全体は比べない（sf-tools の版が進むと、段階に関係のない部分が雛形と違うことがあり、止めすぎるため）
    wf-metasync.yml は、判定の印ではなく、「sf-metasync.sh を呼んでいる」「workflow の中に、main 以外のブランチへの git push がない」ことを確かめる（3.1 の例外）。
      満たさない → 上と同じく INFO を出して die
 4. 影響を表示する（読み取りのみ）:
      a. その段階にだけあって、main にない変更: git log --no-merges --oneline origin/main..origin/<段階>（最大 20 行。件数も）
         「ブランチは消さないので、この変更は失われません。ただし、段階を外すと、リリースされなくなります」
      b. その段階をマージ先にする、開いている PR: gh pr list --base <段階> --state open（番号・タイトル）
         「マージしても、リリースされなくなります（PR の検証もされません）」
      c. その段階の Secrets / Variables の一覧（名前だけ。値は出さない）: *_STG / *_DEV。「残します（使われません）。消すには、PR のマージ後に --purge-secrets」
      d. その段階のブランチを対象にする Ruleset（gh api で一覧を読む。名前と対象だけ）。「残します。段階が無効のあいだは、その段階への PR を出さないでください」
 5. 管理者向けの警告（print_admin_warning）→ check_gh_owner → ask_yn（N / q は die）
 6. 未コミットの変更があれば die（add_tier.sh と同じ）
 7. 作業用ブランチ system-remove-tier-<段階>-<YYYYMMDDHHMMSS> を origin/main から作り、
    手順 2 で読んだ branches.txt から、その段階の行（前後の空白・CR を除いて一致する行）だけを除いた内容を、一時ファイル → mv で書く。
    git add → commit --no-verify → push --no-verify -u → gh pr create --base main
 8. 実行前のブランチ（管理者用のクローンでは admin）に戻る
 9. 次にすることを表示する: PR をマージすると止まる・ブランチと接続情報は残した（戻すときは --add-tier で、行を戻すだけで済む）・
    接続情報を消すなら、マージ後に --purge-secrets・ブランチを消すなら手で（消す前に 4a を確かめる）・
    組織の外部クライアントアプリは残した（組織の中のものは触らない）・Ruleset は残した（4d）
```

- **組織には触れない**（外部クライアントアプリ・ユーザーは残す）。組織を開発用に回すとき、CI 用のアプリが残っていても害はない。消すかは人が決める
- **GitHub の設定（Secrets / Variables・Ruleset・ブランチ）も変えない。** 変えるのは、`branches.txt` の PR だけ。PR をやめれば（閉じれば）、何も変わっていない状態に戻る
- 手順 7 の途中で失敗したときに残るもの（作業用ブランチなど。自動では戻さない）は、`add_tier.sh` と同じ書き方で冒頭コメントに書く

### 5.3 --purge-secrets（接続情報を消す。行を消す PR のマージ後）

```bash
~/sf-tools/bin/sf-init.sh --remove-tier develop --purge-secrets
```

```
 1. 5.2 の 1・2 と同じ確かめ。ただし、origin/main の branches.txt に、その段階の行が**ない**こと（PR がマージ済み）を求める。ある → die
 2. その段階の Secrets / Variables の一覧（名前だけ）を表示する。1 つもなければ、その旨を表示して終了する
 3. 管理者向けの警告 → check_gh_owner → ask_yn（「消すと、この段階の組織に、CI からつながらなくなります。戻すときは --add-tier で、つなぎ直します」）
 4. gh secret delete / gh variable delete を 1 つずつ実行し、結果を表示する（失敗したものは WARNING。続ける。最後に、失敗が 1 つでもあれば終了コード 1）
```

- 管理者向けの安全ガード（CLAUDE.md 2.4）: 手順 3 の前に、`print_admin_warning`（「接続情報を消します。この段階の組織に、CI からつながらなくなります」）を表示する。確認の前に、消す名前の一覧（手順 2）と、「Secret の値は、消すと戻せません（戻すときは --add-tier で、新しくつなぎ直します）」を表示する。確認は `ask_yn || die`（`GITHUB_ACTIONS=true` でも省略しない）
- 1 つずつ消し、それぞれの結果（消した・なかった・失敗）を表示する。最後に一覧で、消した・残っている名前を出す
- 一部が失敗したとき: 終了コード 1。もう一度実行すると、残っているものだけを消す（すでにないものは「なかった」として数える。何度実行しても同じ結果になる）
- 段階が無効になってから消すので、消している途中に、その段階へのリリース・検証が動くことはない
- 消す Secrets / Variables の名前は、決まった一覧（`SF_CONSUMER_KEY_<接尾辞>`・`SF_USERNAME_<接尾辞>`・`SF_INSTANCE_URL_<接尾辞>`・`SF_ORG_ID_<接尾辞>`・`SF_ORG_NAME_<接尾辞>`・`SF_ORG_KIND_<接尾辞>`・`SF_ORG_CHECKED_<接尾辞>`。`add_tier.sh` が登録するもの）だけ。ほかの名前は消さない

### 5.4 やらないこと

- **ブランチを消さない**（2 章）
- **main を外すことはできない**（main は必須）
- 組織の中のもの（外部クライアントアプリ・DebugLevel など）は消さない

---

## 6. --add-tier の調整（戻すとき）

- **つなぎ直さずに戻す**: 手順 6（Salesforce 組織への接続）の前に、その段階の接続情報（`SF_CONSUMER_KEY_<接尾辞>`（Secret）・`SF_USERNAME_<接尾辞>`・`SF_INSTANCE_URL_<接尾辞>`（Variable））が GitHub に残っているか（名前の有無だけ。Secret の値は読めない）を確かめる
  - 3 つとも残っている → 残っている接続情報（Variables の組織名・ユーザー名・確認日時）を表示し、`ask_yn`「つなぎ直さずに、段階だけ戻しますか？（N: ブラウザでログインして、つなぎ直す）」
    - Y → 手順 6 を飛ばして、ブランチ・PR の手順へ進む（`branches.txt` に行を戻す PR だけを作る）
    - N → 今までどおり、つなぎ直す
  - 1 つでも欠けている → 今までどおり、つなぎ直す
  - 残っている接続情報が、今も使えるか（組織のアプリが消されていないか・ユーザーが無効になっていないか）は、ここでは確かめられない（Secret の値を読めないため）。PR をマージしたあとの最初の検証・リリースで分かる。そのことを表示する
- 手順 7（ブランチを作る）で、リモートにブランチがすでにある（`--remove-tier` で残したもの）ときは、今の「作らずに進む」に加えて、**main より遅れている本数**（`git rev-list --count origin/<段階>..origin/main`）を表示する
  - 「PR をマージしたあと、次に main へマージしたときの伝播で、main が取り込まれます。すぐ取り込むには、wf-propagate を手動で実行してください」
- そのほかは変えない

---

## 7. --status の調整

- 段階が `branches.txt` にないのに、その段階の**ブランチ**がリモートにある → INFO「develop ブランチは残っていますが、段階としては無効です（branches.txt にない）」
- 段階が無効なのに、その段階の **Secrets / Variables** が残っている → INFO「develop の接続情報が残っています（使われません）」
- origin/main の workflow の段階の判定が、雛形と違う・ない（5.2 の 3 と同じ確かめ）→ WARNING「workflow が段階の切り替えに対応していません（branches.txt から行を消しても、伝播・リリース・検証は止まりません）。sf-sync-wf.sh で更新してください」
- 段階が無効なのに、その段階のブランチを対象にする Ruleset が残っている → INFO（名前と対象）
- `branches.txt` に、段階の名前でない行がある・develop があって staging がない → WARNING / ERROR（3.1 の規則）
- Variable `SF_TOOLS_BRANCH` が、未設定・`main`・`development` のどれでもない → WARNING（wf-metasync が、想定しない版の `sf-metasync.sh` を使うため。3.1 の例外）

---

## 8. force-test-win・force-test-mac への当てはめ

2 つのリポジトリは、**同じ 3 つの組織を共有している**（GitHub の Variables で確認。develop の組織 ID は、どちらも `00Dfj00000LLyi2EAD`（TAMA_DEVELOP））。

**2026-11-22 の決定（TAMAさん。案 1）**: TAMA_DEVELOP は、CI と e2e に残す。force-test-win・force-test-mac は 3 段階のまま。開発用（`doc/sf-log-design.md`）には、新しい Developer Edition を用意する（TAMAさんが申し込む）。エイリアスは `develop` 以外（例: `tama-dev`）。

本書の機能は、それとは別に作る（段階を増やしたり減らしたりできるようにする）。force-test-win・force-test-mac には、workflow の更新（`sf-sync-wf.sh`）だけを入れる（3 段階のままで、動きは変わらない）。段階を外す動作の確かめは、9 章のテストと e2e で行う。

参考: develop の組織を開発用に回すときの手順（今回は行わない）:

1. 本書の実装を rr する（e2e を含む。CLAUDE.md 1.3.2）
2. その組織を使うすべての force-* で、`sf-sync-wf.sh` → main まで入れる
3. それぞれで `sf-init.sh --remove-tier develop` → PR をマージ → 必要なら `--purge-secrets`
   - マージのあと、確かめる: wf-metasync を手動で実行し（Actions の画面）、ログの「伝播したブランチ」に develop がないこと。main への小さな PR をマージし、wf-propagate のログに「develop は段階として無効です」が出ること
4. e2e がその組織を使っていれば、e2e の develop 用の組織を替える（`tests/e2e/bootstrap.sh --add-orgs`）
5. 開発用には、`develop` 以外のエイリアスで、`sf-start` でログインする（`develop` は予約名で、`sf-deploy`・`sf-log` が止めるため）

- **e2e の develop 用の組織も、同じ TAMA_DEVELOP だった**（2026-11-22 に確認。`~/.sf-tools-e2e/fixture.env` の認証 URL のアドレスが `orgfarm-ab5f0b4c87-dev-ed.develop.my.salesforce.com`、その組織の ID が `00Dfj00000LLyi2EAD`）。e2e は、3 段階の通し検証で、develop の組織に Hello World などをリリース・削除する。TAMA_DEVELOP を開発用に回すなら、e2e の develop 用の組織を、別の組織に替える必要がある（`tests/e2e/bootstrap.sh --add-orgs`。10 章）

---

## 9. テスト

- **workflow の判定**（`tests/test_wf-sequence.sh` と同じ方式。YAML から run のスクリプトを取り出し、ローカルのリモートつきの git リポジトリで、`bash -eo pipefail` で動かす）:
  - 新しいテスト `tests/test_wf-tier-switch.sh`（`tests/run_tests.sh` の `TEST_FILES` に足す。`--changed` で、3 つの workflow の雛形を変えたときに動くよう、対応表にも足す）。3 つの workflow のそれぞれで:
    - `branches.txt` に段階がある／ない／ファイルがない／main を取得できない／段階の名前でない行がある／CR・前後の空白がある
    - wf-release: PR のマージと手動の実行の両方で、無効の段階なら `skip=true`（手動の実行も、判定を通ること）。少なくとも次の 4 つを、個別のテストにする:
      - `branches.txt` = main / staging で、develop へのマージの PR → `skip=true`（ジョブ「リリース実行」の条件が偽になる）
      - 同じ構成で、develop の手動の実行 → `skip=true`
      - `branches.txt` = main だけで、staging へのマージの PR・staging の手動の実行 → どちらも `skip=true`
      - main へのマージの PR・main の手動の実行 → どの構成でも、今までどおり（無効にならない）
      - あわせて、ジョブ「リリース実行」の `if:` の式が、`needs.check-branch.outputs.skip != 'true'` を、PR・手動の実行の両方の場合に含むこと（YAML を読んで確かめる）
    - wf-validate: main・staging・develop・feature へのそれぞれの PR で、使う組織と `skip`
    - wf-propagate: staging・develop のそれぞれで、伝播する／しない（ブランチがある／ない との組み合わせ）
  - 変更する 3 つの workflow（wf-propagate・wf-release・wf-validate）の `>>> sf-tools: tier-switch v1` 〜 `<<<` の中身が、同じであること。その 3 つに、判定の呼び出しの印 `sf-tools: tier-check` があること（wf-sequence・wf-metasync には、ないこと）
  - 3.1.1 の表の行ごとに、無効の段階で、書き込まないこと
  - develop があって staging がない `branches.txt` で、develop が無効になること
- **`get_tier_list`**（`tests/test_common.sh` などの既存の lib のテスト）: 3.1 の規則（名前でない行・重複・main の行がない・develop だけ・`branches.txt` がない）。`is_protected_branch` は、今のまま全行を保護すること
- **wf-metasync（`sf-metasync.sh` の伝播。`tests/test_sf-metasync.sh`）**: schedule・手動の実行のどちらも同じ `sf-metasync.sh` の流れなので、伝播の手順（`phase_propagate_downstream`）で確かめる:
  - `branches.txt` が main / staging / develop → staging・develop に伝播する
  - main / staging（develop の行がない）→ develop のブランチがあっても、develop に伝播しない
  - main / develop（staging がない）→ どちらにも伝播しない
  - 名前でない行がある → その名前には伝播しない
  - `branches.txt` がない → 伝播しない（今の動き: main のみ）
- **`remove_tier.sh` の wf-metasync の確かめ**: `sf-metasync.sh` を呼んでいない、または workflow の中に main 以外への push がある wf-metasync.yml で、止まること
- **`remove_tier.sh`**（`tests/test_sf-init3.sh` など、`add_tier.sh` のテストと同じ方式。gh・git をモックか、ローカルのリモート）:
  - 段階がない・develop があるのに staging を外す・印がない → 止まる
  - 4 の影響の表示（main にない変更・開いている PR・Secrets の名前。値を出さない）
  - 作る PR の `branches.txt` から、その段階の行だけが消える（コメント・ほかの行は残る。CR・前後の空白があっても一致する）
  - Secrets / Variables・Ruleset・ブランチを変えない（GitHub への書き込みは、作業用ブランチの push と PR だけ）
  - workflow の段階の判定が、雛形と違う（書き換えられた・古い）とき、止まる
  - `--purge-secrets`: 行がまだある（PR が未マージ）と止まる／決まった一覧の名前だけを消す／一部の失敗で終了コード 1
- **`add_tier.sh`**: 接続情報が 3 つとも残っているとき、Y でつなぎ直さずに PR だけ作る／N でつなぎ直す／1 つでも欠けていれば（`SF_CONSUMER_KEY_<接尾辞>`・`SF_USERNAME_<接尾辞>`・`SF_INSTANCE_URL_<接尾辞>` のそれぞれを、1 つずつ欠かした場合）、聞かずにつなぎ直す
- **`sf-init.sh` の引数**（`tests/test_sf-init.sh` など）: 5.1 の表の行ごと（値なし・`--purge-secrets` だけ・`--add-tier` との同時指定・順の入れ替え・ほかのモードとの同時指定）
- **`--purge-secrets`**: 一部の削除の失敗で終了コード 1、もう一度実行すると、残りだけを消して 0
- **`add_tier.sh`**: 既存のブランチが遅れているとき、本数を表示する
- **`status.sh`**: 7 章の 3 つの表示
- **e2e**: workflow（`templates/`）を変えるので、rr の前に e2e が要る（`tests/e2e/needs-e2e.sh`）。単体テストだけでは、GitHub Actions の起動の条件・ジョブのスキップ・必須チェック・組織への接続の停止を、同時には確かめられないため、**新しいシナリオ `tier-switch` を足す**（`tests/e2e/scenario.sh`。e2e.yml の Windows のジョブが、ほかのシナリオのあと、**最後に**動かす。段階を変えるため）

### 9.1 e2e のシナリオ tier-switch

対象: run.sh が残した 3 段階のテスト用リポジトリ（main + staging + develop。3 つの別の組織）。新しい組織は使わない。

| # | 操作 | 合格の条件 |
|---|---|---|
| 1 | 管理者用のクローンで `sf-init.sh --remove-tier develop`（確認に Y） | PR ができる。Secrets / Variables・Ruleset・ブランチが、実行の前と同じ |
| 2 | その PR をマージする | origin/main の `branches.txt` に develop がない |
| 3 | feature ブランチから develop への PR（デプロイ対象のある、小さな Apex）を作る | wf-validate のジョブ「対象ファイル確認」のログに「段階として無効」。ジョブ「デプロイ検証」は skipped（組織に検証のデプロイをしない） |
| 4 | 3 の PR をマージする | wf-release のジョブ「リリース対象確認」のログに「段階として無効」。ジョブ「リリース実行」は skipped（組織にリリースしない） |
| 5 | wf-release を develop で手動の実行 | 4 と同じ |
| 6 | 2 のマージで動く wf-propagate を待つ | develop のステップは「段階として無効」で skipped。origin/develop の SHA が変わらない |
| 7 | `sf-init.sh --add-tier develop`（接続情報が残っているので、「つなぎ直さずに戻す」に Y） | ブラウザのログインなしで PR ができる |
| 8 | 7 の PR をマージする | origin/main の `branches.txt` に develop がある |
| 9 | feature ブランチから develop への PR をもう一度作る | wf-validate の「デプロイ検証」が動き、成功する（develop の組織で dry-run）。PR は、マージせずに閉じる |

- 組織に書き込まないことは、組織に書き込むジョブ（wf-validate の「デプロイ検証」・wf-release の「リリース実行」）が skipped であることで確かめる（3・4・5）。組織へのデプロイ・検証は、この 2 つのジョブの中だけで行うため。組織の DeployRequest の前後比較（当初の案）は、develop の組織へのログインが要り、確かさも変わらないため、やめた（2026-11-22）
- **後始末**（中断・失敗を含め、必ず行う。`_scn_restore`）: develop の行が origin/main にないまま終わったら、7・8 と同じ方法で戻す。3・9 の PR とブランチは閉じて消す。4 でマージした Apex は、develop のブランチから戻す（develop の組織には入っていない）。終了時に、Secrets / Variables・Ruleset が、実行の前と同じであることを確かめる
- 所要時間の目安: 10〜15 分（実装のあとに測る）。Actions の無料枠（テスト用の組織の月 2,000 分。CLAUDE.md 1.2）に収まるかを、rr の前に確かめる
- wf-metasync の伝播は、このシナリオでは確かめない（組織からの取得に時間がかかり、push が起きるかは組織の状態しだいのため）。単体テスト（9 章の wf-metasync の項目）で確かめる

---

## 10. 未決事項

- [x] e2e の develop 用の組織は TAMA_DEVELOP と同じだった（8 章）→ 2026-11-22 に決定: TAMA_DEVELOP は CI と e2e に残し、開発用に新しい Developer Edition を用意する（案 1）
- [x] e2e に、段階を外したときのシナリオを足すか → 足す（9.1 の tier-switch）。時間と無料枠は、実装のあとに測って確かめる
- [ ] `sf-launcher.sh` / `sf-next.sh` などで、無効の段階のブランチを、利用者が誤って使わないようにするか（今は `branches.txt` を読むので、案内には出ない。直接 `git checkout develop` するのは止めない）
