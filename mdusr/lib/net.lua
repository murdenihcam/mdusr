-- network + shell helpers for mdusr. All functions block the calling
-- coroutine (run them inside clock.run) but not the norns UI.
local net = {}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
net.quote = q

-- run a shell command in the background and return its stdout. The command
-- runs detached (&) and drops a marker file when finished; the calling clock
-- coroutine polls for the marker, so the norns UI never blocks and this works
-- on every norns version (no dependency on norns.system_cmd).
local seq = 0
net.tmpdir = "/tmp/"
function net.run(cmd, timeout)
  seq = seq + 1
  local base = ("%smdusr_run_%d_%d"):format(net.tmpdir, os.time(), seq)
  local out, done = base .. ".out", base .. ".done"
  os.execute(("( ( %s ) > %s 2>&1; touch %s ) &"):format(cmd, q(out), q(done)))
  local deadline = os.time() + (timeout or 180)
  while true do
    local f = io.open(done, "r")
    if f then f:close(); break end
    if os.time() > deadline then return nil end
    clock.sleep(0.1)
  end
  local f = io.open(out, "rb")
  local s = f and f:read("a") or ""
  if f then f:close() end
  os.remove(out); os.remove(done)
  return s
end

local UA = "mdusr-norns"

-- download url -> path (atomic: temp file then rename)
function net.get_file(url, path)
  if not url:match("^https?://[%w%-%._~:/%?#%[%]@!%$&%%%(%)%*%+,;=]+$") then
    return nil, "refusing odd URL"
  end
  local tmp = path .. ".part"
  local cmd = ("(curl -fsSL --connect-timeout 10 --max-time 90 -A %s -o %s %s || wget -q -T 60 -U %s -O %s %s) >/dev/null 2>&1 && mv %s %s && echo MDUSR_OK || (rm -f %s; echo MDUSR_FAIL)")
    :format(q(UA), q(tmp), q(url), q(UA), q(tmp), q(url), q(tmp), q(path), q(tmp))
  local out = net.run(cmd)
  if out and out:find("MDUSR_OK", 1, true) then return true end
  return nil, "download failed"
end

-- download url -> string (via a temp file so binary/whitespace survive)
function net.get(url, tmpdir)
  seq = seq + 1
  local tmp = ("%smdusr_get_%d.tmp"):format(tmpdir or net.tmpdir, seq)
  local ok, e = net.get_file(url, tmp)
  if not ok then return nil, e end
  local f = io.open(tmp, "rb")
  if not f then return nil, "read failed" end
  local s = f:read("a")
  f:close()
  os.remove(tmp)
  return s
end

local PY_LIST = [[import zipfile,sys
for i in zipfile.ZipFile(sys.argv[1]).infolist():
    print("%d\t%s" % (i.file_size, i.filename))]]
local PY_EXTRACT = [[import zipfile,sys
open(sys.argv[3],"wb").write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))]]

function net.unzip_list(zip)
  local out = net.run(("python3 -c %s %s 2>/dev/null"):format(q(PY_LIST), q(zip)))
  local list = {}
  for size, name in (out or ""):gmatch("(%d+)\t([^\n]+)") do
    list[#list + 1] = { size = tonumber(size), name = name }
  end
  if #list == 0 then
    out = net.run(("unzip -l %s 2>/dev/null"):format(q(zip)))
    for size, name in (out or ""):gmatch("\n%s*(%d+)%s+[%d%-/]+%s+[%d:]+%s+([^\n]+)") do
      list[#list + 1] = { size = tonumber(size), name = name }
    end
  end
  if #list == 0 then return nil, "could not list zip (need python3 or unzip)" end
  return list
end

function net.unzip_extract(zip, member, path)
  local out = net.run(("(python3 -c %s %s %s %s 2>/dev/null || unzip -p %s %s > %s) && echo MDUSR_OK")
    :format(q(PY_EXTRACT), q(zip), q(member), q(path), q(zip), q(member), q(path)))
  if out and out:find("MDUSR_OK", 1, true) then return true end
  return nil, "extract failed"
end

function net.unzip_read(zip, member, tmpdir)
  seq = seq + 1
  local tmp = ("%smdusr_member_%d.tmp"):format(tmpdir or net.tmpdir, seq)
  if not net.unzip_extract(zip, member, tmp) then return nil end
  local f = io.open(tmp, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  os.remove(tmp)
  return s
end

return net
