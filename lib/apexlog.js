'use strict';
// ==============================================================================
// apexlog.js - Apex ログの一覧の検査・AI 向けの要約・日時の計算（bin/sf-log.sh から呼ぶ）
// ==============================================================================
// Node の標準ライブラリだけを使う（追加パッケージなし。sf CLI が npm 版のため、Node は前提）。
// 境界は、この 1 ファイルだけ。シェル側（bin/sf-log.sh）が、組織への問い合わせ・手元の状態・ファイルの保存・終了コードを受け持つ。
// 設計: doc/sf-log-design.md（6 章 要約・8.3 一覧・6.4 実装の言語）
//
// 【使い方】
//   node lib/apexlog.js summarize --list F [--now ISO] [--note TEXT]... [--base DIR] [--local-offset MIN]
//                                       # 要約（Markdown）を標準出力に書く（6 章）
//   node lib/apexlog.js list --user ID  # 標準入力の ApexLog の一覧（sf data query --json の応答）を検査し、表（TSV）にする（8.3）
//   node lib/apexlog.js time now [--plus-sec N]   # 今（UTC。YYYY-MM-DDTHH:MM:SSZ）。N 秒後も出せる
//   node lib/apexlog.js time norm ISO             # 日時を YYYY-MM-DDTHH:MM:SSZ（UTC）に直す（Salesforce の …000+0000 も読む）
//   node lib/apexlog.js time cmp A B              # A < B なら -1、同じなら 0、A > B なら 1
//   node lib/apexlog.js time min A B              # 早いほう（YYYY-MM-DDTHH:MM:SSZ）
//   node lib/apexlog.js time add ISO --sec N      # ISO の N 秒後（N は負でもよい）
//
// 【オプション】
//   --list F    : （summarize）要約に入れるログの一覧（TSV。1 行に 1 本。古い順）。列:
//                   1 ファイルのパス（要約に、そのまま書く）・2 ログの ID・3 開始時刻（UTC。YYYY-MM-DDTHH:MM:SSZ）・
//                   4 操作（Operation）・5 状態（Status）・6 長さ（バイト）・7 所要（ミリ秒）
//   --now ISO   : （summarize）作成時刻（UTC。テスト用。省略時は今）
//   --note TEXT : （summarize）要約の先頭に書く注意（取得役の状態・入れなかったログ・取り込みの残りなど。何度でも）
//   --base DIR  : （summarize）一覧のパスが相対のとき、ファイルを読む基準のフォルダ（省略時は今のフォルダ）
//   --local-offset MIN : （summarize）作成時刻・ログの開始時刻を表示する時差（分。-720〜840。例: 540 = 日本時間）。
//                 省略時は PC のタイムゾーン。テスト用（どの OS でも同じ表示にするため。環境変数 TZ は、Windows の Node で効かないことがある）
//   --user ID   : （list）自分のユーザー ID（英数字 15 か 18 文字）
//   --plus-sec N・--sec N : （time）秒数（整数）
//
// 【処理の流れ】（summarize）
//   1. 一覧の各行を検査する（列の数・ID・日時・数値の形）。形が違えば、終了コード 1（要約を作らない）
//   2. ログを 1 本ずつ読む。行の形（doc/sf-log-design.md 6.3）:
//        1 行目 = API の版と詳しさ。`Execute Anonymous: ` の行は、匿名 Apex のコード（飛ばす）
//        `<時刻> (<ナノ秒>)|<種類>[|<項目>…]` = イベント。時刻で始まらない行は、直前のイベントの続き（複数行のイベント）
//        最初のイベントより前の、上のどれでもない行 = 読み取れなかった行（推測で読まない）
//      ファイルがない・読めない → そのログを「読めなかったログ」に入れて、続ける
//   3. 区分ごとに集める: エラー（EXCEPTION_THROWN・FATAL_ERROR・FLOW_ELEMENT_ERROR）・入力規則（VALIDATION_FAIL・VALIDATION_ERROR。
//      直前の VALIDATION_RULE の名前を添える）・デバッグ出力（USER_DEBUG）・流れ（CODE_UNIT_STARTED / FINISHED）・
//      制限（LIMIT_USAGE_FOR_NS の (default) の「Number of … : a out of b」）・件数（SOQL_EXECUTE_BEGIN・DML_BEGIN）
//   4. Markdown を組み立てる（エラーが先・正常な情報が後。6.1・6.2）:
//        見出し（作成時刻・本数・エラーの数）→ 注意（--note・読めなかったログ・読み取れなかった行・切り詰め・タイムゾーン不明）→
//        1 エラー（フローのエラーを含む。同じ種類と文言は 1 つにまとめ、件数を書く）→ 2 ログの一覧 → 3 System.debug（新しい順・最大 50 件）→
//        4 入力規則のエラー → 5 制限の使用量（50% を超えたもの）→ 6 切り詰め・出なかった区分・読み取れなかった行
//   5. 各区分の件数に上限を付け、超えた分は件数だけを書く（全体の目安は 200 行）
//
// 【補足】
//   - 行の時刻は、ログのユーザーのタイムゾーン（6.3）。表示するだけで、UTC に直さない。USER_INFO の行がない・読めないログは、
//     「タイムゾーン不明」と添える。ログの開始時刻は、一覧の開始時刻（UTC）を、PC のタイムゾーンで表示する
//   - 本文への参照は `<ファイルのパス>:<行番号>`（行番号は 1 から）
//   - 20MB（20,971,520 バイト）以上のログは、Salesforce が古い行から削っている（8.6）。「切り詰めあり」と書く
//   - list は、応答の内容を、標準出力の表にだけ書く（ファイル・記録に残さない。他の人のログの見出しを含むため。10.3）。
//     表の列: ID・自分か（1 / 0）・開始時刻（UTC）・長さ・所要・操作・状態。応答の形が違えば、終了コード 1（推測で進めない）
// ==============================================================================

const fs = require('fs');
const path = require('path');

// ------------------------------------------------------------------------------
// 共通
// ------------------------------------------------------------------------------
const ID_RE = /^[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?$/;
const ISO_Z_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const TRUNCATE_BYTES = 20 * 1024 * 1024;

function fail(msg) {
    process.stderr.write(`apexlog.js: ${msg}\n`);
    process.exit(1);
}

// 引数を読む。値を取るオプションは、繰り返してよい（--note）
function parseArgs(argv) {
    const opts = { _: [], note: [] };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith('--')) {
            const k = a.slice(2);
            if (i + 1 >= argv.length) fail(`${a} の値がありません。`);
            const v = argv[++i];
            if (k === 'note') opts.note.push(v);
            else opts[k] = v;
        } else {
            opts._.push(a);
        }
    }
    return opts;
}

// 日時を読む（UTC のミリ秒）。YYYY-MM-DDTHH:MM:SS[.sss](Z|+HHMM|+HH:MM) だけを受け付ける。
//   Salesforce は「…000+0000」（コロンなし）で返す。JavaScript の標準の形ではないため、Date.parse に頼らない
function parseTime(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})$/.exec(String(s));
    if (!m) return null;
    const [, y, mo, d, h, mi, se, , tz] = m;
    let ms = Date.UTC(+y, +mo - 1, +d, +h, +mi, +se);
    if (Number.isNaN(ms)) return null;
    // 日付として正しいか（2 月 30 日などを弾く）
    const chk = new Date(ms);
    if (chk.getUTCFullYear() !== +y || chk.getUTCMonth() !== +mo - 1 || chk.getUTCDate() !== +d) return null;
    if (tz !== 'Z') {
        const t = tz.replace(':', '');
        const sign = t[0] === '-' ? -1 : 1;
        const off = (+t.slice(1, 3)) * 60 + (+t.slice(3, 5));
        ms -= sign * off * 60 * 1000;
    }
    return ms;
}

// UTC のミリ秒 → YYYY-MM-DDTHH:MM:SSZ（ミリ秒は切り捨て）
function fmtZ(ms) {
    return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// 表示の時差（分）。null = PC のタイムゾーン。summarize の --local-offset で決める（テスト用）
let LOCAL_OFFSET_MIN = null;

// PC のタイムゾーン（--local-offset があれば、その時差）での表示（YYYY-MM-DD HH:MM:SS）
//   テストで TZ を使わないのは、GitHub Actions の Windows で、Node が環境変数 TZ を効かせなかったため（2026-11-23。手元の WSL では効いた）
function fmtLocal(ms) {
    const p = n => String(n).padStart(2, '0');
    if (LOCAL_OFFSET_MIN !== null) {
        const d = new Date(ms + LOCAL_OFFSET_MIN * 60 * 1000);
        return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`;
    }
    const d = new Date(ms);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function needInt(v, name) {
    if (v === undefined || !/^-?\d+$/.test(String(v))) fail(`${name} は整数で指定してください: ${v}`);
    return parseInt(v, 10);
}

// 表の 1 つのマスに入れる文字（改行・タブ・| を除く）
function cell(s) {
    return String(s == null ? '' : s).replace(/[\r\n\t]+/g, ' ').replace(/\|/g, '｜').trim();
}

function sizeText(n) {
    if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)}MB`;
    if (n >= 1024) return `${(n / 1024).toFixed(1)}KB`;
    return `${n}B`;
}

// ------------------------------------------------------------------------------
// time
// ------------------------------------------------------------------------------
function cmdTime(opts) {
    const [sub, a, b] = opts._.slice(1);
    const need = (s) => { const t = parseTime(s); if (t === null) fail(`日時の形が正しくありません: ${s}`); return t; };
    switch (sub) {
        case 'now': {
            const plus = opts['plus-sec'] === undefined ? 0 : needInt(opts['plus-sec'], '--plus-sec');
            process.stdout.write(fmtZ(Date.now() + plus * 1000) + '\n');
            break;
        }
        case 'norm':
            process.stdout.write(fmtZ(need(a)) + '\n');
            break;
        case 'cmp': {
            const x = need(a), y = need(b);
            process.stdout.write((x < y ? '-1' : x > y ? '1' : '0') + '\n');
            break;
        }
        case 'min': {
            const x = need(a), y = need(b);
            process.stdout.write(fmtZ(Math.min(x, y)) + '\n');
            break;
        }
        case 'add': {
            const x = need(a);
            const sec = needInt(opts.sec, '--sec');
            process.stdout.write(fmtZ(x + sec * 1000) + '\n');
            break;
        }
        default:
            fail(`time のサブコマンドが正しくありません: ${sub || '(なし)'}`);
    }
}

// ------------------------------------------------------------------------------
// list（8.3）: 標準入力の sf data query --json の応答を検査し、TSV にする
// ------------------------------------------------------------------------------
function cmdList(opts) {
    const user = opts.user;
    if (!user || !ID_RE.test(user)) fail('--user に、ユーザー ID（英数字 15 か 18 文字）を指定してください。');
    let s = '';
    try { s = fs.readFileSync(0, 'utf8'); } catch (e) { fail('標準入力を読めません。'); }
    let o;
    try { o = JSON.parse(s); }
    catch (e) {
        // sf の更新のお知らせなどが前に付いたときのため、最初の { から最後の } までを読む（lib/common.sh の json_get と同じ）
        try { o = JSON.parse(s.slice(s.indexOf('{'), s.lastIndexOf('}') + 1)); }
        catch (e2) { fail('応答が JSON ではありません。'); }
    }
    // 応答の中身（他の人のログの見出し）は、エラーの文言に入れない
    if (!o || o.status !== 0 || !o.result) fail('応答の status が 0 ではありません。');
    const recs = o.result.records;
    if (!Array.isArray(recs)) fail('応答の result.records が配列ではありません。');
    const me = user.slice(0, 15);
    const out = [];
    recs.forEach((r, i) => {
        if (!r || typeof r !== 'object') fail(`${i + 1} 件目の形が正しくありません。`);
        if (typeof r.Id !== 'string' || !ID_RE.test(r.Id)) fail(`${i + 1} 件目の Id の形が正しくありません。`);
        if (typeof r.LogUserId !== 'string' || !ID_RE.test(r.LogUserId)) fail(`${i + 1} 件目の LogUserId の形が正しくありません。`);
        const t = parseTime(r.StartTime);
        if (t === null) fail(`${i + 1} 件目の StartTime の形が正しくありません。`);
        const len = Number.isInteger(r.LogLength) && r.LogLength >= 0 ? r.LogLength : null;
        if (len === null) fail(`${i + 1} 件目の LogLength の形が正しくありません。`);
        const dur = Number.isInteger(r.DurationMilliseconds) && r.DurationMilliseconds >= 0 ? r.DurationMilliseconds : 0;
        const mine = r.LogUserId.slice(0, 15) === me ? '1' : '0';
        out.push([r.Id, mine, fmtZ(t), len, dur, cell(r.Operation), cell(r.Status)].join('\t'));
    });
    process.stdout.write(out.length ? out.join('\n') + '\n' : '');
}

// ------------------------------------------------------------------------------
// summarize（6 章）
// ------------------------------------------------------------------------------
const EVENT_RE = /^(\d{1,2}:\d{2}:\d{2}\.\d+) \((\d+)\)\|([A-Z][A-Z0-9_]*)(?:\|(.*))?$/;
const ERROR_TYPES = new Set(['EXCEPTION_THROWN', 'FATAL_ERROR', 'FLOW_ELEMENT_ERROR']);
const VALIDATION_TYPES = new Set(['VALIDATION_FAIL', 'VALIDATION_ERROR']);
const CATEGORIES = [
    ['エラー', ['EXCEPTION_THROWN', 'FATAL_ERROR', 'FLOW_ELEMENT_ERROR']],
    ['入力規則', ['VALIDATION_FAIL', 'VALIDATION_RULE', 'VALIDATION_ERROR']],
    ['デバッグ出力', ['USER_DEBUG']],
    ['流れ', ['CODE_UNIT_STARTED', 'CODE_UNIT_FINISHED']],
    ['制限', ['LIMIT_USAGE_FOR_NS', 'CUMULATIVE_LIMIT_USAGE']],
    ['件数', ['SOQL_EXECUTE_BEGIN', 'DML_BEGIN']],
];
const MAX = { errors: 30, debug: 50, validation: 20, limits: 20, unreadable: 10, logs: 100 };

// 一覧（TSV）を読む
function readList(file) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch (e) { fail(`一覧を読めません: ${file}`); }
    const rows = [];
    text.split(/\r?\n/).forEach((line, i) => {
        if (line === '') return;
        const c = line.split('\t');
        const where = `一覧の ${i + 1} 行目`;
        if (c.length !== 7) fail(`${where}: 列の数が 7 ではありません。`);
        const [p, id, st, op, status, len, dur] = c;
        if (p === '') fail(`${where}: ファイルのパスが空です。`);
        if (!ID_RE.test(id)) fail(`${where}: ID の形が正しくありません。`);
        if (!ISO_Z_RE.test(st) || parseTime(st) === null) fail(`${where}: 開始時刻の形が正しくありません。`);
        if (!/^\d+$/.test(len)) fail(`${where}: 長さが整数ではありません。`);
        if (!/^\d+$/.test(dur)) fail(`${where}: 所要が整数ではありません。`);
        rows.push({ path: p, id, start: parseTime(st), op, status, len: parseInt(len, 10), dur: parseInt(dur, 10) });
    });
    return rows;
}

// 1 本のログを読む
function parseLog(text) {
    const lines = text.split(/\r?\n/);
    if (lines.length && lines[lines.length - 1] === '') lines.pop();
    const events = [];
    const unreadable = [];
    let tzKnown = false;
    let cur = null;
    lines.forEach((line, idx) => {
        const no = idx + 1;
        if (no === 1 && /^\d+\.\d+ /.test(line)) return;              // API の版と詳しさ
        if (line.startsWith('Execute Anonymous: ')) return;            // 匿名 Apex のコード
        const m = EVENT_RE.exec(line);
        if (m) {
            cur = { line: no, time: m[1], type: m[3], fields: m[4] === undefined ? [] : m[4].split('|'), more: [] };
            events.push(cur);
            if (cur.type === 'USER_INFO' && cur.fields.some(f => /\([A-Za-z_]+\/[A-Za-z_]+\)/.test(f) || /^GMT[+-]\d{2}:\d{2}$/.test(f))) tzKnown = true;
            return;
        }
        if (cur) { cur.more.push(line); return; }                       // 直前のイベントの続き
        if (line.trim() !== '') unreadable.push(no);                    // 最初のイベントより前の、知らない形の行
    });
    return { events, unreadable, tzKnown };
}

// 行の中の位置（[42] など）
function lineRef(f) {
    const m = /^\[(\d+)\]$/.exec(f || '');
    return m ? `行 ${m[1]}` : '';
}

function analyze(row, base) {
    const file = path.isAbsolute(row.path) ? row.path : path.join(base, row.path);
    let text;
    try { text = fs.readFileSync(file, 'utf8'); }
    catch (e) { return { row, missing: true }; }
    const { events, unreadable, tzKnown } = parseLog(text);
    const res = {
        row, missing: false, unreadable, tzKnown, errors: [], debug: [], validation: [], limits: [],
        soql: null, dml: null, firstUnit: '', counts: {},
    };
    const stack = [];
    let lastRule = '';
    events.forEach(ev => {
        res.counts[ev.type] = (res.counts[ev.type] || 0) + 1;
        const ref = `${row.path}:${ev.line}`;
        switch (ev.type) {
            case 'CODE_UNIT_STARTED': {
                const name = ev.fields[ev.fields.length - 1] || '';
                if (!res.firstUnit) res.firstUnit = name;
                stack.push(name);
                break;
            }
            case 'CODE_UNIT_FINISHED':
                stack.pop();
                break;
            case 'USER_DEBUG': {
                const msg = ev.fields.slice(2).join('|');
                res.debug.push({ ref, time: ev.time, where: lineRef(ev.fields[0]), level: ev.fields[1] || '', msg, more: ev.more.length });
                break;
            }
            case 'VALIDATION_RULE':
                lastRule = ev.fields[ev.fields.length - 1] || '';
                break;
            case 'LIMIT_USAGE_FOR_NS': {
                if (ev.fields[0] !== '(default)') break;
                ev.more.forEach(l => {
                    const m = /^\s*(.+?):\s*(\d+)\s+out of\s+(\d+)\s*$/.exec(l);
                    if (!m) return;
                    const used = +m[2], max = +m[3];
                    if (m[1] === 'Number of SOQL queries') res.soql = `${used}/${max}`;
                    if (m[1] === 'Number of DML statements') res.dml = `${used}/${max}`;
                    if (max > 0 && used / max > 0.5) res.limits.push({ ref, name: m[1], used, max });
                });
                break;
            }
            default:
                break;
        }
        if (ERROR_TYPES.has(ev.type)) {
            let msg, where;
            if (ev.type === 'FATAL_ERROR') {
                msg = ev.fields.join('|');
                where = ev.more.map(s => s.trim()).find(s => s !== '') || '';
            } else if (ev.type === 'EXCEPTION_THROWN') {
                msg = ev.fields.slice(1).join('|');
                where = lineRef(ev.fields[0]);
            } else {
                msg = ev.fields.join(' / ');
                where = '';
            }
            res.errors.push({ ref, type: ev.type, msg, where, unit: stack[stack.length - 1] || '' });
        }
        if (VALIDATION_TYPES.has(ev.type)) {
            res.validation.push({ ref, type: ev.type, msg: ev.fields.join(' / '), rule: lastRule });
        }
    });
    return res;
}

function cmdSummarize(opts) {
    if (!opts.list) fail('--list を指定してください。');
    const now = opts.now === undefined ? Date.now() : parseTime(opts.now);
    if (now === null) fail(`--now の形が正しくありません: ${opts.now}`);
    if (opts['local-offset'] !== undefined) {
        const off = needInt(opts['local-offset'], '--local-offset');
        if (off < -720 || off > 840) fail(`--local-offset は -720〜840（分）で指定してください: ${off}`);
        LOCAL_OFFSET_MIN = off;
    }
    const base = opts.base || process.cwd();
    const rows = readList(opts.list);
    const results = rows.map(r => analyze(r, base));
    const ok = results.filter(r => !r.missing);
    const missing = results.filter(r => r.missing);

    // エラーを、種類と文言でまとめる（最初に出た場所を残す）
    const errMap = new Map();
    ok.forEach(r => r.errors.forEach(e => {
        const k = `${e.type}\u0000${e.msg}`;
        if (errMap.has(k)) errMap.get(k).count++;
        else errMap.set(k, Object.assign({ count: 1 }, e));
    }));
    const errors = [...errMap.values()];
    const errorTotal = ok.reduce((n, r) => n + r.errors.length, 0);

    const out = [];
    out.push(`# Apex ログの要約（${fmtLocal(now)} 作成・${rows.length} 本・エラー ${errorTotal}）`);
    out.push('');

    // 注意（取れていないものを隠さない。6.1）
    const notes = opts.note.slice();
    if (missing.length) notes.push(`読めなかったログ: ${missing.length} 本（${missing.slice(0, 5).map(r => r.row.path).join('、')}${missing.length > 5 ? ' ほか' : ''}）`);
    const unread = ok.filter(r => r.unreadable.length);
    if (unread.length) notes.push(`読み取れなかった行: ${unread.reduce((n, r) => n + r.unreadable.length, 0)} 行（想定と違う形。推測で読んでいません。下の 6）`);
    const trunc = ok.filter(r => r.row.len >= TRUNCATE_BYTES);
    if (trunc.length) notes.push(`20MB で切り詰められたログ: ${trunc.length} 本（古い行が削られています。下の 6）`);
    const noTz = ok.filter(r => !r.tzKnown);
    if (noTz.length) notes.push(`タイムゾーン不明のログ: ${noTz.length} 本（USER_INFO の行がありません。行の時刻は、ログのまま）`);
    if (rows.length === 0) notes.push('対象のログはありません。');
    notes.forEach(n => out.push(`> ${cell(n)}`));
    if (notes.length) out.push('');

    // 1. エラー
    out.push('## 1. エラー');
    if (errors.length === 0) {
        out.push('- なし（エラーの行は、ありませんでした。出なかった区分は、下の 6 を見てください）');
    } else {
        errors.slice(0, MAX.errors).forEach(e => {
            out.push(`- [${e.ref}] ${e.type} ${cell(e.msg)}${e.count > 1 ? `（同じものが ${e.count} 件）` : ''}`);
            // 場所: 行（例外の行・スタックトレースの 1 行目）と、そのとき動いていた CODE_UNIT（入れ子のいちばん内側）
            const unit = e.unit ? `直前の CODE_UNIT: ${cell(e.unit)}` : '';
            const loc = e.where && unit ? `${cell(e.where)}（${unit}）` : (cell(e.where) || unit);
            if (loc) out.push(`  - 場所: ${loc}`);
        });
        if (errors.length > MAX.errors) out.push(`- ほか ${errors.length - MAX.errors} 種類（省略）`);
    }
    out.push('');

    // 2. ログの一覧
    out.push('## 2. ログの一覧');
    out.push('| 開始 | 操作 | 状態 | 長さ | 所要 | SOQL | DML | ファイル |');
    out.push('|---|---|---|---|---|---|---|---|');
    const listed = results.slice(-MAX.logs);
    listed.forEach(r => {
        const op = cell(r.row.op) + (r.firstUnit ? `（${cell(r.firstUnit)}）` : '');
        out.push(`| ${fmtLocal(r.row.start)} | ${op} | ${cell(r.row.status)} | ${sizeText(r.row.len)} | ${r.row.dur}ms | ${r.soql || '-'} | ${r.dml || '-'} | ${r.row.path}${r.missing ? '（読めません）' : ''} |`);
    });
    if (results.length > MAX.logs) out.push(`| … | ほか ${results.length - MAX.logs} 本（古いもの。省略） | | | | | | |`);
    out.push('');

    // 3. System.debug（新しい順）
    out.push('## 3. System.debug の出力（新しい順・最大 50 件）');
    const debug = [];
    ok.forEach(r => r.debug.forEach(d => debug.push(d)));
    debug.reverse();
    if (debug.length === 0) out.push('- なし');
    debug.slice(0, MAX.debug).forEach(d => {
        out.push(`- [${d.ref}] ${d.time} ${d.level}${d.where ? ` ${d.where}` : ''}: ${cell(d.msg)}${d.more ? `（続き ${d.more} 行は本文を見てください）` : ''}`);
    });
    if (debug.length > MAX.debug) out.push(`- ほか ${debug.length - MAX.debug} 件（古いもの。省略）`);
    out.push('');

    // 4. 入力規則・フローのエラー
    out.push('## 4. 入力規則のエラー');
    const val = [];
    ok.forEach(r => r.validation.forEach(v => val.push(v)));
    if (val.length === 0) out.push('- なし');
    val.slice(0, MAX.validation).forEach(v => {
        out.push(`- [${v.ref}] ${v.type}${v.msg ? ` ${cell(v.msg)}` : ''}${v.rule ? `（規則: ${cell(v.rule)}）` : ''}`);
    });
    if (val.length > MAX.validation) out.push(`- ほか ${val.length - MAX.validation} 件（省略）`);
    out.push('- フローのエラー（FLOW_ELEMENT_ERROR）は、上の 1 に入れています');
    out.push('');

    // 5. 制限の使用量
    out.push('## 5. 制限の使用量（上限の 50% を超えたものだけ）');
    const lim = [];
    ok.forEach(r => r.limits.forEach(l => lim.push(l)));
    if (lim.length === 0) out.push('- なし');
    lim.slice(0, MAX.limits).forEach(l => out.push(`- [${l.ref}] ${l.name}: ${l.used} / ${l.max}（${Math.round(l.used / l.max * 100)}%）`));
    if (lim.length > MAX.limits) out.push(`- ほか ${lim.length - MAX.limits} 件（省略）`);
    out.push('');

    // 6. 切り詰め・出なかった区分・読み取れなかった行
    out.push('## 6. 切り詰め・出なかった区分・読み取れなかった行');
    trunc.forEach(r => out.push(`- 切り詰めあり: ${r.row.path}（${sizeText(r.row.len)}）`));
    const empty = CATEGORIES.filter(([, types]) => !ok.some(r => types.some(t => r.counts[t])));
    if (ok.length && empty.length) {
        out.push(`- 該当する行なし（詳しさが足りずに出なかった可能性もある）: ${empty.map(([n]) => n).join('・')}`);
    }
    unread.slice(0, MAX.unreadable).forEach(r => {
        const ls = r.unreadable.slice(0, 5).map(n => `${r.row.path}:${n}`).join('、');
        out.push(`- 読み取れなかった行: ${r.unreadable.length} 行（${ls}${r.unreadable.length > 5 ? ' ほか' : ''}）`);
    });
    if (unread.length > MAX.unreadable) out.push(`- ほか ${unread.length - MAX.unreadable} 本のログに、読み取れなかった行があります（省略）`);
    if (!trunc.length && !(ok.length && empty.length) && !unread.length) out.push('- なし');

    process.stdout.write(out.join('\n') + '\n');
}

// ------------------------------------------------------------------------------
// 入口
// ------------------------------------------------------------------------------
function main() {
    const opts = parseArgs(process.argv.slice(2));
    const cmd = opts._[0];
    switch (cmd) {
        case 'summarize': return cmdSummarize(opts);
        case 'list': return cmdList(opts);
        case 'time': return cmdTime(opts);
        default: fail(`サブコマンドが正しくありません: ${cmd || '(なし)'}（summarize / list / time）`);
    }
}

main();
