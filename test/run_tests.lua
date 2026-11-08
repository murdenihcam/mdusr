-- Off-device tests for mdusr. Run from the mdusr folder:
--   lua5.3 test/run_tests.lua
-- Mocks the norns APIs (screen, params, midi, clock, util) and the network,
-- then drives the real script through browse -> send, backup -> restore.

local ROOT = arg and arg[0]:match("^(.*)/test/") or "."
local TMP = os.getenv("MDUSR_TMP") or "/tmp/mdusr_test/"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP .. "fx")

local fails, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. msg) end
end

-------------------------------------------------------------------- mocks
local modcache = {}
function include(p)
  if not modcache[p] then modcache[p] = dofile(ROOT .. "/" .. p .. ".lua") end
  return modcache[p]
end

_path = { data = TMP .. "data/" }
os.execute("mkdir -p " .. _path.data)

-- virtual clock / scheduler
local now = 0
local tasks = {}
clock = {}
function clock.run(f)
  local co = coroutine.create(f)
  tasks[#tasks + 1] = { co = co, wake = now }
  return co
end
function clock.sleep(s) coroutine.yield(s) end
local function step()
  table.sort(tasks, function(a, b) return a.wake < b.wake end)
  local t = table.remove(tasks, 1)
  if not t then return false end
  now = math.max(now, t.wake)
  local ok, s = coroutine.resume(t.co)
  if not ok then error("task error: " .. tostring(s) .. "\n" .. debug.traceback(t.co)) end
  if coroutine.status(t.co) ~= "dead" then t.wake = now + (s or 0); tasks[#tasks + 1] = t end
  return true
end
local function run_until(cond, max_t)
  local limit = now + (max_t or 600)
  while not cond() do
    if now > limit then return false end
    if not step() then return cond() end
  end
  return true
end

util = {
  time = function() return now end,
  clamp = function(x, a, b) return math.max(a, math.min(b, x)) end,
  make_dir = function(d) os.execute("mkdir -p '" .. d .. "'") end,
  scandir = function(d)
    local t = {}
    local p = io.popen("ls -1 '" .. d .. "' 2>/dev/null")
    for l in p:lines() do t[#t + 1] = l end
    p:close()
    return t
  end,
}

local drawn = {}
screen = setmetatable({
  text_extents = function(s) return #s * 5, 8 end,
  text = function(s) drawn[#drawn + 1] = s end,
  text_right = function(s) drawn[#drawn + 1] = s end,
  text_center = function(s) drawn[#drawn + 1] = s end,
  clear = function() drawn = {} end,
}, { __index = function() return function() end end })

local P = {}
params = {
  add_separator = function() end,
  add_option = function(_, id, _, _, def) P[id] = { v = def or 1 } end,
  add_number = function(_, id, _, _, _, def) P[id] = { v = def } end,
  set_action = function(_, id, f) P[id].action = f end,
  get = function(_, id) return P[id].v end,
  set = function(_, id, v) P[id].v = v; if P[id].action then P[id].action(v) end end,
  read = function() end, write = function() end,
  bang = function() for _, p in pairs(P) do if p.action then p.action(p.v) end end end,
}
-- fix arg order of add_option/add_number (self, id, name, ...)
params.add_option = function(_, id, _, opts, def) P[id] = { v = def or 1 } end
params.add_number = function(_, id, _, min, max, def) P[id] = { v = def } end

local sent = {}         -- raw bytes sent to the MD
local responder = nil   -- function(bytes) for simulated MD replies
local dev = { name = "MD" }
function dev:send(t)
  for _, b in ipairs(t) do sent[#sent + 1] = b end
  if responder then responder(t) end
end
midi = { vports = { { name = "MD" } }, connect = function() return dev end }

-------------------------------------------------------------------- fixtures
local function syx_msg(id, n, fill)
  local m = { 0xF0, 0x00, 0x20, 0x3C, 0x02, 0x00, id, 0x01, 0x00 }
  for i = 1, n do m[#m + 1] = (fill + i) % 128 end
  m[#m + 1] = 0xF7
  return m
end
local function bytes_str(msgs)
  local s = {}
  for _, m in ipairs(msgs) do for _, b in ipairs(m) do s[#s + 1] = string.char(b) end end
  return table.concat(s)
end

local BD_SYX = bytes_str({ syx_msg(0x5E, 400, 9), syx_msg(0x5E, 90, 10) })
local USR_SYX = bytes_str({ syx_msg(0x5E, 300, 1), syx_msg(0x5E, 700, 2), syx_msg(0x5E, 50, 3) })

local MANIFEST = [[{"date":"2026-11-06","hardwareQualified":false,"target":"MDX with USR support",
 "banks":[{"id":"dr110-quality-bank-v14","title":"DR-110","download":"./downloads/BANK-DR110-v1.0.zip"},
          {"id":"gamelan-refinement-v3","title":"Digital Gamelan"}],
 "machines":[
  {"code":"D11-CP","displayName":"DR110 CP PILOT","description":"Clap — noise bursts.","version":"1.0","bank":"dr110-quality-bank-v14","loadOrder":1,"filename":"D11-CP-v1.0.syx","download":"./downloads/D11-CP-v1.0.syx","bytes":1050},
  {"code":"D11-BD","displayName":"DR110 BD","description":"Bass drum.","version":"1.0","bank":"dr110-quality-bank-v14","loadOrder":2,"download":"./downloads/D11-BD-v1.0.syx"},
  {"code":"GM-AG","displayName":"GONG AGENG","description":"Large gong with &amp; long tail.","version":"1.0","bank":"gamelan-refinement-v3","loadOrder":1,"download":"./downloads/GM-AG-v1.0.syx"}
 ]}]]

local MACHINES_JS = [==[// Machine data for the murdenihcam USR machines page. Edit with tools/site-editor.html.
// params rows: [label, default, valueTexts or null, min, max, "what it does"]
// (label, default, valueTexts, min and max set how the knob is drawn on the screen).
window.MACHINES = [
  {"id":"SMP-SL","name":"SMP-SL[ICE]","version":"0.6","category":"SMP","lcdName":"SL","desc":"Transient-detecting slicer.",
   "params":[["SMPL",0,null,0,127,"sample"]],"aware":["Infinite decay at 127."],"tracks":{"mk2":"14","mk1":"12","sram":"0"},
   "variants":[{"id":"SMP-SL","scope":"all banks","compat":"UW only","file":"downloads/SMP-SL/SMP-SL.syx","logo":"x.png"},
               {"id":"SMP-SN","scope":"E12 bank only","compat":"all models","file":"downloads/SMP-SL/SMP-SN.syx","logo":"x.png"}]},
  {"id":"RAM-PS","name":"RAM-P[ITCH] S[HIFTER]","version":"0.2","category":"RAM","desc":"Two-voice pitch shifter.",
   "params":[],"aware":[],"tracks":{"mk2":"10","mk1":"8","sram":"1"},
   "variants":[{"id":"RAM-PS","scope":"Effect","compat":"UW only","file":"downloads/RAM-PS/RAM-PS_U04.syx","logo":"y.png"}]},
  {"id":"NFX-MO","name":"NFX-MO[DULATOR]","version":"0.11","category":"NFX","desc":"Modulation effect.",
   "params":[],"aware":[],"tracks":{"mk2":"16","mk1":"16"},
   "variants":[{"id":"NFX-MO","scope":"Effect","compat":"all models","file":"downloads/NFX-MO/mo.syx","logo":"z.png"}]}
];
]==]

local DBX_HTML = [[<html><body><nav><a href="#dbx-k2">DBX-K2</a></nav>
<section><h3 id="dbx-k2">DBX-K2</h3>
<p class="meta">Resonator kick &middot; v0.9 &middot; MKII 2,508 / MKI 2,850 cycles &middot; 1.8 KB</p>
<p>A resonator kick in the spirit of the <em>Korg Volca Kick</em>.</p>
<a href="https://github.com/MonCalamari/DBX-K2">GitHub</a> <a href="https://github.com/MonCalamari/DBX-K2/releases/latest">Latest release</a></section>
<section><h3 id="dbx-dr">DBX-DR</h3><p class="meta">Dark drone · v0.5 · 2.5 KB</p><p>A single-voice drone.</p>
<a href="https://github.com/MonCalamari/DBX-DR/releases/latest">Latest release</a></section></body></html>]]

local function release(name, tag)
  return ([[{"tag_name":"%s","body":"notes","assets":[{"name":"%s.mds","browser_download_url":"https://github.com/MonCalamari/%s/releases/download/%s/%s.mds","size":10},
  {"name":"%s.syx","browser_download_url":"https://github.com/MonCalamari/%s/releases/download/%s/%s.syx","size":1800}]}]])
    :format(tag, name, name, tag, name, name, name, tag, name)
end

local BENTO_TREE = [[{"sha":"x","tree":[{"path":"NFX-BO","type":"tree"},{"path":"NFX-BO/NFX-BO.syx","type":"blob","size":2248},
{"path":"NFX-BO/README.md","type":"blob"},{"path":"NFX-UW/NFX-UW.syx","type":"blob","size":2394},{"path":"README.md","type":"blob"}],"truncated":false}]]
local BENTO_README = "# NFX-BO\n\n![badge](x.svg)\n\nA custom Machinedrum **User Machine** that captures the [two tracks](x) before it and bounces them.\n\n## Params\n"

-- MDX zip with readme, two machines and a big firmware image
local zipdir = TMP .. "zipsrc/"
os.execute("mkdir -p " .. zipdir .. "USR-Machines")
local function wr(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
wr(zipdir .. "USR-Machines/FMX-B1.syx", USR_SYX)
wr(zipdir .. "USR-Machines/PLK-01.syx", USR_SYX)
wr(zipdir .. "USR-Machines/P-I-HP-v1.0.syx", USR_SYX)
wr(zipdir .. "USR-Machines/P-I-KS.syx", USR_SYX)
wr(zipdir .. "Machinedrum_SPS1-UW_OS_X.20_C.syx", string.rep("\xF0\x01\xF7", 60000))
wr(zipdir .. "Machinedrum_SPS1-UW_OS-X.20_readme.txt", "OS notes\n\nFMX-B1 was renamed in this OS build, see the changelog for details.\n")
wr(zipdir .. "USR-Machines/README.txt", "Bundled user machines\n---------------------\n\n  FMX-B1.syx : two-operator FM bass with feedback.\n  PLK-01.syx\n      Karplus plucked string with damping control.\n")
local ZIP = TMP .. "fx/Machinedrum_SPS1-UW_OS_X.20_C.zip"
os.execute(("cd '%s' && python3 -c \"import zipfile,os;z=zipfile.ZipFile('%s','w')\nfor r,d,f in os.walk('.'):\n  [z.write(os.path.join(r,x),os.path.join(r,x)[2:]) for x in f]\nz.close()\""):format(zipdir, ZIP))
local MDX_TREE = [[{"tree":[{"path":"firmware/mdx/X.20/Machinedrum_SPS1-UW_OS_X.20_B.zip","type":"blob"},
{"path":"firmware/mdx/X.20/Machinedrum_SPS1-UW_OS_X.20_C.zip","type":"blob"},{"path":"firmware/mdx/X.14/Machinedrum_SPS1-UW_OS_X.14.zip","type":"blob"}]}]]

local KB_CATALOG = [[{"schema":"kitbasher.mds-catalog/1","machines":[
 {"file":"mds/core/TX8/TX8-BD.syx","channel":"core","author":"MDX","summary":"808-style bass drum"},
 {"file":"mds/community/murdenihcam/SMP-SL.syx","channel":"community","author":"murdenihcam","summary":"slicer"},
 {"file":"mds/community/samplesandsnacks/rasp/RASP.syx","channel":"community","author":"SamplesAndSnacks","summary":"Blown trill","source":null,"license":"MIT","hardware":"all","notes":"Recategorised \u2013 code changed to PHY-RS."},
 {"file":"mds/tx6/bd/bd.syx","channel":"community","author":"Kitbasher / Simple606 contributors","summary":"606-style bass drum","license":"MIT","notes":"Version 2.1"}
]}]]

local WEB = {
  ["https://raw.githubusercontent.com/etcetc000/kitbasher/main/mds/catalog.json"] = KB_CATALOG,
  ["https://raw.githubusercontent.com/etcetc000/kitbasher/main/mds/tx6/bd/bd.syx"] = USR_SYX,
  ["https://wftlrd.uk/machinedrum-usr/manifest.json"] = MANIFEST,
  ["https://wftlrd.uk/machinedrum-usr/downloads/D11-CP-v1.0.syx"] = USR_SYX,
  ["https://wftlrd.uk/machinedrum-usr/downloads/D11-BD-v1.0.syx"] = BD_SYX,
  ["https://murdenihcam.github.io/murdenihcam-usr-machines/machines.js"] = MACHINES_JS,
  ["https://murdenihcam.github.io/murdenihcam-usr-machines/downloads/SMP-SL/SMP-SN.syx"] = USR_SYX,
  ["https://moncalamari.github.io/dbx-usr-machines/"] = DBX_HTML,
  ["https://api.github.com/repos/MonCalamari/DBX-K2/releases/latest"] = release("DBX-K2", "v0.9"),
  ["https://api.github.com/repos/MonCalamari/DBX-DR/releases/latest"] = release("DBX-DR", "v0.5"),
  ["https://api.github.com/repos/bento909/MDX20-User-Machines/git/trees/main?recursive=1"] = BENTO_TREE,
  ["https://raw.githubusercontent.com/bento909/MDX20-User-Machines/main/NFX-BO/README.md"] = BENTO_README,
  ["https://api.github.com/repos/jmamma/MDX/git/trees/HEAD?recursive=1"] = MDX_TREE,
}
local ZIP_URL = "https://raw.githubusercontent.com/jmamma/MDX/main/firmware/mdx/X.20/Machinedrum_SPS1-UW_OS_X.20_C.zip"

local offline = false
local fetched = {}
local net = include("lib/net")
net.get_file = function(url, path)
  clock.sleep(0.2)
  fetched[#fetched + 1] = url
  if offline then return nil, "offline" end
  if url == ZIP_URL then os.execute(("cp '%s' '%s'"):format(ZIP, path)); return true end
  local body = WEB[url]
  if not body then return nil, "404" end
  wr(path, body)
  return true
end

-- real background runner, checked once, then swapped for a synchronous one so
-- the virtual clock does not spin while real processes run
do
  net.tmpdir = TMP
  local out
  clock.run(function() out = net.run("echo hello; echo world") end)
  run_until(function() return out ~= nil end, 100000)
  check(out == "hello\nworld\n", "net.run background + marker file")
  local leftovers = util.scandir(TMP)
  local stray = false
  for _, f in ipairs(leftovers) do if f:find("mdusr_run_") then stray = true end end
  check(not stray, "net.run cleans up temp files")
end
net.run = function(cmd)
  local f = io.popen(cmd, "r"); local s = f:read("a"); f:close(); return s
end

-------------------------------------------------------------------- unit tests
local json = include("lib/json")
local text = include("lib/text")
local sysex = include("lib/sysex")
local sources = include("lib/sources")

do
  local t = json.decode('{"a":[1,2,{"b":"x\\u00e9\\n"}],"c":null,"d":true,"e":-1.5e2}')
  check(t and t.a[3].b == "x\195\169\n" and t.c == nil and t.d == true and t.e == -150, "json decode")
  check(json.decode('{"a":') == nil, "json rejects truncated")
  local back = json.decode(json.encode({ x = { 1, 2, "q\"" }, y = {} }))
  check(back.x[3] == 'q"' and #back.x == 3, "json roundtrip")
  check(text.clean("<p>A &amp; B &middot; c\226\128\148d</p>") == "A & B - c-d", "text.clean")
  check(text.resolve("https://h/a/b/m.json", "./downloads/x.syx") == "https://h/a/b/downloads/x.syx", "resolve ./")
  check(text.resolve("https://h/a/", "downloads/x y.syx") == "https://h/a/downloads/x y.syx", "resolve rel")
  check(text.urlpath("a b/c.syx") == "a%20b/c.syx", "urlpath")
  local w = text.wrap("one two three four five six seven", 40)
  check(#w == 5 and w[1] == "one two" and w[4] == "five six", "wrap")
  check(text.readme_summary(BENTO_README):find("^A custom Machinedrum User Machine that captures the two tracks") ~= nil, "readme summary")
  check(sysex.pattern_name(0) == "A01" and sysex.pattern_name(127) == "H16", "pattern names")

  local r = sysex.split("junk" .. USR_SYX .. "\xF0\x01\x90\x02\xF7" .. USR_SYX)
  check(#r.msgs == 6 and #r.errors == 1 and r.junk == 7, "split + bad message detection")
  check(sysex.split("\xF0\x01\x02").errors[1] ~= nil, "split: missing F7")

  local got = {}
  local a = sysex.assembler(function(m) got[#got + 1] = m end)
  local m = syx_msg(0x52, 100, 5)
  for i = 1, #m, 3 do
    local c = { table.unpack(m, i, math.min(i + 2, #m)) }
    a.feed(c)
    a.feed({ 0xF8 }) -- clock interleaved
  end
  a.feed({ 0x90, 60, 100 }) -- note outside sysex ignored
  check(#got == 1 and #got[1] == #m and got[1][#m] == 0xF7, "assembler across chunks with realtime")
  a.feed({ 0xF0, 1, 2, 0x90 })
  check(#got == 1 and a.aborted == 1, "assembler aborts on status byte")
  local req = sysex.md_request(0x68, 5)
  check(table.concat(req, ",") == "240,0,32,60,2,0,104,5,247", "pattern request bytes")
  check(sources.readme_entry("x\n  FMX-B1.syx : FM bass with feedback here.\n", "FMX-B1") == "FM bass with feedback here.", "readme entry same line")
end

-------------------------------------------------------------------- script tests
dofile(ROOT .. "/mdusr.lua")
init()
run_until(function() return #fetched > 0 end, 5)
-- wait for the auto refresh to finish
local function idle() redraw(); return true end
run_until(function()
  for _, t in ipairs(tasks) do
    -- the redraw loop never ends; refresh task ends
  end
  return #tasks <= 1
end, 600)
redraw()

local function count_index(id)
  local f = io.open(_path.data .. "mdusr/cache/index_" .. id .. ".json")
  if not f then return -1 end
  local t = json.decode(f:read("a")); f:close()
  return #t.machines, t
end
local logf = io.open(_path.data .. "mdusr/refresh.log")
local logtxt = logf and logf:read("a") or ""
check(logtxt:find("wftlrd: ok, 3 machines") and logtxt:find("refresh ok: 6 sources"), "refresh log written: " .. logtxt)
local n, w = count_index("wftlrd")
check(n == 3, "wftlrd: 3 machines (got " .. tostring(n) .. ")")
check(w and w.machines[1].files[1].url == "https://wftlrd.uk/machinedrum-usr/downloads/D11-CP-v1.0.syx", "wftlrd url")
check(w and w.machines[1].category == "DR-110" and w.machines[3].category == "Digital Gamelan", "wftlrd categories")
check(w and w.machines[1].desc == "Clap - noise bursts.", "wftlrd desc ascii")
local n2, mu = count_index("murdenihcam")
check(n2 == 3, "murdenihcam: 3 machines")
check(mu and mu.machines[1].files[2].url == "https://murdenihcam.github.io/murdenihcam-usr-machines/downloads/SMP-SL/SMP-SN.syx", "murdenihcam url")
check(mu and mu.machines[2].category == "RAM machines" and mu.machines[2].extra[1]:find("RAM slots"), "murdenihcam RAM note")
local n3, db = count_index("dbx")
check(n3 == 2 and #db.machines[1].files == 1 and db.machines[1].files[1].filename == "DBX-K2.syx", "dbx: syx from release")
check(db and db.machines[1].desc == "A resonator kick in the spirit of the Korg Volca Kick.", "dbx desc: " .. tostring(db and db.machines[1].desc))
check(db and db.machines[1].extra[1] and db.machines[1].extra[1]:find("v0.9"), "dbx meta line")
local n4, be = count_index("bento909")
check(n4 == 2 and be.machines[1].name == "NFX-BO" and be.machines[1].category == "NFX effects", "bento909 machines")
check(be and be.machines[2].desc == "", "bento909 missing readme -> empty desc")
local nk, kb = count_index("kitbasher")
check(nk == 2, "kitbasher: core + community/murdenihcam skipped (got " .. tostring(nk) .. ")")
check(kb and kb.machines[1].name == "TX6-BD" and kb.machines[1].category == "TX6 (Simple606)", "kitbasher tx6 first")
check(kb and kb.machines[2].category == "Community: SamplesAndSnacks" and kb.machines[2].desc == "Blown trill", "kitbasher community entry")
check(kb and kb.machines[1].files[1].url == "https://raw.githubusercontent.com/etcetc000/kitbasher/main/mds/tx6/bd/bd.syx", "kitbasher raw url")
local n5, mx = count_index("mdx")
check(n5 == 4, "mdx: firmware image hidden, 4 machines (got " .. tostring(n5) .. ")")
check(mx and mx.machines[1].category == "MDX bundle", "mdx category")
check(mx and mx.machines[2].name == "P-I-HP" and mx.machines[3].name == "P-I-KS", "mdx full names, version dropped: " .. tostring(mx and mx.machines[2].name))
check(mx and mx.machines[1].desc == "two-operator FM bass with feedback.", "mdx desc same line: " .. tostring(mx and mx.machines[1].desc))
check(mx and mx.machines[4].desc == "Karplus plucked string with damping control.", "mdx desc next line: " .. tostring(mx and mx.machines[4].desc))

-- browse wftlrd -> DR-110 -> D11-CP -> send
enc(2, 1); key(3, 1); redraw() -- enter wftlrd (sources item 2, after Collection)
enc(2, 1); key(3, 1); redraw() -- cats: item 2 = DR-110
key(3, 1); redraw()            -- D11-CP detail
local seen = table.concat(drawn, "|")
check(seen:find("D11%-CP") and seen:find("Clap"), "detail shows name + desc")
key(3, 1)                      -- prepare (download)
run_until(function() return #tasks <= 1 end, 30)
redraw()
check(table.concat(drawn, "|"):find("arm RECV"), "confirm screen shows receive reminder")
sent = {}
key(3, 1)                      -- send
run_until(function() return #tasks <= 1 end, 60)
redraw()
check(bytes_str({ sent }) == USR_SYX, "sent bytes == file bytes (" .. #sent .. "/" .. #USR_SYX .. ")")
check(table.concat(drawn, "|"):find("SENT"), "result screen")
key(2, 1)                      -- dismiss result
-- pacing: 1053 bytes at 2500 B/s + 2 gaps of 0.15 s ~ 0.72 s minimum
local t0 = now
key(3, 1); run_until(function() return #tasks <= 1 end, 30) -- prepare again (cached, no download)
sent = {}
local before = #fetched
key(3, 1); run_until(function() return #tasks <= 1 end, 60)
check(now - t0 >= 0.7, "send is paced (" .. string.format("%.2f", now - t0) .. "s)")
check(#fetched == before, "cached syx not re-downloaded")
key(2, 1)

-- abort mid-send
key(3, 1); run_until(function() return #tasks <= 1 end, 30)
sent = {}
key(3, 1)
run_until(function() return #sent > 400 end, 10)
key(2, 1)
run_until(function() return #tasks <= 1 end, 10)
check(#sent < #USR_SYX and sent[#sent] == 0xF7, "abort closes SysEx with F7")
key(2, 1)

-- zip machine (MDX) send
for _ = 1, 4 do key(2, 1) end   -- back to sources
for _ = 1, 20 do enc(2, -1) end
for i, src in ipairs(sources) do if src.id == "mdx" then for _ = 1, i do enc(2, 1) end end end
key(3, 1); redraw()            -- mdx has 1 category -> machines directly? (USR folder)
local s1 = table.concat(drawn, "|")
check(s1:find("FMX%-B1"), "mdx source opens machine list")
key(3, 1); key(3, 1)           -- detail -> prepare
run_until(function() return #tasks <= 1 end, 30)
sent = {}
key(3, 1); run_until(function() return #tasks <= 1 end, 60)
check(bytes_str({ sent }) == USR_SYX, "zip member extracted and sent")
key(2, 1)

-- offline refresh keeps cache
offline = true
for _ = 1, 4 do key(2, 1) end
for _ = 1, 20 do enc(2, 1) end -- "Refresh all"
key(3, 1)
run_until(function() return #tasks <= 1 end, 600)
local n6 = count_index("wftlrd")
check(n6 == 3, "offline refresh keeps cached index")
logtxt = io.open(_path.data .. "mdusr/refresh.log"):read("a")
check(logtxt:find("wftlrd: FAILED") and logtxt:find("1 ok, 6 FAILED"), "failure summary logged")
redraw()
check(table.concat(drawn, "|"):find("!2 0m"), "error flag shown on source row: " .. table.concat(drawn, "|"))
offline = false

-------------------------------------------------------------------- backup page
enc(1, 1)
redraw()
check(table.concat(drawn, "|"):find("BACKUP"), "E1 switches to backup page")
-- simulated MD: answers requests with a dump split into 3-byte chunks + clock bytes
responder = function(t)
  if t[1] == 0xF0 and t[7] and (t[7] == 0x51 or t[7] == 0x53 or t[7] == 0x68 or t[7] == 0x6A) then
    local reply = syx_msg(t[7] - 1, 200, t[8] or 0)
    reply[10] = t[8] or 0
    clock.run(function()
      clock.sleep(0.05)
      for i = 1, #reply, 3 do
        dev.event({ table.unpack(reply, i, math.min(i + 2, #reply)) })
        dev.event({ 0xF8 })
        clock.sleep(0.001)
      end
    end)
  end
end
-- request kit 05
B_sel = nil
enc(2, 1) -- kit
for _ = 1, 4 do enc(3, 1) end
key(3, 1)
run_until(function() return #tasks <= 1 end, 10)
redraw()
check(table.concat(drawn, "|"):find("got kit 5"), "kit request -> reply captured (" .. table.concat(drawn, "|") .. ")")
-- full backup
for _ = 1, 4 do enc(2, 1) end -- full
key(3, 1)
run_until(function() return #tasks <= 1 end, 3000)
local files = util.scandir(_path.data .. "mdusr/backups/")
check(#files == 1 and files[1]:match("^full_.*%.syx$"), "full backup saved")
local data = sysex.read_file(_path.data .. "mdusr/backups/" .. files[1])
local r = sysex.split(data or "")
check(#r.msgs == 232 and #r.errors == 0, "full backup has 232 valid dumps (got " .. #r.msgs .. ")")
-- restore it
responder = nil
for _ = 1, 3 do enc(2, 1) end -- restore
key(3, 1); redraw()
check(table.concat(drawn, "|"):find("full_"), "restore list shows backup")
key(3, 1); redraw()
check(table.concat(drawn, "|"):find("overwrites"), "restore confirm warns")
sent = {}
key(3, 1)
run_until(function() return #tasks <= 1 end, 3000)
check(bytes_str({ sent }) == data, "restore sends file bytes exactly")

-------------------------------------------------------------------- variant rows
do
  enc(1, -1)
  for _ = 1, 5 do key(2, 1) end; for _ = 1, 20 do enc(2, -1) end
  for i, src in ipairs(sources) do if src.id == "murdenihcam" then for _ = 1, i do enc(2, 1) end end end
  key(3, 1)                 -- murdenihcam -> categories
  enc(2, 1); key(3, 1)      -- Samplers
  redraw()
  local sc = table.concat(drawn, "|")
  check(sc:find("SMP%-SL") and sc:find("SMP%-SN") and sc:find("E3 %+coll"), "each variant is its own row + E3 hint: " .. sc)
  enc(2, 1); key(3, 1); redraw()  -- SMP-SN detail
  sc = table.concat(drawn, "|")
  check(sc:find("Variant of SMP%-SL") and sc:find("E3> collect"), "variant detail + hint")
  enc(3, 1); redraw()
  check(table.concat(drawn, "|"):find("%* E3< remove"), "E3 in detail adds to collection")
  enc(3, -1)
end

-------------------------------------------------------------------- collection
enc(1, -1) -- back to LOAD
local function to_sources() for _ = 1, 5 do key(2, 1) end; for _ = 1, 20 do enc(2, -1) end end
local function open_source(id)
  to_sources()
  for i, src in ipairs(sources) do if src.id == id then for _ = 1, i do enc(2, 1) end end end
  key(3, 1)
end
-- wftlrd -> DR-110 -> add D11-CP and D11-BD with E3
open_source("wftlrd")
enc(2, 1); key(3, 1)       -- DR-110
for _ = 1, 5 do enc(2, -1) end
enc(3, 1)                  -- add D11-CP
enc(2, 1); enc(3, 1)       -- add D11-BD
enc(3, 1)                  -- adding twice is a no-op
redraw()
check(table.concat(drawn, "|"):find("%* D11%-CP") and table.concat(drawn, "|"):find("%* D11%-BD"), "collected machines marked")
-- mdx: add the second machine
open_source("mdx")
enc(2, 1); enc(3, 1)       -- PLK-01
-- remove + re-add D11-BD to check E3 left
open_source("wftlrd"); enc(2, 1); key(3, 1); for _ = 1, 5 do enc(2, -1) end; enc(2, 1)
enc(3, -1); enc(3, 1)
local cj = json.decode(read_file and "" or (io.open(_path.data .. "mdusr/collection.json"):read("a")))
check(cj and #cj == 3 and cj[1].file.filename == "D11-CP-v1.0.syx" and cj[3].file.filename == "D11-BD-v1.0.syx", "collection saved in order (" .. tostring(cj and #cj) .. ")")
-- open collection, move D11-BD (item 3) up to position 2
to_sources(); key(3, 1)    -- Collection is first item
redraw()
check(table.concat(drawn, "|"):find("COLLECTION"), "collection screen")
for _ = 1, 4 do enc(2, 1) end -- rows: send, clear, 1, 2, 3 -> sel 5 (item 3)
enc(3, -1)                 -- move up
redraw()
check(table.concat(drawn, "|"):find("2 D11%-BD"), "reorder moves item up")
-- send all, auto gap
for _ = 1, 10 do enc(2, -1) end
key(3, 1)                  -- Send all -> prepare (downloads D11-BD)
run_until(function() return #tasks <= 1 end, 60)
redraw()
check(table.concat(drawn, "|"):find("3 files"), "batch confirm shows 3 files")
sent = {}
local t1 = now
key(3, 1)
run_until(function() return #tasks <= 1 end, 120)
check(bytes_str({ sent }) == USR_SYX .. BD_SYX .. USR_SYX, "batch sends files in collection order")
check(now - t1 >= 3.0, "auto gap between files (" .. string.format("%.2f", now - t1) .. "s)")
redraw()
check(table.concat(drawn, "|"):find("3 files sent"), "batch result screen")
key(2, 1)
-- wait-for-K3 mode
params:set("between", 2)
key(3, 1); run_until(function() return #tasks <= 1 end, 60)
sent = {}
key(3, 1)
run_until(function() return #sent >= #USR_SYX end, 60)
run_until(function() return false end, 5) -- give it time; it must hold at file 2
redraw()
check(#sent == #USR_SYX and table.concat(drawn, "|"):find("NEXT 2/3"), "waits for K3 before file 2")
key(3, 1); run_until(function() return #sent >= #USR_SYX + #BD_SYX end, 60)
run_until(function() return false end, 3)
check(#sent == #USR_SYX + #BD_SYX, "waits again before file 3")
key(2, 1)                  -- stop instead
run_until(function() return #tasks <= 1 end, 10)
redraw()
check(table.concat(drawn, "|"):find("2 of 3 files"), "stopped batch reports progress")
key(2, 1)
-- remove item with K3, clear needs two presses
for _ = 1, 2 do enc(2, 1) end
key(3, 1)
local cj2 = json.decode(io.open(_path.data .. "mdusr/collection.json"):read("a"))
check(#cj2 == 2, "K3 on item removes it")
for _ = 1, 10 do enc(2, -1) end; enc(2, 1)
key(3, 1)
check(#json.decode(io.open(_path.data .. "mdusr/collection.json"):read("a")) == 2, "first clear press only asks")
key(3, 1)
check(#json.decode(io.open(_path.data .. "mdusr/collection.json"):read("a")) == 0, "second press clears")

print(("%d passed, %d failed"):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
