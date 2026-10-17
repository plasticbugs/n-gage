local mac = manager.machine
local f = io.open(os.getenv("OUT") or "ports.txt", "w")
for pname, port in pairs(mac.ioport.ports) do
  f:write(string.format("PORT %s\n", pname))
  for fname, field in pairs(port.fields) do
    f:write(string.format("   %-28s mask=%04x defvalue=%04x\n", fname, field.mask, field.defvalue))
  end
end
f:close()
mac:exit()
