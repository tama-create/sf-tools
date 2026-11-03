'use strict';
// ==============================================================================
// metasync.js - 組織から取得した内容と手元の main を比べて計画を作り、反映する（bin/sf-metasync.sh から呼ぶ）
// ==============================================================================
// 組織の内容を正として、手元の「同期の対象のフォルダ」を、取得結果と同じにする（鏡像）。追加・変更・削除を、計画（plan）に
// して出し、削除には、安全の守り（S2〜S5）を通す。反映（apply）は、計画の A・M・D だけを行う（H = 保留は、何もしない）。
// Node の標準ライブラリだけを使う（追加パッケージなし。sf CLI が npm 版のため、Node は前提）。
// 境界は、この 1 ファイルだけ。シェル側（bin/sf-metasync.sh）が、順序・Git・警告と確認・終了コードを受け持つ。
// 設計: doc/sf-metasync-redesign.md（3.4 境界・4.5 削除の守り）
//
// 【使い方】
//   node lib/metasync.js plan  --repo DIR --fetched DIR --types-file F --dirs-table F --out PLAN
//                              [--recent-files F] [--retrieve-json F] [--allow-mass-delete]
//   node lib/metasync.js apply --plan PLAN --repo DIR --fetched DIR
//   node lib/metasync.js root  --repo DIR     # sfdx-project.json のパッケージのフォルダ（path）を出す。1 つでなければ中断（S8）
//   node lib/metasync.js detect --org ALIAS --types-file F --table F --state F --out-state F [--now ISO]
//                                              # 組織に変更があるかを、取得の前に調べる（読み取りのみ。設計 15 章）
//
// 【オプション】
//   --org ALIAS         : （detect）問い合わせる組織のエイリアス
//   --table F           : （detect）種類ごとの検知の区分の表（sf-tools の config/metasync-detect.txt）
//   --state F           : （detect）前回の状態（force-* の sf-tools/metasync/state.json）。なくても、読めなくてもよい
//   --out-state F       : （detect）今回の状態の出力先。書くのは、終了コード 10・11 で、一覧の取得ができたときだけ
//   --now ISO           : （detect）今回の開始時刻（テスト用。省略時は現在）
//   --repo DIR          : 手元のリポジトリの根（sfdx-project.json がある場所）
//   --fetched DIR       : 取得結果の一時プロジェクトの根（sfdx-project.json の packageDirectories と同じ構成）
//   --types-file F      : 同期する種類の一覧（force-* の sf-tools/config/metadata.txt）
//   --dirs-table F      : 種類 → フォルダ名の表（sf-tools の config/metadata-dirs.txt）
//   --out PLAN          : 計画の出力先（TSV。上書き）
//   --recent-files F    : 直近に、同期以外のコミットで変わったファイルの一覧（リポジトリの根からの相対パス。1 行に 1 つ）。S5 に使う
//   --retrieve-json F   : sf project retrieve start --json の応答。S1・S2 に使う（空・読めないときは、問題なしとみなす）
//   --allow-mass-delete : S3（消えたフォルダ）・S4（削除が多い）の保留を解く
//
// 【処理の流れ】（plan）
//   1. sfdx-project.json の packageDirectories が 1 つでなければ、中断する（S8）。根 = <path>/main/default
//   2. 同期の対象のフォルダ = 「--types-file の種類に当たるフォルダ（--dirs-table）」と「取得結果にあるフォルダ」の和集合
//   3. フォルダごとに、手元（A）と取得結果（B）のファイルを比べる。B だけ = A（追加）／ 両方で中身が違う = M（変更）／
//      A だけ = D（削除）。中身は、バイト単位で比べる。改行コード（CRLF / LF）だけの違いは、同じとみなす（テキストのみ）
//   4. 残すファイル（削除の対象にしない）: .gitkeep と、.forceignore の行に当たるファイル（否定の ! の行は、警告して無視する）
//   5. 削除の守り（当たった削除は H = 保留にして、ファイルを残す）:
//        S1 取得の応答の status が 0 以外 → 中断（終了コード 1）
//        S2 取得の応答に、問題の報告がある → 報告に種類が読み取れて、その種類のフォルダがあれば、そのフォルダの削除を保留。
//           種類が読み取れなければ、その回の削除を、すべて保留。
//           ただし、「この組織・この API バージョンでは使えない種類」（Entity type 'X' is not available in this organization /
//           api version）の報告は、取得の失敗ではないので、表（--dirs-table）にある種類のフォルダだけ保留し、表にない種類は保留しない
//        S3 手元に 1 件以上あった（残すファイルを除く）フォルダが、取得結果で 0 件 → そのフォルダの削除を保留（--allow-mass-delete で解く）
//        S5 --recent-files にあるファイルの削除 → 保留（時間がたてば解ける。--allow-mass-delete では解けない）
//        S4 残りの削除の件数が、max(100, 手元の同期の対象のファイルの 10%) を超える → 削除をすべて保留（--allow-mass-delete で解く）
//   6. 標準出力に、要約（件数・削除の一覧の先頭 30 件・保留とその理由）を出し、--out に計画を書く。
//      要約の最後に、「使えない種類」（S2 の報告）と、警告（先頭に [WARNING] を付ける行）を出す。どちらも、種類が多くても 1 行にまとめる
//      （重複は除く。名前は省略しない）。表（--dirs-table）にない種類の警告も、1 行
//
// 【補足】
//   ・計画の形式（TSV。見出し行なし）: 操作<TAB>パス<TAB>理由。操作は A・M・D・H。パスは、リポジトリの根からの相対（/ 区切り）。
//     H の理由は S2 / S3 / S4 / S5。A・M・D の理由は空
//   ・終了コード: 0 = 計画できた（保留なし、または S5 だけ）／ 3 = 計画できた（S2・S3・S4 の保留あり）／ 1 = 中断
//     （引数の誤り・読めない・S1・S8・パスの安全の確認。メッセージは標準エラーに [ERROR] で出す）
//   ・apply は、計画のパスが、根（<path>/main/default）の外を指していたら、何も変えずに中断する（終了コード 1）。
//     削除で空になったフォルダは、根の直下まで消す（根は残す）
//   ・.forceignore の解釈は、*・**・?・先頭の /・末尾の / だけに対応する（gitignore の簡易版）
//
// 【処理の流れ】（detect。変更の検知。設計 15 章）
//   1. --types-file の種類を、--table の区分で分ける: A = 設定変更の履歴（SetupAuditTrail）で検知 ／ B = 更新日時の一覧
//      （sf org list metadata）で検知 ／ C = 表にない種類（検知できない。毎日の全件取得でだけ反映される）
//   2. 区分 B の種類の一覧を取り、種類ごとの「最新の更新日時・件数・名前のハッシュ」を作る（Report・Dashboard・Document・
//      EmailTemplate は、フォルダの種類を先に一覧し、フォルダごとに問い合わせる。sf は同時に 4 つまで）
//   3. 前回の状態（--state）が読めて、版（version）と設定のハッシュ（configHash）が合うときだけ、比べる。
//      区分 A に種類があれば、履歴に「前回の開始時刻の 10 分前」より後の記録が 1 件でもあるかを、1 回の問い合わせ
//      （SELECT COUNT() FROM SetupAuditTrail WHERE CreatedDate > …）で調べる（履歴の分類名・Action は、見ない）
//   4. 区分 B のどれかが前回と違う、または履歴に記録がある → 変更あり（10）。どちらもない → 変更なし（0）。
//      状態が使えない・履歴の問い合わせが失敗 → 不明（11）。一覧の取得が失敗 → 不明（11。状態は書かない）
//   5. 10・11 のとき（一覧が取れていれば）、今回の状態（lastFullSyncAt = 今回の開始時刻）を --out-state に書く。
//      呼び出し側は、全件取得が成功したあとで、これを状態ファイルにする
//
// 【補足】（detect）
//   ・終了コード: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明（呼び出し側は、0 以外では、必ず全件取得する）／ 1 = 引数の誤り
//   ・環境変数 SF_METASYNC_SF: 起動するコマンドを sf から差し替える（テストで、モックの sf を使うため）
//   ・変更なしと判定できても、区分 C の種類の変更は見えない（毎日の全件取得で反映される）。検知は、取得を省くための手がかりで、
//     正しさの根拠にしない（失敗・不明は、すべて全件取得に倒す）
// ==============================================================================

const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const crypto = require('crypto');

const MASS_MIN = 100;        // S4: 削除の件数のしきい値の下限
const MASS_RATIO = 0.10;     // S4: 手元の同期の対象のファイルに対する割合
const LIST_MAX = 30;         // 要約に出す削除の一覧の件数

function fail(msg) {
  process.stderr.write('[ERROR] ' + msg + '\n');
  process.exit(1);
}

// ---- 引数 ----
function parseArgs(argv) {
  const cmd = argv[0];
  if (!['plan', 'apply', 'root', 'detect'].includes(cmd)) fail('使い方: node lib/metasync.js plan|apply|root|detect [オプション]');
  const o = { cmd, allowMass: false };
  const need = new Set(['--repo', '--fetched', '--types-file', '--dirs-table', '--out', '--recent-files', '--retrieve-json', '--plan',
    '--org', '--table', '--state', '--out-state', '--now']);
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--allow-mass-delete') { o.allowMass = true; continue; }
    if (need.has(a)) {
      if (i + 1 >= argv.length) fail(a + ' に値がありません。');
      o[a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
      continue;
    }
    fail('不明なオプションです: ' + a);
  }
  const req = cmd === 'plan' ? ['repo', 'fetched', 'typesFile', 'dirsTable', 'out'] : cmd === 'root' ? ['repo']
    : cmd === 'detect' ? ['org', 'typesFile', 'table', 'state', 'outState'] : ['plan', 'repo', 'fetched'];
  for (const k of req) if (!o[k]) fail('--' + k.replace(/[A-Z]/g, c => '-' + c.toLowerCase()) + ' は必須です。');
  return o;
}

// ---- ファイルの読み取りの部品 ----
function readLines(file) {
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith('#'));
}

function packageRoot(repo) {
  const f = path.join(repo, 'sfdx-project.json');
  if (!fs.existsSync(f)) fail('sfdx-project.json が見つかりません: ' + f);
  let j;
  try { j = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { fail('sfdx-project.json を読めません: ' + e.message); }
  const dirs = j && j.packageDirectories;
  if (!Array.isArray(dirs) || dirs.length !== 1 || !dirs[0].path) {
    fail('sfdx-project.json の packageDirectories が 1 つではありません（S8。新しい部品の置き場所を決められないため、中断します）。');
  }
  return dirs[0].path.replace(/\\/g, '/').replace(/\/+$/, '') + '/main/default';
}

function walk(dir) {   // dir の下のファイルを、dir からの相対パス（/ 区切り）で返す。なければ空
  const out = [];
  if (!fs.existsSync(dir)) return out;
  (function rec(d, rel) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const r = rel ? rel + '/' + e.name : e.name;
      if (e.isDirectory()) rec(path.join(d, e.name), r);
      else if (e.isFile()) out.push(r);
    }
  })(dir, '');
  return out.sort();
}

function sameContent(fa, fb) {
  const a = fs.readFileSync(fa), b = fs.readFileSync(fb);
  if (a.equals(b)) return true;
  if (a.includes(0) || b.includes(0)) return false;   // バイナリは、改行の違いを無視しない
  const norm = x => x.toString('latin1').replace(/\r\n/g, '\n');
  return norm(a) === norm(b);
}

// ---- .forceignore（gitignore の簡易版）----
function globToRegex(pat) {
  let re = '';
  for (let i = 0; i < pat.length; i++) {
    const c = pat[i];
    if (c === '*') {
      if (pat[i + 1] === '*') {
        if (pat[i + 2] === '/') { re += '(?:.*/)?'; i += 2; } else { re += '.*'; i += 1; }
      } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return re;
}

function loadIgnore(repo, warnings) {
  const f = path.join(repo, '.forceignore');
  const rules = [];
  if (!fs.existsSync(f)) return () => false;
  for (let line of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('!')) { warnings.push('.forceignore の否定の行は、解釈しません（無視します）: ' + line); continue; }
    let anchored = false;
    if (line.startsWith('/')) { anchored = true; line = line.slice(1); }
    line = line.replace(/\/+$/, '');
    if (!line) continue;
    if (line.includes('/')) anchored = true;
    const body = globToRegex(line);
    rules.push(new RegExp(anchored ? '^' + body + '(?:/.*)?$' : '(?:^|/)' + body + '(?:/.*)?$'));
  }
  return p => rules.some(r => r.test(p));
}

// ---- 取得の応答（S1・S2）----
// 報告は、2 つの形を読む。
//   ・「この組織・この API バージョンでは使えない種類」（Entity type 'X' is not available in this organization / api version）:
//     取得の失敗ではない（その種類の部品は、もともと取得されない。Developer Edition などでは、ふつうに出る）。
//     表（typeToFolder）にある種類は、そのフォルダだけ保留する。表にない種類は、保留しない（取得結果にフォルダが現れず、同期の対象にならない
//     ため、守る対象がない）
//   ・上以外の問題の報告: 種類が読めて、表にあれば、そのフォルダだけ保留する。読めない・表にないときは、その回の削除を、すべて保留する
function readRetrieve(file, types, typeToFolder, warnings) {
  const res = { status: 0, holdAll: false, holdFolders: new Set(), notes: [], unavailable: [] };   // unavailable: 使えない種類の名前（重複なし。表示は 1 行にまとめる）
  if (!file || !fs.existsSync(file)) return res;
  let j;
  try { j = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return res; }   // 空・JSON でない = 情報なし
  if (!j || typeof j !== 'object') return res;
  if (typeof j.status === 'number' && j.status !== 0) { res.status = j.status; return res; }
  const r = j.result || {};
  const items = [].concat(Array.isArray(r.messages) ? r.messages : [], Array.isArray(r.warnings) ? r.warnings : []);
  for (const it of items) {
    const text = typeof it === 'string' ? it : String((it && (it.problem || it.message)) || JSON.stringify(it));
    const na = /Entity type '([A-Za-z0-9_]+)' is not available in this (?:organization|api version)/i.exec(text);
    if (na) {
      const naFolder = typeToFolder.get(na[1]);
      if (naFolder) res.holdFolders.add(naFolder);
      if (!res.unavailable.includes(na[1])) res.unavailable.push(na[1]);
      continue;
    }
    const m = /type:\s*([A-Za-z0-9_]+)/.exec(text) || /of type\s+([A-Za-z0-9_]+)/.exec(text);
    const folder = m ? typeToFolder.get(m[1]) : null;
    if (folder) { res.holdFolders.add(folder); res.notes.push(m[1] + ': ' + text.slice(0, 120)); }
    else { res.holdAll = true; res.notes.push(text.slice(0, 120)); }
  }
  return res;
}

// ---- plan ----
function plan(o) {
  const warnings = [];
  const root = packageRoot(o.repo);
  const repoRoot = path.join(o.repo, root), fetchedRoot = path.join(o.fetched, root);

  const types = readLines(o.typesFile);
  const typeToFolder = new Map();
  for (const l of readLines(o.dirsTable)) {
    const p = l.replace(/\s+#.*$/, '').split(/\s+/);
    if (p.length >= 2) typeToFolder.set(p[0], p[1]);
  }
  const managed = new Set();
  for (const t of types) {
    if (typeToFolder.has(t)) managed.add(typeToFolder.get(t));
  }
  const fetchedTop = fs.existsSync(fetchedRoot)
    ? fs.readdirSync(fetchedRoot, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name) : [];
  for (const d of fetchedTop) managed.add(d);
  // 表にない種類は、1 行にまとめる（重複は除く。名前は、省略しない）。種類ごとに 1 行ずつ出すと、40 行以上になるため
  const unmapped = [...new Set(types.filter(t => !typeToFolder.has(t)))];
  if (unmapped.length) {
    warnings.push(`表（--dirs-table）にない種類が ${unmapped.length} 個あります（取得結果にフォルダが現れれば同期し、現れなければ触りません）: ${unmapped.join('、')}`);
  }

  const retrieve = readRetrieve(o.retrieveJson, types, typeToFolder, warnings);
  if (retrieve.status !== 0) fail('取得の応答の status が 0 以外です（S1）: ' + retrieve.status);

  const ignored = loadIgnore(o.repo, warnings);
  const recent = new Set(o.recentFiles && fs.existsSync(o.recentFiles) ? readLines0(o.recentFiles) : []);

  const rows = [];      // {op, p, reason}
  const delByFolder = new Map();
  let localTotal = 0;
  const folders = [...managed].sort();
  for (const f of folders) {
    const A = walk(path.join(repoRoot, f)), B = walk(path.join(fetchedRoot, f));
    const setA = new Set(A), setB = new Set(B);
    const isKeep = rel => path.posix.basename(rel) === '.gitkeep' || ignored(root + '/' + f + '/' + rel);
    localTotal += A.filter(x => !isKeep(x)).length;
    const dels = [];
    for (const rel of B) {
      const p = root + '/' + f + '/' + rel;
      if (!setA.has(rel)) rows.push({ op: 'A', p, reason: '' });
      else if (!sameContent(path.join(repoRoot, f, rel), path.join(fetchedRoot, f, rel))) rows.push({ op: 'M', p, reason: '' });
    }
    for (const rel of A) {
      if (setB.has(rel) || isKeep(rel)) continue;
      dels.push(root + '/' + f + '/' + rel);
    }
    delByFolder.set(f, { dels, fetchedCount: B.length, localKept: A.filter(x => !isKeep(x)).length });
  }

  // 削除の守り
  const held = (p, reason) => rows.push({ op: 'H', p, reason });
  let pending = [];
  for (const f of folders) {
    const d = delByFolder.get(f);
    for (const p of d.dels) {
      if (retrieve.holdAll || retrieve.holdFolders.has(f)) held(p, 'S2');
      else if (!o.allowMass && d.localKept >= 1 && d.fetchedCount === 0) held(p, 'S3');
      else if (recent.has(p)) held(p, 'S5');
      else pending.push(p);
    }
  }
  const limit = Math.max(MASS_MIN, Math.floor(localTotal * MASS_RATIO));
  if (!o.allowMass && pending.length > limit) {
    for (const p of pending) held(p, 'S4');
    pending = [];
  }
  for (const p of pending) rows.push({ op: 'D', p, reason: '' });

  rows.sort((a, b) => (a.p < b.p ? -1 : a.p > b.p ? 1 : 0));
  fs.writeFileSync(o.out, rows.map(r => r.op + '\t' + r.p + '\t' + r.reason).join('\n') + (rows.length ? '\n' : ''));

  // 要約
  const cnt = op => rows.filter(r => r.op === op).length;
  const out = [];
  out.push(`計画: 追加 ${cnt('A')} 件 / 変更 ${cnt('M')} 件 / 削除 ${cnt('D')} 件 / 削除の保留 ${cnt('H')} 件`);
  out.push(`  （同期の対象のフォルダ ${folders.length} 個 / 手元の対象のファイル ${localTotal} 件 / 大量削除のしきい値 ${limit} 件）`);
  const dl = rows.filter(r => r.op === 'D');
  if (dl.length) {
    out.push(`削除（先頭 ${Math.min(LIST_MAX, dl.length)} 件 / 全 ${dl.length} 件）:`);
    for (const r of dl.slice(0, LIST_MAX)) out.push('  - ' + r.p);
  }
  const hl = rows.filter(r => r.op === 'H');
  if (hl.length) {
    const by = {};
    for (const r of hl) by[r.reason] = (by[r.reason] || 0) + 1;
    const why = { S2: '取得の応答に問題の報告がある', S3: '手元にあったフォルダが、取得結果で 0 件', S4: '削除が多い', S5: '直近にマージされたファイル' };
    out.push('削除の保留（ファイルは残す）:');
    for (const k of Object.keys(by).sort()) out.push(`  - ${k} ${why[k]}: ${by[k]} 件`);
    for (const r of hl.slice(0, LIST_MAX)) out.push(`    ${r.reason} ${r.p}`);
  }
  if (retrieve.unavailable.length) {
    out.push(`この組織・この API バージョンでは使えない種類が ${retrieve.unavailable.length} 個あります（取得されません）: ${retrieve.unavailable.join('、')}`);
  }
  for (const n of retrieve.notes.slice(0, 10)) out.push('取得の応答の問題: ' + n);
  for (const w of warnings) out.push('[WARNING] ' + w);
  process.stdout.write(out.join('\n') + '\n');
  process.exitCode = hl.some(r => r.reason !== 'S5') ? 3 : 0;   // process.exit は使わない（Windows のパイプで、出力が欠けないように）
}

function readLines0(file) {   // 行の前後の空白は残さず、# の行も含めて、すべて読む（パスの一覧用）
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
}

// ---- apply ----
function apply(o) {
  const root = packageRoot(o.repo);
  const repoRoot = path.resolve(o.repo, root), fetchedRoot = path.resolve(o.fetched, root);
  const rows = fs.readFileSync(o.plan, 'utf8').split('\n').filter(Boolean).map(l => l.split('\t'));
  const inside = (base, rel) => {
    const abs = path.resolve(o.repo, rel);
    return abs === base || abs.startsWith(base + path.sep) ? abs : null;
  };
  for (const [op, p] of rows) {      // 先に、すべてのパスを確かめる（途中で中断して、半端に反映しない）
    if (!['A', 'M', 'D', 'H'].includes(op) || !p) fail('計画の形式が正しくありません: ' + op + ' ' + p);
    if (!inside(repoRoot, p)) fail('計画のパスが、同期の対象の外を指しています: ' + p);
  }
  let a = 0, m = 0, d = 0;
  for (const [op, p] of rows) {
    const dst = inside(repoRoot, p);
    const rel = p.slice(root.length + 1);
    if (op === 'A' || op === 'M') {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.copyFileSync(path.join(fetchedRoot, rel), dst);
      if (op === 'A') a++; else m++;
    } else if (op === 'D') {
      fs.rmSync(dst, { force: true });
      d++;
      for (let dir = path.dirname(dst); dir !== repoRoot && dir.startsWith(repoRoot + path.sep); dir = path.dirname(dir)) {
        if (fs.readdirSync(dir).length) break;
        fs.rmdirSync(dir);
      }
    }
  }
  process.stdout.write(`反映: 追加 ${a} 件 / 変更 ${m} 件 / 削除 ${d} 件\n`);
}

// ---- root: sfdx-project.json の packageDirectories の path を出す（S8 の確認を兼ねる。シェルが、一時プロジェクトと git add に使う）----
function rootCmd(o) {
  packageRoot(o.repo);   // 1 つでなければ、ここで中断する
  const j = JSON.parse(fs.readFileSync(path.join(o.repo, 'sfdx-project.json'), 'utf8'));
  process.stdout.write(j.packageDirectories[0].path.replace(/\\/g, '/').replace(/\/+$/, '') + '\n');
}

// ---- detect: 変更の検知（設計 15 章）----
const SKEW_MIN = 10;          // 履歴の問い合わせの基準を、前回の開始時刻より前にずらす分（時計のずれと、記録の遅れの分）
const SF_MAX_PARALLEL = 4;    // sf の同時実行の上限
// フォルダ型の種類 → フォルダの種類。フォルダごとに問い合わせる
const FOLDER_TYPE = { Report: 'ReportFolder', Dashboard: 'DashboardFolder', Document: 'DocumentFolder', EmailTemplate: 'EmailFolder' };
const UNFILED = { Report: 'unfiled$public', EmailTemplate: 'unfiled$public' };   // フォルダに入っていない部品の置き場所

const sha = s => crypto.createHash('sha1').update(s).digest('hex').slice(0, 16);
const isoSec = d => d.toISOString().replace(/\.\d+Z$/, 'Z');
const sq = a => {   // sf の引数を、シェルを通して渡すための引用（名前に $ や空白を含むため）
  const s = String(a);
  return process.platform === 'win32' ? '"' + s.replace(/"/g, '\\"') + '"' : "'" + s.replace(/'/g, "'\\''") + "'";
};

let sfActive = 0;
const sfWaiters = [];
async function sfAcquire() { if (sfActive < SF_MAX_PARALLEL) { sfActive++; return; } await new Promise(r => sfWaiters.push(r)); }
function sfRelease() { const w = sfWaiters.shift(); if (w) w(); else sfActive--; }

// sf を実行して、応答（JSON）を返す。失敗（終了コード・status・JSON でない）は、例外
async function sfJson(args) {
  await sfAcquire();
  try {
    const cmd = (process.env.SF_METASYNC_SF || 'sf') + ' ' + args.concat('--json').map(sq).join(' ');
    return await new Promise((resolve, reject) => {
      cp.exec(cmd, { maxBuffer: 1 << 26, timeout: 180000 }, (err, stdout, stderr) => {
        let j;
        try { j = JSON.parse(stdout.slice(stdout.indexOf('{'))); } catch (e) { return reject(new Error('sf の応答を読めません: ' + args.slice(0, 4).join(' '))); }
        if (err || j.status !== 0) return reject(new Error('sf が失敗しました: ' + args.slice(0, 4).join(' ') + ' (' + String(j.message || stderr || '').replace(/\s+/g, ' ').slice(0, 100) + ')'));
        resolve(j);
      });
    });
  } finally { sfRelease(); }
}

async function listMeta(org, type, folder) {
  const a = ['org', 'list', 'metadata', '--metadata-type', type, '--target-org', org];
  if (folder) a.push('--folder', folder);
  const r = (await sfJson(a)).result;
  return Array.isArray(r) ? r : r ? [r] : [];
}

// 種類ごとの「最新の更新日時・件数・名前のハッシュ」。フォルダ型は、フォルダ自身と、フォルダの中の部品を合わせる
async function snapshotType(org, type) {
  let entries;
  if (FOLDER_TYPE[type]) {
    const folders = await listMeta(org, FOLDER_TYPE[type]);
    const names = folders.map(e => e.fullName);
    if (UNFILED[type]) names.push(UNFILED[type]);
    const parts = await Promise.all(names.map(f => listMeta(org, type, f)));
    entries = folders.concat(...parts);
  } else entries = await listMeta(org, type);
  const names = entries.map(e => String(e.fullName)).sort();
  const newest = entries.map(e => String(e.lastModifiedDate || '')).sort().pop() || '';
  return { newest, count: entries.length, hash: sha(names.join('\n')) };
}

async function detect(o) {
  const out = [];
  const finish = (code) => { process.stdout.write(out.join('\n') + '\n'); process.exitCode = code; };
  const types = readLines(o.typesFile);
  const table = new Map();
  for (const l of readLines(o.table)) {
    const p = l.replace(/\s+#.*$/, '').split(/\s+/);
    if (p.length >= 2 && (p[0] === 'A' || p[0] === 'B')) table.set(p[1], p[0]);
  }
  const aTypes = types.filter(t => table.get(t) === 'A'), bTypes = types.filter(t => table.get(t) === 'B');
  const cCount = types.length - aTypes.length - bTypes.length;
  const configHash = sha([...aTypes].sort().join(',') + '|' + [...bTypes].sort().join(',') + '|' + types.slice().sort().join(','));
  const now = o.now ? new Date(o.now) : new Date();
  if (isNaN(now.getTime())) fail('--now が日時として読めません: ' + o.now);
  out.push(`検知: A ${aTypes.length} 種類（履歴）/ B ${bTypes.length} 種類（更新日時の一覧）/ C ${cCount} 種類（毎日の全件取得でだけ反映）`);

  // 前回の状態（読めない・版や設定が違う = 使えない）
  let state = null, stateWhy = '';
  if (!fs.existsSync(o.state)) stateWhy = '前回の状態がありません';
  else {
    try {
      const s = JSON.parse(fs.readFileSync(o.state, 'utf8'));
      if (s && s.version === 1 && s.configHash === configHash && s.types && typeof s.types === 'object' && !isNaN(Date.parse(s.lastFullSyncAt))) state = s;
      else stateWhy = '前回の状態の版または設定が、今回と合いません';
    } catch (e) { stateWhy = '前回の状態を読めません'; }
  }

  // 区分 B の一覧。失敗したら、状態も書かずに、不明で終える
  const snap = {};
  try { await Promise.all(bTypes.map(async t => { snap[t] = await snapshotType(o.org, t); })); } catch (e) {
    out.push('不明: 更新日時の一覧を取得できませんでした: ' + e.message);
    return finish(11);
  }
  const next = { version: 1, configHash, lastFullSyncAt: isoSec(now), types: snap };
  const save = () => fs.writeFileSync(o.outState, JSON.stringify(next, null, 2) + '\n');

  if (!state) { out.push('不明: ' + stateWhy + '（全件取得で、状態を作ります）'); save(); return finish(11); }

  const reasons = [];
  for (const t of bTypes) {
    const a = state.types[t], b = snap[t];
    if (!a) reasons.push(`${t}: 前回の記録がありません`);
    else if (a.count !== b.count) reasons.push(`${t}: 件数が変わりました（${a.count} → ${b.count}）`);
    else if (a.hash !== b.hash) reasons.push(`${t}: 名前が変わりました`);
    else if (a.newest !== b.newest) reasons.push(`${t}: 更新日時が変わりました`);
  }
  if (aTypes.length) {
    const since = isoSec(new Date(Date.parse(state.lastFullSyncAt) - SKEW_MIN * 60000));
    try {
      const q = await sfJson(['data', 'query', '--query', `SELECT COUNT() FROM SetupAuditTrail WHERE CreatedDate > ${since}`, '--target-org', o.org]);
      const n = Number((q.result || {}).totalSize);
      if (!Number.isFinite(n)) throw new Error('履歴の件数を読めません');
      if (n > 0) reasons.push(`設定変更の履歴に ${n} 件の記録があります（${since} より後）`);
    } catch (e) {
      out.push('不明: 履歴の問い合わせに失敗しました: ' + e.message);
      save();
      return finish(11);
    }
  }
  if (reasons.length) { out.push('変更あり:'); for (const r of reasons.slice(0, 20)) out.push('  - ' + r); save(); return finish(10); }
  out.push('変更なし（区分 A の履歴・区分 B の一覧とも、前回から変わっていません）');
  return finish(0);
}

const o = parseArgs(process.argv.slice(2));
if (o.cmd === 'plan') plan(o);
else if (o.cmd === 'root') rootCmd(o);
else if (o.cmd === 'detect') detect(o).catch(e => { process.stderr.write('[ERROR] ' + e.message + '\n'); process.exitCode = 11; });
else apply(o);
