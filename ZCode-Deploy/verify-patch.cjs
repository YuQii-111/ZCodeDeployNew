// ============================================
// ZCode 补丁功能验证器
// 用法: node verify-patch.cjs [zcode.cjs 路径]
// 作用: 真正执行补丁后的函数，确认 system 层已被替换
//       而不只是"字符串对上了"
// ============================================
const fs = require('fs');
const path = require('path');
const os = require('os');

function detectTarget() {
    if (process.argv[2]) { return process.argv[2]; }
    const cands = [];
    if (process.env.ZCODE_DIR) {
        cands.push(path.join(process.env.ZCODE_DIR, 'resources', 'glm', 'zcode.cjs'));          // Windows / 解包布局
        cands.push(path.join(process.env.ZCODE_DIR, 'Contents', 'Resources', 'glm', 'zcode.cjs')); // macOS .app
        cands.push(path.join(process.env.ZCODE_DIR, 'glm', 'zcode.cjs'));
    }
    cands.push('D:\\app\\zcode\\resources\\glm\\zcode.cjs');                                   // Windows 常规位置
    cands.push('/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs');                    // macOS 常规位置
    cands.push(path.join(os.homedir(), 'Applications', 'ZCode.app', 'Contents', 'Resources', 'glm', 'zcode.cjs'));
    for (const c of cands) { if (fs.existsSync(c)) { return c; } }
    return cands[0];
}

const target = detectTarget();
const personaFile = path.join(__dirname, '人格.txt');

let fail = 0;
function check(label, ok, extra) {
    console.log((ok ? '  [OK]   ' : '  [FAIL] ') + label + (extra ? '   -> ' + extra : ''));
    if (!ok) { fail++; }
}

if (!fs.existsSync(target)) { console.log('目标文件不存在: ' + target); process.exit(1); }
const src = fs.readFileSync(target, 'utf8');
const persona = fs.readFileSync(personaFile, 'utf8');

console.log('目标: ' + target);
console.log('大小: ' + src.length + ' chars');
console.log('');

// ---- 1. 部署标记 ----
const markerCount = src.split('ZP:PERSONA').length - 1;
check('注入标记 ZP:PERSONA 存在 (期望 2 处)', markerCount === 2, markerCount + ' 处');
if (markerCount === 0) {
    console.log('');
    console.log('结果: 未部署，后续检查跳过');
    process.exit(1);
}

// ---- 2. 静态检查 ----
check('CLI Prefix 身份声明已清空', !src.includes('="You are ZCode, an interactive coding agent"'));
check('customSystemPrompt 原逻辑已被替换', !src.includes('this.config.customSystemPrompt?.trim()'));

// ---- 3. 实际执行注入的读取表达式 ----
let readerOk = 0, readerTotal = 0, sample = null;
let pos = 0;
while (true) {
    const start = src.indexOf('(function(){/*ZP:PERSONA*/', pos);
    if (start < 0) { break; }
    const end = src.indexOf('})()', start);
    if (end < 0) { break; }
    readerTotal++;
    const exprSrc = src.slice(start, end + 4);
    try {
        const val = new Function('require', 'return (' + exprSrc + ');')(require);
        if (val && val === persona) { readerOk++; }
        if (sample === null) { sample = val; }
    } catch (e) {
        console.log('  执行失败: ' + e.message);
    }
    pos = end + 4;
}
check('注入的读取表达式能读到人格文件 (' + readerOk + '/' + readerTotal + ')',
      readerTotal === 2 && readerOk === 2,
      sample ? sample.length + ' chars' : 'null');

// ---- 4. 花括号配平定位：真正包住锚点的那个函数 ----
function extractFn(name) {
    const start = src.indexOf('function ' + name + '(');
    if (start < 0) { return null; }
    const open = src.indexOf('{', start);
    let depth = 0;
    for (let i = open; i < src.length; i++) {
        const ch = src[i];
        if (ch === '{') { depth++; }
        else if (ch === '}') { depth--; if (depth === 0) { return src.slice(start, i + 1); } }
    }
    return null;
}

function braceClose(open) {
    let depth = 0;
    for (let i = open; i < src.length; i++) {
        const ch = src[i];
        if (ch === '{') { depth++; }
        else if (ch === '}') { depth--; if (depth === 0) { return i; } }
    }
    return -1;
}

function findFnForLiteral(literal) {
    const idx = src.indexOf(literal);
    if (idx < 0) { return null; }
    const start = Math.max(0, idx - 2000);
    const head = src.slice(start, idx);
    const re = /function\s+([A-Za-z_$][\w$]*)\s*\(([A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*)?\)\s*\{/g;
    let best = null, m;
    while ((m = re.exec(head)) !== null) {
        const open = start + m.index + m[0].length - 1;
        if (braceClose(open) > idx) { best = m[1]; }
    }
    return best;
}

const sections = [
    ['日期提醒',              'name:"Current Date",source:"current_date"'],
    ['Skills 列表',           'name:"Skills",source:"skills"'],
    ['User Context',          'name:"Request User Context",source:"request_user_context"'],
];

for (const item of sections) {
    const actual = findFnForLiteral(item[1]);
    const body = actual ? extractFn(actual) : null;
    if (!body) { check(item[0] + ' 函数可定位', false, '未找到包住锚点的函数'); continue; }
    if (body.indexOf('{return null;') < 0) {
        check(item[0] + ' 已置空 (' + actual + ')', false, '函数体开头不是 return null;');
        continue;
    }
    try {
        const fn = new Function('wm', 'return (' + body + ');')(() => 0);
        check(item[0] + ' 已置空并实际返回 null (' + actual + ')', fn({ outcome: { skills: [] } }) === null);
    } catch (e) {
        check(item[0] + ' 已置空 (' + actual + ')', false, '执行异常: ' + e.message);
    }
}

// ---- 4.5 沙箱执行辅助 ----
// 补丁后的产物函数会引用包内其他顶层标识符（如 qf 计数器、模块级变量），
// 单独提取执行时不在作用域。这里用 with 作用域兜底：
//   - 已知覆盖值（如 CLI Prefix 的模块变量，补丁后为 ""）优先
//   - 其余未知标识符给"可调用透传 stub"（调用返回首个参数，可链式取属性）
//   - require 等真实参数比 with 作用域更内层，不受影响
function makeStub() {
    const f = function () {};
    const p = new Proxy(f, {
        get(t, k) {
            if (k === Symbol.unscopables) { return undefined; }
            if (k === Symbol.toPrimitive) { return () => ''; }
            if (k === 'toString') { return () => ''; }
            if (k === 'length') { return 0; }
            if (k === 'slice') { return () => ''; }
            return p;
        },
        apply(t, thisArg, args) { return args.length ? args[0] : p; },
    });
    return p;
}
function runWithScope(fnSrc, callSrc, named) {
    const stub = makeStub();
    // 真实 require 必须进命名表：产物函数声明在 with 块内，
    // 其体内的自由变量先查 with 代理（has 恒真），再到外层参数就晚了
    const scopeVal = Object.assign({ require: require }, named || {});
    const scope = new Proxy(scopeVal, {
        has() { return true; },
        get(t, k) {
            if (k === Symbol.unscopables) { return undefined; }
            if (k in t) { return t[k]; }
            return stub;
        },
    });
    return new Function('require', '__s', 'with(__s){' + fnSrc + callSrc + '}')(require, scope);
}

// ---- 5. CLI Prefix 实际返回空串 ----
const jmeName = findFnForLiteral('name:"CLI Prefix",source:"cli_prefix"');
const jmeBody = jmeName ? extractFn(jmeName) : null;
if (jmeBody) {
    try {
        // 补丁 1 把模块级身份变量置 ""，从函数体首个赋值里发现变量名并注入该值
        const varHit = jmeBody.match(/let\s+[A-Za-z_$][\w$]*\s*=\s*([A-Za-z_$][\w$]*)\s*;/);
        const scopeVal = {};
        if (varHit) { scopeVal[varHit[1]] = ''; }
        const section = runWithScope(jmeBody, '; return ' + jmeName + '();', scopeVal);
        check('CLI Prefix 片段内容为空 (' + jmeName + ')', section && section.content === '',
              section ? JSON.stringify(section.content).slice(0, 40) : 'null');
    } catch (e) {
        check('CLI Prefix 片段内容为空', false, e.message);
    }
} else {
    check('CLI Prefix 函数可定位', false);
}

// ---- 6. Agent Identity 实际读到人格 ----
const idName = findFnForLiteral('name:"Agent Identity",source:"identity"');
const idBody = idName ? extractFn(idName) : null;
if (idBody) {
    try {
        const section = runWithScope(idBody, '; return ' + idName + '({});', {});
        check('Agent Identity 读到人格文件 (' + idName + ')', section && section.content === persona,
              section ? section.content.length + ' chars' : 'null');
    } catch (e) {
        check('Agent Identity 读到人格文件', false, e.message);
    }
} else {
    check('Agent Identity 函数可定位', false);
}

console.log('');
if (fail === 0) {
    console.log('结果: 全部通过 —— system 层已是人格文件，产品注入已清除');
    process.exit(0);
} else {
    console.log('结果: ' + fail + ' 项失败 —— 补丁未完全生效');
    process.exit(1);
}
