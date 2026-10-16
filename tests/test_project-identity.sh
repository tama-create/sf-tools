#!/bin/bash
# ==============================================================================
# test_project-identity.sh - lib/project.sh の「プロジェクトの特定」（オーナーと XXXX）のテスト
# ==============================================================================
# 確認すること:
#   ・parse_github_remote / normalize_project_name / discover_clones / gh_owner_candidates
#   ・resolve_init_identity: 引数・対話（オーナー候補・XXXX の入力・補助）。フォルダ構成には頼らない
#   ・resolve_job_identity: 引数・クローンの git remote（1 つ / 複数）・対話
# gh は、モック（test_helper.sh の create_mock_gh）。リポジトリ名は force-XXXX（force- は固定、XXXX は任意）
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== プロジェクトの特定（オーナーと XXXX）===${CLR_RST}"

# 出力に、固定の文字列が含まれるか（正規表現ではない）
_has()   { printf '%s' "$1" | grep -qF -- "$2" && pass "$3" || fail "$3" "'$2' が出力に含まれていない"; }
_hasnt() { printf '%s' "$1" | grep -qF -- "$2" && fail "$3" "'$2' が出力に含まれている" || pass "$3"; }

# bash -c で、common.sh を読み込み、指定のフォルダで、指定のコマンドを実行する。標準入力は、第 3 引数
#   引数: フォルダ 標準入力 コマンド [環境変数の設定...]。出力: コマンドの出力 + 最後に RESULT 行（結果の変数）
_run_in() {
    local dir="$1" input="$2" cmd="$3" mb="$4"
    printf '%b' "$input" | (
        export PATH="$mb:$PATH" MOCK_CALL_LOG="$mb/calls.log"
        cd "$dir" && bash -c "
            readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
            source '${SF_TOOLS_DIR}/lib/common.sh'
            ${cmd}
            echo \"RESULT owner=\${GITHUB_OWNER:-} project=\${COMPANY_NAME:-}\"" 2>&1
    )
}

# 作業フォルダ（任意の場所。フォルダ名に意味はない）を作る
_mkdirs() {
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/test-ident-XXXX")
    mkdir -p "$base/work"; echo "$base/work"
}

# 作業フォルダの、テスト用の一番上のフォルダ（test-ident-*）まで、まとめて削除する
_rm_base() {
    local d="$1"
    while [[ -n "$d" && "$d" != "/" && "$(basename "$d")" != test-ident-* ]]; do d=$(dirname "$d"); done
    [[ "$(basename "$d")" == test-ident-* ]] && rm -rf "$d"
}

# クローンを作る（git init + remote）。引数: 作業フォルダ 作業単位 クローン名 URL
_mkclone() {
    mkdir -p "$1/$2/$3"
    git -C "$1/$2/$3" init -q 2>/dev/null
    git -C "$1/$2/$3" remote add origin "$4" 2>/dev/null
}

test_parse_github_remote() {
    local mb; mb=$(setup_mock_bin)
    local out
    out=$(_run_in "${TMPDIR:-/tmp}" "" 'for u in https://github.com/o/force-a.git git@github.com:o/force-b.git https://tok@github.com/o/r ssh://git@github.com/o/force-c/ https://gitlab.com/o/r https://github.com/o/r/extra; do echo "$u => $(parse_github_remote "$u" || echo NG)"; done' "$mb")
    _has "$out" "force-a.git => o force-a" "HTTPS の URL から、オーナーとリポジトリ名を取り出せる"
    _has "$out" "force-b.git => o force-b" "SSH（git@github.com:）の URL を読める"
    _has "$out" "o/r => o r" "認証情報つきの HTTPS を読める"
    _has "$out" "force-c/ => o force-c" "ssh:// 形式・末尾の / を読める"
    _has "$out" "gitlab.com/o/r => NG" "GitHub 以外の URL は、拒否する"
    _has "$out" "r/extra => NG" "階層が多い URL は、拒否する"
    teardown "$mb"
}

test_normalize_project_name() {
    local mb; mb=$(setup_mock_bin)
    local out
    out=$(_run_in "${TMPDIR:-/tmp}" "" 'for n in acme force-acme Force-Acme "  acme  " "" force- a.b a..b -x acme/x "a b" acme.git; do echo "[$n] => $(normalize_project_name "$n" || echo NG)"; done' "$mb")
    _has "$out" "[acme] => acme" "XXXX は、そのまま使える"
    _has "$out" "[force-acme] => acme" "force- まで入力しても、除く（force-force-XXXX を防ぐ）"
    _has "$out" "[Force-Acme] => Acme" "force- は、大文字小文字を問わず除く"
    _has "$out" "[  acme  ] => acme" "前後の空白を除く"
    _has "$out" "[] => NG" "空は、不正"
    _has "$out" "[force-] => NG" "force- だけは、不正（XXXX がない）"
    _has "$out" "[a.b] => a.b" "ピリオドは、使える"
    _has "$out" "[a..b] => NG" "連続するピリオドは、不正"
    _has "$out" "[-x] => NG" "先頭がハイフンは、不正"
    _has "$out" "[acme/x] => NG" "/ は、不正"
    _has "$out" "[a b] => NG" "空白は、不正"
    _has "$out" "[acme.git] => NG" ".git で終わる名前は、不正"
    teardown "$mb"
}

test_discover_clones() {
    local mb dir out; mb=$(setup_mock_bin); dir=$(_mkdirs)
    _mkclone "$dir" "JOB-1" "force-acme" "https://github.com/my-org/force-acme.git"
    _mkclone "$dir" "JOB-2" "force-acme" "https://github.com/my-org/force-acme.git"     # 同じものは、重複を除く
    _mkclone "$dir" "init-beta" "force-beta" "git@github.com:other-org/force-beta.git"
    _mkclone "$dir" "JOB-3" "force-x" "https://gitlab.com/my-org/force-x.git"            # GitHub 以外は、無視
    _mkclone "$dir" "JOB-4" "not-force" "https://github.com/my-org/not-force.git"        # force- で始まらないフォルダは、見ない
    _mkclone "$dir" "JOB-5" "force-y" "https://github.com/my-org/plain-repo.git"         # リポジトリ名が force- でないものは、無視
    mkdir -p "$dir/JOB-6/force-nogit"                                                    # クローンでないフォルダは、無視
    out=$(_run_in "$dir" "" 'discover_clones "$PWD"' "$mb")
    _has "$out" "my-org force-acme" "クローンの git remote から、オーナーとリポジトリを取れる"
    _has "$out" "other-org force-beta" "SSH の remote も読める（作業単位のフォルダ名は、関係ない）"
    assert_equals "$(printf '%s\n' "$out" | grep -c '^my-org force-acme$')" "1" "同じリポジトリは、1 行にまとまる"
    assert_equals "$(printf '%s\n' "$out" | grep -c 'force-x\|not-force\|plain-repo\|nogit')" "0" "GitHub 以外・force- でないもの・クローンでないものは、無視する"
    teardown "$mb"; _rm_base "$dir"
}

test_gh_owner_candidates() {
    local mb out; mb=$(setup_mock_bin); create_mock_gh "$mb"
    out=$(MOCK_GH_API_USER=tama MOCK_GH_ORGS_ADMIN=$'org-a\norg-b' _run_in "${TMPDIR:-/tmp}" "" 'gh_owner_candidates admin' "$mb" | grep -v RESULT)
    assert_equals "$out" $'org-a\norg-b\ntama' "admin: 管理者の組織 → 自分のアカウントの順に出る"
    out=$(MOCK_GH_API_USER=tama MOCK_GH_ORGS_MEMBER=$'org-m\ntama' _run_in "${TMPDIR:-/tmp}" "" 'gh_owner_candidates member' "$mb" | grep -v RESULT)
    assert_equals "$out" $'org-m\ntama' "member: 所属する組織 → 自分のアカウント（重複は 1 つ）"
    teardown "$mb"
}

test_init_identity_args() {
    local mb dir out; mb=$(setup_mock_bin); create_mock_gh "$mb"; dir=$(_mkdirs)
    out=$(_run_in "$dir" "" 'export SF_INIT_OWNER=my-org SF_INIT_PROJECT=acme; resolve_init_identity' "$mb")
    _has "$out" "RESULT owner=my-org project=acme" "任意の場所 + 引数 → 入力なしで決まる（）"
    out=$(_run_in "$dir" "" 'export SF_INIT_OWNER=my-org SF_INIT_PROJECT=force-acme; resolve_init_identity' "$mb")
    _has "$out" "project=acme" "--project に force- まで書いても、除く"
    _has "$out" "force- は自動で付くため" "force- を除いたことを、表示する"
    out=$(_run_in "$dir" "" 'export SF_INIT_OWNER=my-org SF_INIT_PROJECT="a b"; resolve_init_identity' "$mb")
    _has "$out" "プロジェクト名" "不正なプロジェクト名 → エラーで、理由を表示"
    _hasnt "$out" "RESULT" "不正なプロジェクト名 → 先へ進まない"
    out=$(_run_in "$dir" "" 'export SF_INIT_OWNER="bad_owner!" SF_INIT_PROJECT=acme; resolve_init_identity' "$mb")
    _has "$out" "オーナー名が正しくありません" "不正なオーナー名 → エラー"
    out=$(_run_in "$dir" "" 'export SF_INIT_OWNER=my-org SF_INIT_PROJECT=acme; resolve_init_identity; echo "EXPORTED=$SF_INIT_OWNER/$SF_INIT_PROJECT"' "$mb")
    _has "$out" "EXPORTED=my-org/acme" "決めた値を export する（sf-tools を更新して実行しなおすときと Phase 2 が使う）"
    teardown "$mb"; _rm_base "$dir"
}

test_init_identity_prompt() {
    local mb dir out; mb=$(setup_mock_bin); create_mock_gh "$mb"; dir=$(_mkdirs)
    # オーナーの候補が 1 つ（自分のアカウントだけ）→ 自動で決まる。XXXX を入力 → 確認 Y
    out=$(MOCK_GH_API_USER=tama MOCK_GH_REPO_LIST=$'force-old' _run_in "$dir" 'acme\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "RESULT owner=tama project=acme" "候補が 1 つ → オーナーは自動。XXXX を入力して決まる"
    _has "$out" "XXXX の部分だけを入力してください" "「force- は自動で付く。XXXX だけ入力」と案内する"
    _has "$out" "例: acme と入力 → force-acme" "入力例を表示する"
    _has "$out" "作るリポジトリ" "入力のあとに、作るリポジトリ名を表示して確認する"
    _has "$out" "tama/force-acme" "作るリポジトリ名は、オーナー/force-XXXX の形"
    _has "$out" "admin/force-acme" "管理者用の作業フォルダ（admin）を表示する"
    # 候補が複数 → 番号で選ぶ
    out=$(MOCK_GH_API_USER=tama MOCK_GH_ORGS_ADMIN=$'org-a\norg-b' _run_in "$dir" '2\nacme\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "RESULT owner=org-b project=acme" "候補が複数 → 番号で選べる（2 = org-b）"
    # すでにあるプロジェクトの一覧を、参考に表示する。同じ名前は、警告して、聞きなおす
    out=$(MOCK_GH_API_USER=tama MOCK_GH_REPO_LIST=$'acme\nbeta' _run_in "$dir" 'acme\nnewp\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "acme / beta" "すでにあるプロジェクトの一覧を、参考に表示する"
    _has "$out" "tama/force-acme は、すでに存在します" "すでにある名前 → 警告して、聞きなおす"
    _has "$out" "project=newp" "別の名前（newp）で決まる"
    # force- まで入力 → 除く。不正な名前 → 聞きなおす。N → 聞きなおす
    out=$(MOCK_GH_API_USER=tama _run_in "$dir" 'force-acme\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "project=acme" "force-acme と入力 → acme として扱う"
    out=$(MOCK_GH_API_USER=tama _run_in "$dir" 'a b\nacme\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "使えない名前です" "不正な名前 → 理由を表示して、聞きなおす"
    _has "$out" "project=acme" "聞きなおして、決まる"
    out=$(MOCK_GH_API_USER=tama _run_in "$dir" 'acme\nN\nbeta\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "project=beta" "確認で N → 聞きなおして、beta で決まる"
    # 入力できない（標準入力が空）→ 中断する
    out=$(MOCK_GH_API_USER=tama _run_in "$dir" '' 'resolve_init_identity' "$mb")
    _hasnt "$out" "RESULT" "入力がない → 先へ進まない（中断）"
    # オーナーの候補が 1 つもない（gh が使えない）→ オーナーも、入力する
    printf '#!/bin/bash\nexit 1\n' > "$mb/gh"; chmod +x "$mb/gh"   # gh が使えない（未認証・通信エラー）
    out=$(_run_in "$dir" 'my-org\nacme\nY\n' 'resolve_init_identity' "$mb")
    _has "$out" "owner=my-org project=acme" "候補がない → オーナーも入力して決まる"
    teardown "$mb"; _rm_base "$dir"
}

test_job_identity() {
    local mb dir out; mb=$(setup_mock_bin); create_mock_gh "$mb"
    # カレントの下のクローンが 1 種類 → 自動
    mb=$(setup_mock_bin); create_mock_gh "$mb"; dir=$(_mkdirs)
    _mkclone "$dir" "admin" "force-acme" "https://github.com/org-x/force-acme.git"
    _mkclone "$dir" "JOB-1" "force-acme" "https://github.com/org-x/force-acme.git"
    out=$(_run_in "$dir" "" 'resolve_job_identity "" ""' "$mb")
    _has "$out" "RESULT owner=org-x project=acme" "クローンが 1 種類 → 入力なしで、git remote から決まる"
    # 複数 → 番号で選ぶ
    _mkclone "$dir" "JOB-2" "force-beta" "https://github.com/org-y/force-beta.git"
    out=$(_run_in "$dir" '2\n' 'resolve_job_identity "" ""' "$mb")
    _has "$out" "どのプロジェクトですか" "クローンが複数 → 選択肢を表示する"
    _has "$out" "owner=org-y project=beta" "番号で選べる（2 = org-y/force-beta）"
    # --project 指定 → 同じリポジトリのクローンから、オーナーを取る
    out=$(_run_in "$dir" "" 'resolve_job_identity "" "beta"' "$mb")
    _has "$out" "owner=org-y project=beta" "--project beta → そのリポジトリのクローンから、オーナーを取る（入力なし）"
    out=$(_run_in "$dir" "" 'resolve_job_identity "" "force-acme"' "$mb")
    _has "$out" "owner=org-x project=acme" "--project force-acme → force- を除いて、acme として扱う"
    out=$(_run_in "$dir" "" 'resolve_job_identity "my-own" "zzz"' "$mb")
    _has "$out" "owner=my-own project=zzz" "--owner と --project の両方 → 入力なしで決まる"
    teardown "$mb"; _rm_base "$dir"
    # クローンが 1 つもない → 対話（オーナーは gh のログインから、XXXX は入力）
    mb=$(setup_mock_bin); create_mock_gh "$mb"; dir=$(_mkdirs)
    out=$(MOCK_GH_API_USER=tama _run_in "$dir" 'acme\nY\n' 'resolve_job_identity "" ""' "$mb")
    _has "$out" "force-* のクローンが見つかりません" "クローンがない → その旨を表示して、対話にする"
    _has "$out" "owner=tama project=acme" "対話で決まる"
    teardown "$mb"; _rm_base "$dir"
}

test_parse_github_remote
test_normalize_project_name
test_discover_clones
test_gh_owner_candidates
test_init_identity_args
test_init_identity_prompt
test_job_identity

print_summary
