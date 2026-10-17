-- Dump the whole video state of mycore at chosen frames, plus MAME's own
-- snapshot of the same frame, so tools/render_model.py can be checked against
-- it pixel for pixel.
--
--   DUMPFRAMES=1000,2000 DUMP_DIR=... tools/mame.sh -seconds_to_run 40 \
--       -snapshot_directory ... -autoboot_script tools/dump_state.lua
--
-- One binary file per frame, little-endian:
--   magic "MWST", u32 version=1, u32 frame
--   u16 ctrl[16]
--   u16 vram[32768]        400000..40FFFF
--   u16 spriteram[3264]    410000..41197F
--   u16 scrollram[1024]    413800..413FFF
--   u16 palette[4096]      600000..601FFF
--   u16 fb[2][224][160]    both framebuffer pages over the visible window
--                          (x 0..319 as 160 words, y 16..239), page 0 first
--   u32 pixels[224][320]   MAME's own output for the frame, straight from
--                          screen:pixels(): the frame the renderer must match
--
-- A lite dump (LITE="from-to") is the same header with magic "MWSL" followed
-- by ctrl[16] and spriteram[3264], and nothing else.
--
-- The framebuffer is read through the chip's own CPU-side handler, which is
-- the only way Lua can see it; it exposes 8 bits per pixel where the chip
-- stores 10, so the two colour-code high bits are lost here.  That is enough
-- to check the sprite rasteriser's shapes and positions; the composite check
-- uses the full value the renderer computes for itself.

local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local dir = os.getenv("DUMP_DIR") or "."

local want = {}
for n in string.gmatch(os.getenv("DUMPFRAMES") or "1000", "%d+") do
  want[tonumber(n)] = true
end
local COIN  = tonumber(os.getenv("COIN")  or "200")
local START = tonumber(os.getenv("START") or "260")

-- LITE="from-to" also writes a small dump every frame in that range: just the
-- control registers and sprite RAM, which is all the framebuffer replay in
-- tools/vcu_model.py needs to follow a never-cleared framebuffer across
-- hundreds of frames without storing a full state for each.
local lite_from, lite_to = 0, -1
do
  local a, b = string.match(os.getenv("LITE") or "", "(%d+)-(%d+)")
  if a then lite_from, lite_to = tonumber(a), tonumber(b) end
end

local frames = 0

-- FLIP=1 turns the Flip Screen DIP on before the game boots, which is the
-- only way to make it set video control bit 4.
if os.getenv("FLIP") == "1" then
  mac.ioport.ports[":DSWA"].fields["Flip Screen"]:set_value(0)   -- ACTIVE_LOW
end

local function u16(f, v) f:write(string.char(v & 0xff, (v >> 8) & 0xff)) end
local function u32(f, v)
  f:write(string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff))
end

local function block(f, base, words)
  local t = {}
  for i = 0, words - 1 do
    local v = sp:read_u16(base + i * 2)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t == 4096 then f:write(table.concat(t)); t = {} end
  end
  if #t > 0 then f:write(table.concat(t)) end
end

local function dump(n)
  local f = io.open(string.format("%s/state_%04d.bin", dir, n), "wb")
  f:write("MWST"); u32(f, 1); u32(f, n)
  block(f, 0x418000, 16)        -- control registers
  block(f, 0x400000, 32768)     -- VRAM
  block(f, 0x410000, 3264)      -- sprite RAM
  block(f, 0x413800, 1024)      -- scroll RAM
  block(f, 0x600000, 4096)      -- palette
  for page = 0, 1 do            -- framebuffer, visible window only
    for y = 16, 239 do
      block(f, 0x440000 + (page * 256 + y) * 512, 160)
    end
  end
  f:write(mac.screens[":screen"]:pixels())
  f:close()
end

local function dump_lite(n)
  local f = io.open(string.format("%s/lite_%04d.bin", dir, n), "wb")
  f:write("MWSL"); u32(f, 1); u32(f, n)
  block(f, 0x418000, 16)        -- control registers
  block(f, 0x410000, 3264)      -- sprite RAM
  f:close()
end

local function press(port, field, on)
  mac.ioport.ports[port].fields[field]:set_value(on and 0 or 1)  -- ACTIVE_LOW
end

_G.KEEP = {}
-- MAME has been seen to end a headless run early and silently, so record how
-- far it actually got; tools/dump_states.sh checks this and retries.
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  local f = io.open(dir .. "/run.txt", "w")
  f:write(string.format("frames %d\n", frames))
  for n in pairs(want) do
    local h = io.open(string.format("%s/state_%04d.bin", dir, n), "rb")
    f:write(string.format("want %d %s\n", n, h and "ok" or "MISSING"))
    if h then h:close() end
  end
  f:close()
end)
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == COIN      then press(":IN2", "Coin 1", true)  end
  if frames == COIN + 10 then press(":IN2", "Coin 1", false) end
  if frames == START     then press(":IN2", "1 Player Start", true)  end
  if frames == START + 10 then press(":IN2", "1 Player Start", false) end
  if frames >= lite_from and frames <= lite_to then dump_lite(frames) end
  if want[frames] then
    dump(frames)
    mac.screens[":screen"]:snapshot(string.format("%s/mame_%04d.png", dir, frames))
  end
end)
