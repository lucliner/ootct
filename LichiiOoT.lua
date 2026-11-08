--[[
LichiiOoT.lua
Cheat Engine add-on for the Lichii Switch 2 emulator (Ocarina of Time remake).

Install: copy this file into the "autorun" folder of Cheat Engine, then restart Cheat Engine.

What it does:
  1. Finds the Lichii process and attaches to it (only if no other process is open).
  2. Finds the guest memory of the emulated console inside the Lichii process.
  3. Sets the scan range to the guest memory only (no duplicates, faster scans).
  4. Registers the symbol GUEST. Guest address X is then written as GUEST+X.
     GUEST+X stays valid after you restart the emulator.
  5. Adds a "Lichii" menu to Cheat Engine.
]]

if LichiiTool and LichiiTool.shutdown then pcall(LichiiTool.shutdown) end

local T = {}
LichiiTool = T

local cfg = {
  names = { 'lichii', 'eglantine' },             -- parts of the process name to match
  virtualSizes = { 0x8000000000, 0x4000000000 }, -- 512 GiB (Windows), 256 GiB (NCE builds)
  minBacking = 0x40000000,                       -- backing memory is at least 1 GiB
  pollMs = 2000,
}

local MEM_COMMIT, MEM_RESERVE, MEM_FREE, MEM_MAPPED = 0x1000, 0x2000, 0x10000, 0x40000

T.pid, T.base, T.size, T.backing, T.autoAttach = nil, nil, nil, nil, true

local function hex(n) return string.format('%X', n) end

local function mib(n) return string.format('%.0f MiB', n / 1048576) end

-- Pure function. Input: the list from enumMemoryRegions().
-- Output: table {base, size, backingBase, backingSize, committed} or nil, reason.
function T.analyze(regs)
  local list = {}
  for _, r in ipairs(regs) do list[#list + 1] = r end
  table.sort(list, function(a, b) return a.BaseAddress < b.BaseAddress end)

  -- Group regions that touch each other and are not free.
  local runs, cur = {}, nil
  for _, r in ipairs(list) do
    if r.State ~= MEM_FREE then
      if cur and cur.last == r.BaseAddress then
        cur.items[#cur.items + 1] = r
        cur.last = r.BaseAddress + r.RegionSize
      else
        cur = { items = { r }, last = r.BaseAddress + r.RegionSize }
        runs[#runs + 1] = cur
      end
    else
      cur = nil
    end
  end

  -- The guest address space is one reserved block. It starts with a reserved
  -- (placeholder) region and is at least 512 GiB long.
  local found
  for _, size in ipairs(cfg.virtualSizes) do
    for _, run in ipairs(runs) do
      for _, r in ipairs(run.items) do
        if r.BaseAddress == r.AllocationBase and r.State == MEM_RESERVE
           and run.last - r.BaseAddress >= size then
          local slack = run.last - (r.BaseAddress + size)
          if not found or found.size ~= size or slack < found.slack then
            found = { base = r.BaseAddress, size = size, slack = slack }
          end
        end
      end
    end
    if found then break end
  end
  if not found then
    return nil, 'No reserved block of 256 or 512 GiB found. Is a game running in Lichii?'
  end

  -- The backing memory is the largest committed mapped block outside the guest block.
  local backing
  for _, r in ipairs(list) do
    if r.State == MEM_COMMIT and r.Type == MEM_MAPPED and r.BaseAddress == r.AllocationBase
       and (r.BaseAddress < found.base or r.BaseAddress >= found.base + found.size)
       and r.RegionSize >= cfg.minBacking
       and (not backing or r.RegionSize > backing.size) then
      backing = { base = r.BaseAddress, size = r.RegionSize }
    end
  end

  local committed = 0
  for _, r in ipairs(list) do
    if r.State == MEM_COMMIT and r.BaseAddress >= found.base
       and r.BaseAddress < found.base + found.size + 0x200000 then
      committed = committed + r.RegionSize
    end
  end

  -- Lichii aligns the guest base up to 2 MiB inside the reserved block.
  local ALIGN = 0x200000
  local alignedBase = (found.base + ALIGN - 1) // ALIGN * ALIGN

  return {
    base = alignedBase, size = found.size,
    backingBase = backing and backing.base, backingSize = backing and backing.size,
    committed = committed,
  }
end

function T.info()
  if not T.base then return 'Guest memory not found yet.' end
  local s = string.format('Process ID: %d\nGuest memory (GUEST): %X\nGuest size: %d GiB\nMapped guest memory: %s',
    T.pid or 0, T.base, T.size >> 30, mib(T.committed or 0))
  if T.backing then
    s = s .. string.format('\nBacking memory (LICHII_BACKING): %X (%s)', T.backing.base, mib(T.backing.size))
  end
  return s
end

function T.clear()
  pcall(unregisterSymbol, 'GUEST')
  pcall(unregisterSymbol, 'LICHII_BACKING')
  T.pid, T.base, T.size, T.backing, T.committed = nil, nil, nil, nil, nil
end

function T.setScanRange()
  if not T.base then return end
  local mf = getMainForm()
  mf.FromAddress.Text = string.format('%016X', T.base)
  mf.ToAddress.Text = string.format('%016X', T.base + T.size - 1)
end

local warnedMapped = false
local function checkMemMapped()
  if warnedMapped then return end
  local ok, on = pcall(function() return getSettingsForm().cbMemMapped.Checked end)
  if ok and on then return end
  warnedMapped = true
  showMessage('Lichii add-on: guest memory is "mapped" memory.\n' ..
              'Open Edit > Settings > Scan Settings and tick MEM_MAPPED.\n' ..
              'If you do not, scans find nothing.')
end

local failedOnce = false
function T.detect(quiet)
  local res, why = T.analyze(enumMemoryRegions())
  if not res then
    if not quiet or not failedOnce then print('[Lichii] ' .. why) end
    failedOnce = true
    return false
  end
  failedOnce = false
  T.base, T.size, T.backing, T.committed = res.base, res.size, nil, res.committed
  if res.backingBase then T.backing = { base = res.backingBase, size = res.backingSize } end
  registerSymbol('GUEST', T.base, true)
  if T.backing then registerSymbol('LICHII_BACKING', T.backing.base, true) end
  T.setScanRange()
  print('[Lichii] Guest memory found.\n' .. T.info())
  checkMemMapped()
  return true
end

local function findProcess()
  local best
  for pid, name in pairs(getProcesslist()) do
    local n = tostring(name):lower()
    for _, key in ipairs(cfg.names) do
      if n:find(key, 1, true) and (not best or pid < best) then best = pid end
    end
  end
  return best
end

function T.attach(force)
  local pid = findProcess()
  if not pid then
    if force then showMessage('Lichii process not found. Start Lichii first.') end
    return false
  end
  openProcess(pid)
  T.clear()
  T.pid = pid
  return T.detect(not force)
end

local function tick()
  if T.pid and not getProcesslist()[T.pid] then T.clear() end
  if T.pid then
    if not T.base then T.detect(true) end
  elseif T.autoAttach then
    local cur = getOpenedProcessID()
    if cur == 0 or cur == getCheatEngineProcessID() then T.attach(false) end
  end
end

-- Table helpers: guest address <-> host address.
function T.toGuest(addr)
  if T.base and addr >= T.base and addr < T.base + T.size then return addr - T.base end
end

function T.makeRelative()
  if not T.base then showMessage('Guest memory not found yet.') return end
  local done, skipped = 0, 0
  for _, mr in ipairs(getAddressList().getSelectedRecords() or {}) do
    local g = (mr.OffsetCount == 0) and T.toGuest(mr.CurrentAddress)
    if g then
      mr.Address = 'GUEST+' .. hex(g)
      done = done + 1
    else
      skipped = skipped + 1
    end
  end
  showMessage(string.format('Changed: %d. Skipped: %d.\n(Skipped = pointer entries or addresses outside guest memory.)',
    done, skipped))
end

function T.copyGuest()
  local mr = getAddressList().SelectedRecord
  local g = mr and T.toGuest(mr.CurrentAddress)
  if not g then showMessage('Select an address that is inside guest memory.') return end
  writeToClipboard('GUEST+' .. hex(g))
  print('[Lichii] Copied GUEST+' .. hex(g))
end


-- Guest memory blocks and dumps (for code analysis in Ghidra).
T.dumpDir = [[E:\Emulation\ROMS\Switch 2\Zelda OOT\Claude outputs\]]

-- Returns a list of {g = guest address, size = bytes} for mapped guest memory.
-- Blocks that touch each other are merged.
function T.guestBlocks()
  local out = {}
  if not T.base then return out end
  local list = {}
  for _, r in ipairs(enumMemoryRegions()) do
    if r.State == MEM_COMMIT and r.BaseAddress >= T.base and r.BaseAddress < T.base + T.size then
      list[#list + 1] = r
    end
  end
  table.sort(list, function(a, b) return a.BaseAddress < b.BaseAddress end)
  for _, r in ipairs(list) do
    local last = out[#out]
    if last and T.base + last.g + last.size == r.BaseAddress then
      last.size = last.size + r.RegionSize
    else
      out[#out + 1] = { g = r.BaseAddress - T.base, size = r.RegionSize }
    end
  end
  return out
end

function T.listBlocks()
  if not T.base then showMessage('Guest memory not found yet.') return end
  local blocks = T.guestBlocks()
  print(string.format('[Lichii] %d guest blocks. First 25 (guest address, size):', #blocks))
  for i = 1, math.min(25, #blocks) do
    print(string.format('  %2d  %011X  size %X  (%s)', i, blocks[i].g, blocks[i].size, mib(blocks[i].size)))
  end
end

-- Writes guest memory [g, g+size) to files in T.dumpDir.
-- Only readable pages are written. Each file holds up to 64 MiB of one run of
-- readable pages. The file name holds the guest address: g_<address>.bin
local READABLE = 0x02 | 0x04 | 0x08 | 0x20 | 0x40 | 0x80
local function readable(r)
  local p = r.Protect or 0x04
  return (p & READABLE) ~= 0 and (p & 0x100) == 0
end

function T.dump(g, size)
  if not T.base then showMessage('Guest memory not found yet.') return end
  local lo, hi = T.base + g, T.base + g + size
  local regs = {}
  for _, r in ipairs(enumMemoryRegions()) do
    if r.State == MEM_COMMIT and r.BaseAddress + r.RegionSize > lo and r.BaseAddress < hi then
      regs[#regs + 1] = r
    end
  end
  table.sort(regs, function(a, b) return a.BaseAddress < b.BaseAddress end)

  local runs, cur = {}, nil
  for _, r in ipairs(regs) do
    local a = math.max(r.BaseAddress, lo)
    local b = math.min(r.BaseAddress + r.RegionSize, hi)
    if readable(r) then
      if cur and cur.b == a then cur.b = b else cur = { a = a, b = b }; runs[#runs + 1] = cur end
    else
      cur = nil
      print(string.format('[Lichii] skipped %X size %X protect %X', a - T.base, b - a, r.Protect or 0))
    end
  end

  local PART = 0x4000000
  local files, bytes, bad = 0, 0, 0
  for _, run in ipairs(runs) do
    local off = run.a
    while off < run.b do
      local n = math.min(PART, run.b - off)
      local name = string.format('%sg_%011X.bin', T.dumpDir, off - T.base)
      local ok, wrote = pcall(writeRegionToFile, name, off, n)
      wrote = ok and tonumber(wrote) or 0
      if wrote ~= n then
        bad = bad + 1
        print(string.format('[Lichii] WARNING %s wrote %d of %d bytes', name, wrote, n))
      end
      files, bytes = files + 1, bytes + wrote
      off = off + n
    end
  end
  print(string.format('[Lichii] Done. %d runs, %d files, %s written, %d warnings.', #runs, files, mib(bytes), bad))
end

function T.dumpAsk()
  local text = inputQuery('Dump guest memory',
    'Enter #1 to dump all of block 1 (block numbers from the list),\nor a guest start and a size in hex, separated by a space.', '')
  if not text then return end
  local idx = text:match('^%s*#(%d+)%s*$')
  if idx then
    local blk = T.guestBlocks()[tonumber(idx)]
    if not blk then showMessage('No such block.') return end
    T.dump(blk.g, blk.size)
    return
  end
  local a, b = text:match('^%s*(%x+)%s+(%x+)%s*$')
  if not a then showMessage('Wrong format. Example: 8000000 6000000') return end
  T.dump(tonumber(a, 16), tonumber(b, 16))
end


-- Dumps only the guest pages that Windows blocks (PAGE_NOACCESS). This is
-- usually the program code. Each run is made readable for a short time, written
-- to x_<address>.bin, and locked again at once.
function T.dumpLocked(g, size)
  if not T.base then showMessage('Guest memory not found yet.') return end
  local lo, hi = T.base + g, T.base + g + size
  local regs = {}
  for _, r in ipairs(enumMemoryRegions()) do
    if r.State == MEM_COMMIT and (r.Protect or 0) == 0x01
       and r.BaseAddress + r.RegionSize > lo and r.BaseAddress < hi then
      regs[#regs + 1] = r
    end
  end
  table.sort(regs, function(a, b) return a.BaseAddress < b.BaseAddress end)
  local runs, cur = {}, nil
  for _, r in ipairs(regs) do
    local a = math.max(r.BaseAddress, lo)
    local b = math.min(r.BaseAddress + r.RegionSize, hi)
    if cur and cur.b == a then cur.b = b else cur = { a = a, b = b }; runs[#runs + 1] = cur end
  end
  local PART = 0x4000000
  local files, bytes, bad = 0, 0, 0
  for _, run in ipairs(runs) do
    local off = run.a
    while off < run.b do
      local n = math.min(PART, run.b - off)
      local name = string.format('%sx_%011X.bin', T.dumpDir, off - T.base)
      local okp = pcall(setMemoryProtection, off, n, { R = true })
      local ok, wrote = pcall(writeRegionToFile, name, off, n)
      pcall(setMemoryProtection, off, n, {})           -- lock again
      wrote = (okp and ok) and tonumber(wrote) or 0
      if wrote ~= n then
        bad = bad + 1
        print(string.format('[Lichii] WARNING %s wrote %d of %d bytes', name, wrote, n))
      end
      files, bytes = files + 1, bytes + wrote
      off = off + n
    end
  end
  print(string.format('[Lichii] Locked pages done. %d runs, %d files, %s written, %d warnings.',
    #runs, files, mib(bytes), bad))
end

function T.dumpLockedAsk()
  local text = inputQuery('Dump locked guest pages',
    'Enter #1 for block 1 (block numbers from the list),\nor a guest start and a size in hex, separated by a space.', '#1')
  if not text then return end
  local idx = text:match('^%s*#(%d+)%s*$')
  if idx then
    local blk = T.guestBlocks()[tonumber(idx)]
    if not blk then showMessage('No such block.') return end
    T.dumpLocked(blk.g, blk.size)
    return
  end
  local a, b = text:match('^%s*(%x+)%s+(%x+)%s*$')
  if not a then showMessage('Wrong format. Example: 8000000 6000000') return end
  T.dumpLocked(tonumber(a, 16), tonumber(b, 16))
end


-- Dumps the host code cache of the emulator (the x86 code made from the game
-- code). Only executable pages outside the guest block and outside the program
-- image are written, to j_<host address>.bin.
function T.dumpJit()
  if not T.base then showMessage('Guest memory not found yet.') return end
  local glo, ghi = T.base, T.base + (T.size or 0)
  local EXEC = 0x10 | 0x20 | 0x40 | 0x80
  local regs = {}
  for _, r in ipairs(enumMemoryRegions()) do
    local p = r.Protect or 0
    local inGuest = r.BaseAddress < ghi and r.BaseAddress + r.RegionSize > glo
    if r.State == MEM_COMMIT and (p & EXEC) ~= 0 and (p & 0x100) == 0
       and not inGuest and (r.Type or 0) ~= 0x1000000 then
      regs[#regs + 1] = r
    end
  end
  table.sort(regs, function(a, b) return a.BaseAddress < b.BaseAddress end)
  local PART, files, bytes, bad = 0x4000000, 0, 0, 0
  for _, r in ipairs(regs) do
    local off, stop = r.BaseAddress, r.BaseAddress + r.RegionSize
    while off < stop do
      local n = math.min(PART, stop - off)
      local name = string.format('%sj_%012X.bin', T.dumpDir, off)
      local ok, wrote = pcall(writeRegionToFile, name, off, n)
      wrote = ok and tonumber(wrote) or 0
      if wrote ~= n then
        bad = bad + 1
        print(string.format('[Lichii] WARNING %s wrote %d of %d bytes', name, wrote, n))
      end
      files, bytes = files + 1, bytes + wrote
      off = off + n
    end
  end
  print(string.format('[Lichii] Code cache done. %d regions, %d files, %s written, %d warnings.',
    #regs, files, mib(bytes), bad))
end


-- Player object search.
-- The jump code reads Link's height as a float at offset 0x320 of the player
-- object (X at 0x31C, Z at 0x324). Every C++ object starts with a pointer to its
-- class table (84xxxxxx or 85xxxxxx). This tool lists all such objects whose
-- three floats look like a position. Walking and standing still then removes the
-- wrong ones.
local OBJ_X, OBJ_Y, OBJ_Z = 0x31C, 0x320, 0x324
local WRITABLE = 0x04 | 0x08 | 0x40 | 0x80
T.pStage, T.pCand = 0, nil

local function okf(v) return v == v and v > -100000 and v < 100000 end

local function snapshot()
  local snap, regions, count = {}, {}, 0
  for _, r in ipairs(enumMemoryRegions()) do
    local p = r.Protect or 0
    local g = r.BaseAddress - T.base
    if r.State == MEM_COMMIT and r.BaseAddress >= T.base and r.BaseAddress < T.base + T.size
       and (p & WRITABLE) ~= 0 and (p & 0x100) == 0
       and not (g >= 0x80000000 and g < 0x86400000) then
      regions[#regions + 1] = r
    end
  end
  table.sort(regions, function(a, b) return a.BaseAddress < b.BaseAddress end)
  local CH = 0x100000
  for ri, r in ipairs(regions) do
    local a, e = r.BaseAddress, r.BaseAddress + r.RegionSize
    while a < e do
      local n = math.min(CH, e - a)
      local ok, b = pcall(readBytes, a, n, true)
      if ok and b then
        for i = 1, n - 7, 8 do
          local hi = b[i + 7]
          if hi == 0 and b[i + 6] == 0 and b[i + 5] == 0 and b[i + 4] == 0 then
            local top = b[i + 3]
            if top == 0x84 or top == 0x85 then
              local obj = a + i - 1
              if not T.pCand or T.pCand[obj] then
                local okx, x = pcall(readFloat, obj + OBJ_X)
                local oky, y = pcall(readFloat, obj + OBJ_Y)
                local okz, z = pcall(readFloat, obj + OBJ_Z)
                if okx and oky and okz and x and y and z and okf(x) and okf(y) and okf(z)
                   and (x ~= 0 or z ~= 0) then
                  local vt = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (top << 24)
                  snap[obj] = { x = x, y = y, z = z, vt = vt }
                  count = count + 1
                end
              end
            end
          end
        end
      end
      a = a + n
    end
    if ri % 20 == 0 then print(string.format('[Lichii] scanned %d of %d regions...', ri, #regions)) end
  end
  return snap, count
end

function T.playerReset()
  T.pStage, T.pCand, T.pPrev = 0, nil, nil
  print('[Lichii] Player search reset. Stand still and run "Player search" again.')
end

function T.playerStep()
  if not T.base then showMessage('Guest memory not found yet.') return end
  local snap, count = snapshot()
  local old, keep, kept = T.pCand, {}, 0
  local prev = T.pPrev or {}
  if T.pStage == 0 then
    for obj, v in pairs(snap) do keep[obj] = v; kept = kept + 1 end
    print(string.format('[Lichii] Step 1 done: %d objects look like a position. Now WALK Link forward ~10 steps on flat ground, stop, and run "Player search" again.', kept))
    T.pStage = 1
  elseif T.pStage == 1 then
    for obj, v in pairs(snap) do
      local o = prev[obj]
      if o and math.abs(v.x - o.x) + math.abs(v.z - o.z) > 0.5 and math.abs(v.y - o.y) < 0.3 then
        keep[obj] = v; kept = kept + 1
      end
    end
    print(string.format('[Lichii] Step 2 done: %d objects moved with Link. Now STAND STILL for 3 seconds and run "Player search" again.', kept))
    T.pStage = 2
  else
    for obj, v in pairs(snap) do
      local o = prev[obj]
      if o and math.abs(v.x - o.x) + math.abs(v.z - o.z) < 0.001 and math.abs(v.y - o.y) < 0.001 then
        keep[obj] = v; kept = kept + 1
      end
    end
    print(string.format('[Lichii] Step 3 done: %d candidates left.', kept))
    local list = {}
    for obj, v in pairs(keep) do list[#list + 1] = { obj = obj, v = v } end
    table.sort(list, function(a, b) return a.obj < b.obj end)
    local al = getAddressList()
    for i, c in ipairs(list) do
      if i > 40 then print('[Lichii] ... more not shown') break end
      local g = c.obj - T.base
      print(string.format('[Lichii] object GUEST+%X  vtable %X  X %.2f  Y %.2f  Z %.2f',
        g, c.v.vt, c.v.x, c.v.y, c.v.z))
      if #list <= 20 then
        local rec = al.createMemoryRecord()
        rec.Description = string.format('Player? Y  obj GUEST+%X', g)
        rec.Type = vtSingle
        rec.Address = string.format('GUEST+%X', g + OBJ_Y)
      end
    end
    T.pStage = 2
  end
  T.pCand, T.pPrev = keep, snap
end

-- Menu.
local function buildMenu()
  local mf = getMainForm()
  local top = createMenuItem(mf.Menu)
  top.Caption = 'Lichii'
  local function add(caption, fn)
    local mi = createMenuItem(top)
    mi.Caption = caption
    mi.OnClick = fn
    top.add(mi)
    return mi
  end
  add('Attach to Lichii now', function() T.attach(true) end)
  add('Find guest memory again', function() if T.detect(false) then showMessage(T.info()) end end)
  add('Show guest memory info', function() showMessage(T.info()) end)
  add('Set scan range to guest memory', function() T.setScanRange() end)
  add('Make selected addresses GUEST-relative', T.makeRelative)
  add('Copy GUEST address of selected', T.copyGuest)
  add('List guest memory blocks', T.listBlocks)
  add('Dump guest memory to file...', T.dumpAsk)
  add('Dump locked (code) pages to file...', T.dumpLockedAsk)
  add('Dump emulator code cache to file', T.dumpJit)
  add('Player search (repeat 3 times)', T.playerStep)
  add('Player search: reset', T.playerReset)
  local auto = add('Auto attach', function(sender)
    T.autoAttach = not T.autoAttach
    sender.Checked = T.autoAttach
  end)
  auto.Checked = true
  mf.Menu.Items.insert(mf.miHelp.MenuIndex, top)
  return top
end

T.menu = buildMenu()
T.timer = createTimer(getMainForm())
T.timer.Interval = cfg.pollMs
T.timer.OnTimer = tick
T.timer.Enabled = true

function T.shutdown()
  pcall(function() T.timer.Enabled = false; T.timer.destroy() end)
  pcall(function() T.menu.destroy() end)
  T.clear()
end

print('[Lichii] Add-on loaded. Start Lichii and a game. The add-on attaches by itself.')
