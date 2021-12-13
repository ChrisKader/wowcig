local args = (function()
  local parser = require('argparse')()
  parser:option('-c --cache', 'cache directory', 'cache')
  parser:option('-d --db2', 'db2 to extract'):count('*')
  parser:option('-e --extracts', 'extracts directory', 'extracts')
  parser:option('-p --product', 'WoW product'):choices({
    'wow',
    'wowt',
    'wow_classic',
    'wow_classic_era',
    'wow_classic_era_ptr',
    'wow_classic_ptr',
  })
  parser:flag('-v --verbose', 'verbose printing')
  parser:flag('-x --skip-framexml', 'skip framexml extraction')
  parser:flag('-z --zip', 'write zip files instead of directory trees')
  return parser:parse()
end)()

local dbds = require('luadbd').dbds
local path = require('path')

local function normalizePath(p)
  -- path.normalize does not normalize x/../y to y.
  -- Unfortunately, we need exactly that behavior for Interface_Vanilla etc.
  -- links in per-product TOCs. We hack around it here by adding an extra dir.
  return path.normalize('a/' .. p):sub(3)
end

path.mkdir(args.cache)

local function log(...)
  if args.verbose then
    print(...)
  end
end

local encryptionKeys = (function()
  local url = 'https://raw.githubusercontent.com/wowdev/TACTKeys/master/WoW.txt'
  local wowtxt = require('ssl.https').request(url)
  local ret = {}
  for line in wowtxt:gmatch('[^\r\n]+') do
    local k, v = line:match('^([0-9A-F]+) ([0-9A-F]+)')
    ret[k:lower()] = v:lower()
  end
  return ret
end)()

local load, save, onexit, version = (function()
  local casc = require('casc')
  local url = 'http://us.patch.battle.net:1119/' .. args.product
  local bkey, cdn, ckey, version = casc.cdnbuild(url, 'us')
  assert(bkey)
  log('loading', version)
  local handle, err = casc.open({
    bkey = bkey,
    cdn = cdn,
    ckey = ckey,
    cache = args.cache,
    cacheFiles = true,
    keys = encryptionKeys,
    locale = casc.locale.US,
    log = log,
  })
  if not handle then
    print('unable to open ' .. args.product .. ': ' .. err)
    os.exit()
  end
  local zfVersion, zfProduct
  if args.zip then
    local z = require('brimworks.zip')
    local fnVersion = path.join(args.extracts, version .. '.zip')
    local fnProduct = path.join(args.extracts, args.product .. '.zip')
    path.remove(fnVersion)
    path.remove(fnProduct)
    zfVersion = assert(z.open(fnVersion, z.OR(z.CREATE, z.EXCL)))
    zfProduct = assert(z.open(fnProduct, z.OR(z.CREATE, z.EXCL)))
  end
  local fdids = {}
  do
    local dbd = dbds.manifestinterfacedata
    local filedb = assert(handle:readFile(dbd.fdid))
    local build = assert(dbd:build(version))
    for row in build:rows(filedb) do
      fdids[normalizePath(row.FilePath .. row.FileName)] = row.ID
    end
  end
  local function load(f)
    return handle:readFile(fdids[f] or f)
  end
  local function addToZip(zf, fn, content)
    local idx = zf:name_locate(fn)
    if idx then
      zf:replace(idx, 'string', content)
    else
      zf:add(fn, 'string', content)
    end
  end
  local function save(f, c)
    if not c then
      log('skipping', f)
    else
      log('writing ', f)
      if zfVersion then
        local t = {}
        if type(c) == 'function' then
          c(function(s) table.insert(t, s) end)
        else
          table.insert(t, c)
        end
        local content = table.concat(t, '')
        addToZip(zfVersion, path.join(version, f), content)
        addToZip(zfProduct, path.join(args.product, f), content)
      else
        local fn = path.join(args.extracts, version, f)
        path.mkdir(path.dirname(fn))
        local fd = assert(io.open(fn, 'w'))
        if type(c) == 'function' then
          c(function(s) fd:write(s) end)
        else
          fd:write(c)
        end
        fd:close()
      end
    end
  end
  local function onexit()
    if zfVersion then
      zfVersion:close()
      zfProduct:close()
    else
      require('lfs').link(version, path.join(args.extracts, args.product), true)
    end
  end
  return load, save, onexit, version
end)()

local function joinRelative(relativeTo, suffix)
  return normalizePath(path.join(path.dirname(relativeTo), suffix))
end

local processFile = (function()
  local lxp = require('lxp')
  local function doProcessFile(fn)
    local content = load(fn)
    save(fn, content)
    if (fn:sub(-4) == '.xml') then
      local parser = lxp.new({
        StartElement = function(_, name, attrs)
          local lname = string.lower(name)
          if (lname == 'include' or lname == 'script') and attrs.file then
            doProcessFile(joinRelative(fn, attrs.file))
          end
        end,
      })
      parser:parse(content)
      parser:close()
    end
  end
  return doProcessFile
end)()

local function processToc(tocName)
  local toc = load(tocName)
  save(tocName, toc)
  if toc then
    for line in toc:gmatch('[^\r\n]+') do
      if line:sub(1, 1) ~= '#' then
        processFile(joinRelative(tocName, line:gsub('%s*$', '')))
      end
    end
  end
end

local productSuffixes = {
  '',
  '_Vanilla',
  '_TBC',
  '_Mainline',
}

if not args.skip_framexml then
  local function processAllProductFiles(addonDir)
    assert(addonDir:sub(1, 10) == 'Interface/', addonDir)
    local addonName = path.basename(addonDir)
    for _, suffix in ipairs(productSuffixes) do
      processToc(path.join(addonDir, addonName .. suffix .. '.toc'))
      processFile(path.join('Interface' .. suffix, addonDir:sub(11), 'Bindings.xml'))
    end
  end
  processAllProductFiles('Interface/FrameXML')
  do
    local dbd = dbds.manifestinterfacetocdata
    local tocdb = assert(load(dbd.fdid))
    local build = assert(dbd:build(version))
    for dir in build:rows(tocdb) do
      processAllProductFiles(normalizePath(dir.FilePath))
    end
  end
end

for _, db2 in ipairs(args.db2) do
  local name = string.lower(db2)
  save(('db2/%s.db2'):format(name), function(write)
    write(assert(load(assert(dbds[name]).fdid)))
  end)
end

onexit()
