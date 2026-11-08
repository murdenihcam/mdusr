-- Machine sources for mdusr.
--
-- Each source has: id, name, home, and load(env) which returns an index:
--   { machines = { machine, ... }, notes = { "..." } }
-- machine = { name, title, category, desc, version, extra = {lines},
--             files = { { label, url | zip_member, filename, size } } }
--
-- env provides (all blocking inside a norns clock coroutine):
--   env.get(url)                -> body string | nil, err
--   env.get_file(url, path)     -> true | nil, err
--   env.unzip_list(zip)         -> { {name=, size=}, ... } | nil, err
--   env.unzip_read(zip, member) -> string | nil, err
--   env.dir                     -> per-source cache directory (trailing /)
--
-- To add a site, copy one of the entries below.

local json = include("lib/json")
local text = include("lib/text")

local S = {}

local function github_api(path) return "https://api.github.com" .. path end
local function raw_url(owner, repo, branch, path)
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, branch, text.urlpath(path))
end

local function decode_or_fail(body, what)
  if not body then return nil, what .. ": download failed" end
  local t, e = json.decode(body)
  if not t then return nil, what .. ": bad JSON (" .. tostring(e) .. ")" end
  return t
end

---------------------------------------------------------------------------
-- 1. wftlrd.uk : JSON manifest behind a JS page
---------------------------------------------------------------------------
S[#S + 1] = {
  id = "wftlrd",
  name = "wftlrd",
  home = "https://wftlrd.uk/machinedrum-usr/",
  load = function(env)
    local base = "https://wftlrd.uk/machinedrum-usr/manifest.json"
    local m, e = decode_or_fail(env.get(base), "manifest.json")
    if not m then return nil, e end
    local banks, order = {}, {}
    for i, b in ipairs(m.banks or {}) do
      local title = b.title or b.name or b.id
      banks[b.id or title] = title
      if b.title then banks[b.title] = title end
      order[title] = i
    end
    local out = {}
    for _, x in ipairs(m.machines or {}) do
      local cat = banks[x.bank] or (type(x.bank) == "string" and x.bank) or "Machines"
      local url = text.resolve(base, x.download) or
        (x.filename and text.resolve(base, "downloads/" .. x.filename))
      local extra = {}
      if x.loadOrder then extra[#extra + 1] = "Bank load order: " .. tostring(x.loadOrder) end
      if x.kind then extra[#extra + 1] = "Kind: " .. tostring(x.kind) end
      local files = {}
      if url then
        files[1] = { label = text.basename(url), url = url, filename = text.basename(url),
          size = x.bytes, sha256 = x.sha256 }
      end
      out[#out + 1] = {
        name = x.code or x.id or "?", title = text.ascii(x.displayName or x.title or ""),
        category = cat, desc = text.clean(x.description or ""), version = x.version,
        sort = (order[cat] or 99) * 1000 + (tonumber(x.loadOrder) or 999),
        extra = extra, files = files,
      }
    end
    local notes = { "Whole banks: load every machine of a bank in its numbered order." }
    if m.hardwareQualified == false then
      notes[#notes + 1] = "Site manifest says: not hardware-qualified."
    end
    return { machines = out, notes = notes }
  end,
}

---------------------------------------------------------------------------
-- 2. murdenihcam : machines.js (a JSON array assigned to window.MACHINES)
---------------------------------------------------------------------------
local MURD_CAT = { SMP = "Samplers", RAM = "RAM machines", NFX = "NFX effects" }
S[#S + 1] = {
  id = "murdenihcam",
  name = "murdenihcam",
  home = "https://murdenihcam.github.io/murdenihcam-usr-machines/",
  load = function(env)
    local root = "https://murdenihcam.github.io/murdenihcam-usr-machines/"
    -- prefer a plain machines.json if the site ever publishes one
    local list
    local body = env.get(root .. "machines.json")
    if body then list = json.decode(body) end
    if type(list) ~= "table" or #list == 0 then
      body = env.get(root .. "machines.js")
      if not body then return nil, "machines.js: download failed" end
      local a = body:find("=%s*%[")
      local z = body:match(".*()%]")
      if not a or not z then return nil, "machines.js: no array found" end
      local e
      list, e = json.decode(body:sub(body:find("%[", a), z))
      if not list then return nil, "machines.js: " .. tostring(e) end
    end
    local out = {}
    for i, x in ipairs(list) do
      local files = {}
      for _, v in ipairs(x.variants or {}) do
        if v.file then
          local url = text.resolve(root, text.urlpath(v.file))
          local label = (v.id or text.basename(v.file))
          if v.compat then label = label .. " (" .. v.compat .. ")" end
          files[#files + 1] = { label = label, url = url, filename = text.basename(v.file),
            scope = v.scope and text.ascii(v.scope) }
        end
      end
      local extra = {}
      local t = x.tracks or {}
      if x.category == "RAM" then
        extra[#extra + 1] = "RAM slots per pattern: 4 MKII / 2 MKI"
      end
      if t.mk2 or t.mk1 then
        extra[#extra + 1] = ("Tracks: MKII %s / MKI %s"):format(t.mk2 or "?", t.mk1 or "?")
      end
      for _, a in ipairs(x.aware or {}) do extra[#extra + 1] = "! " .. text.clean(a) end
      out[#out + 1] = {
        name = x.id or x.name, title = text.ascii(x.name or ""),
        category = MURD_CAT[x.category] or x.category or "Machines",
        desc = text.clean(x.desc or ""), version = x.version, sort = i,
        extra = extra, files = files,
      }
    end
    return { machines = out, notes = { "UW only = needs a Machinedrum UW." } }
  end,
}

---------------------------------------------------------------------------
-- 3. moncalamari DBX : static HTML page, .syx in each repo's latest release
---------------------------------------------------------------------------
S[#S + 1] = {
  id = "dbx",
  name = "DBX (MonCalamari)",
  home = "https://moncalamari.github.io/dbx-usr-machines/",
  load = function(env)
    local page = env.get("https://moncalamari.github.io/dbx-usr-machines/")
    if not page then return nil, "page download failed" end
    local seen, repos = {}, {}
    for owner, repo in page:gmatch("github%.com/([%w%-_%.]+)/([%w%-_%.]+)/releases") do
      local k = owner .. "/" .. repo
      if not seen[k] then seen[k] = true; repos[#repos + 1] = { owner = owner, repo = repo } end
    end
    local out, notes = {}, {}
    for i, r in ipairs(repos) do
      -- description: paragraphs after the element whose id matches the repo name
      local desc, meta = "", nil
      local anchor = page:find('id="' .. r.repo:lower() .. '"', 1, true)
        or page:find('id="' .. r.repo .. '"', 1, true)
      if anchor then
        local stop = page:find('<h[1-3][^>]*id="', anchor + 10) or #page
        local chunk = page:sub(anchor, stop)
        for p in chunk:gmatch("<p[^>]*>(.-)</p>") do
          local t = text.clean(p)
          if t:find(" %- v%d") or t:find("cycles") then
            meta = meta or t
          elseif #t > 10 and desc == "" then
            desc = t
          end
          if desc ~= "" and meta then break end
        end
      end
      local m = { name = r.repo, title = "", category = "Machines", desc = desc, sort = i,
        extra = meta and { meta } or {}, files = {} }
      local rel = env.get(github_api(("/repos/%s/%s/releases/latest"):format(r.owner, r.repo)))
      local rj = rel and json.decode(rel)
      if rj and rj.assets then
        m.version = rj.tag_name
        for _, a in ipairs(rj.assets) do
          if (a.name or ""):lower():match("%.syx$") then
            m.files[#m.files + 1] = { label = a.name, url = a.browser_download_url,
              filename = a.name, size = a.size }
          end
        end
      else
        notes[#notes + 1] = r.repo .. ": GitHub release lookup failed (rate limit?)"
      end
      if desc == "" and rj and rj.body then desc = text.readme_summary(rj.body) or "" end
      m.desc = desc
      out[#out + 1] = m
    end
    if #repos == 0 then return nil, "no GitHub release links found on page" end
    return { machines = out, notes = notes }
  end,
}

---------------------------------------------------------------------------
-- 4. GitHub repos holding loose .syx files (one folder per machine)
---------------------------------------------------------------------------
local PREFIX_CAT = { NFX = "NFX effects", SMP = "Samplers", RAM = "RAM machines" }

local function github_tree_source(def)
  return {
    id = def.id, name = def.name,
    home = ("https://github.com/%s/%s"):format(def.owner, def.repo),
    load = function(env)
      local branch = def.branch or "main"
      local t, e = decode_or_fail(env.get(github_api(("/repos/%s/%s/git/trees/%s?recursive=1")
        :format(def.owner, def.repo, branch))), "repo tree")
      if not t then return nil, e end
      local folders, order = {}, {}
      for _, n in ipairs(t.tree or {}) do
        if n.type == "blob" and n.path:lower():match("%.syx$") then
          local folder = n.path:match("^(.*)/[^/]+$") or ""
          if not folders[folder] then folders[folder] = {}; order[#order + 1] = folder end
          table.insert(folders[folder], n)
        end
      end
      table.sort(order)
      local out = {}
      for i, folder in ipairs(order) do
        local name = folder:match("([^/]+)$") or def.repo
        local readme = env.get(raw_url(def.owner, def.repo, branch,
          (folder ~= "" and folder .. "/" or "") .. "README.md"))
        local files = {}
        for _, n in ipairs(folders[folder]) do
          files[#files + 1] = { label = text.basename(n.path),
            url = raw_url(def.owner, def.repo, branch, n.path),
            filename = text.basename(n.path), size = n.size }
        end
        local pre = name:match("^(%u+)%-")
        out[#out + 1] = {
          name = name, title = "", category = PREFIX_CAT[pre] or pre or "Machines",
          desc = text.readme_summary(readme) or "", sort = i, extra = {}, files = files,
        }
      end
      return { machines = out, notes = {} }
    end,
  }
end

S[#S + 1] = github_tree_source {
  id = "bento909", name = "bento909", owner = "bento909", repo = "MDX20-User-Machines",
}

---------------------------------------------------------------------------
-- Kitbasher (kitbasher.xyz/mds): mds/catalog.json in etcetc000/kitbasher.
-- Lists mds/tx6 and mds/community/*, except community/murdenihcam (already
-- its own source). mds/core is skipped: those are the MDX built-ins.
---------------------------------------------------------------------------
local KB_RAW = "https://raw.githubusercontent.com/etcetc000/kitbasher/main/"
local function kitbasher_include(file)
  if file:match("^mds/tx6/") then return true end
  if file:match("^mds/community/") and not file:lower():match("^mds/community/murdenihcam/") then
    return true
  end
  return false
end
S[#S + 1] = {
  id = "kitbasher",
  name = "kitbasher MDS",
  home = "https://kitbasher.xyz/mds",
  include = kitbasher_include,
  load = function(env)
    local c, e = decode_or_fail(env.get(KB_RAW .. "mds/catalog.json"), "catalog.json")
    if not c then return nil, e end
    local out = {}
    for i, x in ipairs(c.machines or {}) do
      local file = x.file or ""
      if kitbasher_include(file) and file:lower():match("%.syx$") then
        local fname = text.basename(file)
        local stem = fname:gsub("%.[Ss][Yy][Xx]$", "")
        local cat, name
        local tx6 = file:match("^mds/tx6/([^/]+)/")
        if tx6 then
          cat, name = "TX6 (Simple606)", "TX6-" .. tx6:upper()
        else
          local author = file:match("^mds/community/([^/]+)/") or "community"
          cat, name = "Community: " .. (x.author or author), stem:upper()
        end
        local extra = {}
        if x.author then extra[#extra + 1] = "By " .. text.ascii(x.author) end
        if x.hardware == "uw" then extra[#extra + 1] = "UW only"
        elseif x.hardware == "all" then extra[#extra + 1] = "All models" end
        if x.license then extra[#extra + 1] = "Licence: " .. text.ascii(x.license) end
        if x.notes and x.notes ~= "" then extra[#extra + 1] = text.clean(x.notes) end
        out[#out + 1] = {
          name = name, title = "", category = cat,
          desc = text.clean(x.summary or ""), sort = (tx6 and 0 or 1000) + i,
          extra = extra,
          files = { { label = fname, url = KB_RAW .. text.urlpath(file), filename = text.safe(
            (file:gsub("^mds/", ""):gsub("/", "_"))), size = x.size, sha256 = x.sha256 } },
        }
      end
    end
    if #out == 0 then return nil, "catalog has no tx6/community machines" end
    return { machines = out, notes = { "core/ (MDX built-ins) and community/murdenihcam are skipped." } }
  end,
}

---------------------------------------------------------------------------
-- 5. MDX X.20 bundled machines : .syx files inside the firmware zip
---------------------------------------------------------------------------
local FIRMWARE_MIN = 100 * 1024 -- anything this big is the OS image, never offered

-- find a description for `stem` in readme text: same line after the name, or
-- the following non-empty lines
local function readme_entry(readme, stem)
  if not readme then return nil end
  local lines = {}
  for l in (readme:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local pat = stem:gsub("%p", "%%%0")
  for i, l in ipairs(lines) do
    if l:find(pat) then
      local rest = l:gsub(".-" .. pat .. "[%w%._]*", "", 1)
      rest = rest:gsub("^[%s:|%-=%.%)%]]+", "")
      local t = text.clean(rest)
      if #t < 12 then
        local acc = {}
        for k = i + 1, math.min(i + 6, #lines) do
          local n = lines[k]
          if n:match("^%s*$") then if #acc > 0 then break end
          elseif n:match("^%s*[%-=*]+%s*$") then -- underline
          else acc[#acc + 1] = n end
        end
        t = text.clean(table.concat(acc, " "))
      end
      if #t >= 12 then return t end
    end
  end
  return nil
end

S[#S + 1] = {
  id = "mdx",
  name = "MDX X.20 bundle",
  home = "https://github.com/jmamma/MDX",
  load = function(env)
    local t, e = decode_or_fail(env.get(github_api("/repos/jmamma/MDX/git/trees/HEAD?recursive=1")),
      "MDX repo tree")
    if not t then return nil, e end
    local best
    for _, n in ipairs(t.tree or {}) do
      if n.type == "blob" and n.path:match("^firmware/mdx/X%.20/.*%.zip$") then
        if not best or n.path > best.path then best = n end
      end
    end
    if not best then return nil, "no X.20 zip in repo" end
    local zipname = text.basename(best.path)
    local zip = env.dir .. text.safe(zipname)
    local f = io.open(zip, "rb")
    if f then f:close() else
      local ok, ge = env.get_file(raw_url("jmamma", "MDX", "main", best.path), zip)
      if not ok then return nil, "zip download failed: " .. tostring(ge) end
    end
    local list, le = env.unzip_list(zip)
    if not list then return nil, "unzip failed: " .. tostring(le) end
    local syx, readmes = {}, {}
    for _, z in ipairs(list) do
      local low = z.name:lower()
      if low:match("%.syx$") and (z.size or 0) < FIRMWARE_MIN then
        syx[#syx + 1] = z
      elseif low:match("readme[^/]*%.txt$") then
        readmes[#readmes + 1] = z
      end
    end
    -- descriptions come only from the machines' own README (USR-Machines/
    -- README.txt), never from the OS readme or changelog
    local pick
    for _, z in ipairs(readmes) do
      if z.name:lower():match("usr[%-_ ]?machines/readme") then pick = z end
    end
    if not pick then
      local dirs = {}
      for _, z in ipairs(syx) do dirs[(z.name:match("^(.*)/") or "")] = true end
      for _, z in ipairs(readmes) do
        if dirs[(z.name:match("^(.*)/") or "")] and not z.name:lower():match("os") then pick = z end
      end
    end
    local readme = pick and env.unzip_read(zip, pick.name) or nil
    table.sort(syx, function(a, b) return a.name < b.name end)
    local out = {}
    for i, z in ipairs(syx) do
      local fname = text.basename(z.name)
      local stem = fname:gsub("%.[Ss][Yy][Xx]$", "")
      -- full machine name (e.g. P-I-HP), only a trailing version is dropped
      local short = stem:gsub("[%-_ ]+[vV]?%d+[%d%._]*[%a]?$", "")
      if short == "" then short = stem end
      local pre = short:match("^(%u+)%-")
      out[#out + 1] = {
        name = short, title = "",
        category = PREFIX_CAT[pre] or "MDX bundle",
        desc = readme_entry(readme, stem) or readme_entry(readme, short)
          or ("Bundled with " .. zipname:gsub("%.zip$", "")),
        sort = i, extra = {},
        files = { { label = fname, zip = zip, zip_member = z.name, filename = fname, size = z.size } },
      }
    end
    return { machines = out, notes = { "From " .. zipname .. " (X.20 is a public preview)." } }
  end,
}

S.readme_entry = readme_entry -- exposed for tests
return S
