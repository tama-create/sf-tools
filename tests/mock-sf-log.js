'use strict';
// ==============================================================================
// mock-sf-log.js - tests/test_sf-log.sh 用の偽の sf（小さな偽の組織）
// ==============================================================================
// 状態は、環境変数 FAKE_ORG のフォルダの org.json に持つ（呼び出しごとに読み書きする）。呼び出しは MOCK_CALL_LOG に 1 行ずつ書く。
// 読む前にロックを取り、終わるまで持つ（tests/mock-org-lock.js。テストの _org_set が足したログを、古い状態の書き戻しで消さないため）
// 2026-11-23 に開発組織で確かめた動き（doc/sf-log-design.md 13.1）をまねる:
//   - TraceFlag: 同じ対象・同じ種類（LogType）で期間が重なると FIELD_INTEGRITY_EXCEPTION。種類が違えば作れる
//   - TraceFlag: ExpirationDate が「今から 30 秒」以内・StartDate 以前なら FIELD_INTEGRITY_EXCEPTION（今にはできない）
//   - sf apex get log -n N: 全ユーザーのログの新しい順に N 本を、-d のフォルダに <ID>.log で書く。-i ID: その 1 本
//   - 日時は「…000+0000」の形で返す
// 失敗の注入: org.json の fail に「操作:オブジェクト」（例: "create:TraceFlag"・"query:ApexLog"・"getlog"）→ name を書く。
//   failOnce に書くと、1 回だけ失敗する
// 取得の競合の注入: org.json の injectOnGetLog（ログの配列）を、最初の apex get log -n の直前に、ログに足す
// ==============================================================================
const fs = require('fs');
const path = require('path');

const dir = process.env.FAKE_ORG;
const file = path.join(dir, 'org.json');
const args = process.argv.slice(2);
if (process.env.MOCK_CALL_LOG) fs.appendFileSync(process.env.MOCK_CALL_LOG, 'sf ' + args.join(' ') + '\n');

const { lock, writeAtomic } = require('./mock-org-lock');
lock(file);   // プロセスの終了時に外れる
const org = JSON.parse(fs.readFileSync(file, 'utf8'));
const save = () => writeAtomic(file, JSON.stringify(org, null, 1));
const out = (o) => { process.stdout.write(JSON.stringify(o) + '\n'); };
const ok = (result) => { out({ status: 0, result, warnings: [] }); save(); process.exit(0); };
const err = (name, message) => { out({ status: 1, name, message: message || name, exitCode: 1 }); save(); process.exit(1); };
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const sfTime = (ms) => new Date(ms).toISOString().replace('Z', '+0000');
const parse = (s) => {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|\+0000)$/.exec(s || '');
    return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null;
};
const now = Date.now();
org.seq = org.seq || 0;
const newId = (p) => `${p}${String(++org.seq).padStart(12, '0')}AAA`;
// failOnce は 1 回だけ失敗する（使ったら消す。err が保存する）。sf の一時的な失敗のやり直しを確かめる
const failKey = (k) => {
    if (org.failOnce && org.failOnce[k]) { const n = org.failOnce[k]; delete org.failOnce[k]; return n; }
    return org.fail && org.fail[k];
};
const values = () => {
    const o = {};
    (opt('--values') || '').split(' ').filter(Boolean).forEach(kv => { const i = kv.indexOf('='); o[kv.slice(0, i)] = kv.slice(i + 1); });
    return o;
};
org.debugLevels = org.debugLevels || [];
org.traceFlags = org.traceFlags || [];
org.logs = org.logs || [];

const cmd = args.slice(0, 2).join(' ');
if (args[0] === '--version') { process.stdout.write('@salesforce/cli/2.157.8 mock\n'); process.exit(0); }

if (cmd === 'org display' && args[2] === 'user') {
    if (failKey('display:user')) err(failKey('display:user'));
    ok({ id: org.userId, orgId: org.orgId, username: 'user@example.com' });
}

if (cmd === 'data query') {
    const q = opt('--query') || '';
    if (/FROM Organization/.test(q)) {
        ok({ records: [{ Id: org.orgId, Name: 'Fake', IsSandbox: false, OrganizationType: org.orgType || 'Developer Edition', TrialExpirationDate: null }], totalSize: 1, done: true });
    }
    let m;
    if ((m = /FROM DebugLevel WHERE DeveloperName = '([^']+)'/.exec(q))) {
        if (failKey('query:DebugLevel')) err(failKey('query:DebugLevel'));
        const r = org.debugLevels.filter(d => d.DeveloperName === m[1]).map(d => ({ Id: d.Id }));
        ok({ records: r, totalSize: r.length, done: true });
    }
    if ((m = /FROM TraceFlag WHERE TracedEntityId = '([^']+)'/.exec(q))) {
        if (failKey('query:TraceFlag')) err(failKey('query:TraceFlag'));
        const r = org.traceFlags.filter(t => t.TracedEntityId === m[1]).map(t => {
            const dl = org.debugLevels.find(d => d.Id === t.DebugLevelId);
            return { Id: t.Id, LogType: t.LogType, StartDate: t.StartDate === null ? null : sfTime(t.StartDate), ExpirationDate: sfTime(t.ExpirationDate),
                DebugLevel: dl ? { DeveloperName: dl.DeveloperName } : null };
        });
        ok({ records: r, totalSize: r.length, done: true });
    }
    if (/COUNT\(Id\)/.test(q) && /FROM ApexLog/.test(q)) {
        const u = /LogUserId = '([^']+)'/.exec(q);
        const ls = org.logs.filter(l => !u || l.LogUserId === u[1]);
        ok({ records: [{ n: ls.length, s: ls.length ? ls.reduce((a, l) => a + l.LogLength, 0) : null }], totalSize: 1, done: true });
    }
    if (/FROM ApexLog/.test(q)) {
        if (failKey('query:ApexLog')) err(failKey('query:ApexLog'));
        let ls = org.logs.slice();
        if ((m = /StartTime > (\S+) OR \(StartTime = (\S+) AND Id > '([^']+)'\)/.exec(q))) {
            const t = parse(m[1]), id = m[3];
            ls = ls.filter(l => parse(l.StartTime) > t || (parse(l.StartTime) === t && l.Id > id));
        } else if ((m = /StartTime >= (\S+)/.exec(q))) {
            const t = parse(m[1]);
            ls = ls.filter(l => parse(l.StartTime) >= t);
        }
        ls.sort((a, b) => (parse(a.StartTime) - parse(b.StartTime)) || (a.Id < b.Id ? -1 : a.Id > b.Id ? 1 : 0));
        const lim = /LIMIT (\d+)/.exec(q);
        if (lim) ls = ls.slice(0, +lim[1]);
        ok({ records: ls.map(l => ({ attributes: { type: 'ApexLog' }, Id: l.Id, LogUserId: l.LogUserId, StartTime: sfTime(parse(l.StartTime)), Operation: l.Operation,
            Request: 'Api', Status: l.Status, LogLength: l.LogLength, DurationMilliseconds: l.DurationMilliseconds })), totalSize: ls.length, done: true });
    }
    err('MALFORMED_QUERY', 'unknown query: ' + q);
}

// TraceFlag の期間の検査（実機の動き）
const checkTf = (t, self) => {
    if (t.ExpirationDate <= now + 30 * 1000) err('FIELD_INTEGRITY_EXCEPTION', 'ExpirationDate は将来の日付にしてください。: 有効期限');
    if (t.StartDate !== null && t.ExpirationDate <= t.StartDate) err('MULTIPLE_API_ERRORS', 'Multiple errors returned.');
    const s = t.StartDate === null ? now : t.StartDate;
    const clash = org.traceFlags.some(o => o !== self && o.TracedEntityId === t.TracedEntityId && o.LogType === t.LogType
        && s < o.ExpirationDate && (o.StartDate === null ? now : o.StartDate) < t.ExpirationDate);
    if (clash) err('FIELD_INTEGRITY_EXCEPTION', 'このエンティティは、開始日と有効期限がこの追跡フラグと重複する追跡フラグですでに追跡されています。');
};

if (cmd === 'data create') {
    const s = opt('--sobject'), v = values();
    if (failKey('create:' + s)) err(failKey('create:' + s));
    if (s === 'DebugLevel') {
        const d = Object.assign({ Id: newId('7dl') }, v);
        org.debugLevels.push(d);
        ok({ id: d.Id, success: true, errors: [] });
    }
    if (s === 'TraceFlag') {
        const t = { Id: newId('7tf'), TracedEntityId: v.TracedEntityId, LogType: v.LogType, DebugLevelId: v.DebugLevelId,
            StartDate: v.StartDate ? parse(v.StartDate) : null, ExpirationDate: parse(v.ExpirationDate) };
        checkTf(t, null);
        org.traceFlags.push(t);
        ok({ id: t.Id, success: true, errors: [] });
    }
    err('NOT_SUPPORTED');
}

if (cmd === 'data update') {
    const s = opt('--sobject'), id = opt('--record-id'), v = values();
    if (failKey('update:' + s)) err(failKey('update:' + s));
    const list = s === 'TraceFlag' ? org.traceFlags : org.debugLevels;
    const r = list.find(x => x.Id === id);
    if (!r) err('NOT_FOUND', 'not found');
    if (s === 'TraceFlag') {
        const t = Object.assign({}, r);
        if (v.StartDate) t.StartDate = parse(v.StartDate);
        if (v.ExpirationDate) t.ExpirationDate = parse(v.ExpirationDate);
        if (v.DebugLevelId) t.DebugLevelId = v.DebugLevelId;
        checkTf(t, r);
        Object.assign(r, t);
    } else {
        Object.assign(r, v);
    }
    ok({ id, success: true, errors: [] });
}

if (cmd === 'data delete') {
    const s = opt('--sobject'), id = opt('--record-id');
    if (failKey('delete:' + s)) err(failKey('delete:' + s));
    const list = s === 'TraceFlag' ? org.traceFlags : org.debugLevels;
    const i = list.findIndex(x => x.Id === id);
    if (i < 0) err('NOT_FOUND', 'The requested resource does not exist');
    list.splice(i, 1);
    ok({ id, success: true, errors: [] });
}

if (cmd === 'apex get') {
    if (failKey('getlog')) { process.stderr.write('getlog failed\n'); save(); process.exit(1); }
    const d = opt('-d');
    fs.mkdirSync(d, { recursive: true });
    const n = opt('-n'), id = opt('-i');
    let pick;
    if (n !== undefined) {
        if (org.injectOnGetLog && org.injectOnGetLog.length) { org.logs.push(...org.injectOnGetLog); org.injectOnGetLog = []; }
        pick = org.logs.slice().sort((a, b) => (parse(b.StartTime) - parse(a.StartTime)) || (a.Id < b.Id ? 1 : -1)).slice(0, +n);
    } else {
        pick = org.logs.filter(l => l.Id === id);
    }
    if (org.junkFile) fs.writeFileSync(path.join(d, org.junkFile), 'x');
    pick.forEach(l => fs.writeFileSync(path.join(d, `${l.Id}.log`), l.body || `68.0 APEX_CODE,FINE\n12:00:00.1 (1)|USER_INFO|[EXTERNAL]|x|u|(GMT+09:00) 日本標準時 (Asia/Tokyo)|GMT+09:00\n12:00:00.1 (2)|USER_DEBUG|[1]|DEBUG|${l.Id}\n`));
    process.stdout.write(`Log files written to ${d}\n`);
    save();
    process.exit(0);
}

err('NOT_SUPPORTED', 'mock: ' + args.join(' '));
