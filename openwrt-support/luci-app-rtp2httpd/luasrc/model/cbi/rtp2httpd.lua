require ("nixio.fs")
require ("luci.sys")
require ("luci.http")
require ("luci.dispatcher")
require "luci.model.uci".cursor()

local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local port = uci:get("rtp2httpd", "@rtp2httpd[0]", "port") or "5140"
local status_page_path = uci:get("rtp2httpd", "@rtp2httpd[0]", "status_page_path") or "/status"
local player_page_path = uci:get("rtp2httpd", "@rtp2httpd[0]", "player_page_path") or "/player"
local router_ip = http.getenv("SERVER_NAME")
local button_staus_url = string.format("http://%s:%s%s", router_ip, port, status_page_path)
local button_player_url = string.format("http://%s:%s%s", router_ip, port, player_page_path)
local button_staus_text = translate("Open Status Dashboard")
local button_player_text = translate("Open Player Page")

m = Map("rtp2httpd")
m.title = translate("Rtp2httpd")
m.description = translate("rtp2httpd converts RTP/UDP/RTSP media into http stream.")

m:section(SimpleSection).template  = "rtp2httpd/rtp2httpd_status"

s = m:section(TypedSection, "rtp2httpd")
s.addremove = true
s.anonymous = false
s.addbtntitle = translate("Add instance")

o = s:option(Flag, "disabled", translate("Enable"))
o.enabled = "0"
o.disabled = "1"
o.default = o.disabled
o.rmempty = false

o = s:option(Flag, "respawn", translate("Respawn"))
o.enabled = "1"
o.disabled = "0"
o.default = o.enabled
o.rmempty = false
o.description = translate("Auto restart after crash")

o = s:option(DummyValue, "status_page_dummy", translate("Status Dashboard"))
o.value = string.format(
    '<a href="%s" target="_blank" rel="noopener noreferrer" class="cbi-button cbi-button-action">%s</a>',
    button_staus_url,
    button_staus_text
)
o.rawhtml = true

o = s:option(DummyValue, "status_player_dummy", translate("Player Page"))
o.value = string.format(
    '<a href="%s" target="_blank" rel="noopener noreferrer" class="cbi-button cbi-button-action">%s</a>',
    button_player_url,
    button_player_text
)
o.rawhtml = true

o = s:option(Flag, "use_config_file", translate("Use Config File"))
o.enabled = "1"
o.disabled = "0"
o.default = o.disabled
o.rmempty = false
o.description = translate("Use config file instead of individual options")

o = s:option(Flag, "zerocopy_on_send", translate("Enable zero-copy"))
o.enabled = "1"
o.disabled = "0"
o.default = o.disabled
o.rmempty = false
o.description = translate("Enable zero-copy send with MSG_ZEROCOPY for better performance. Requires kernel 4.14+ (MSG_ZEROCOPY support).")

o = s:option(Value, "port", translate("Port"))
o.datatype = "uinteger"
o.default = "5140"
o.rmempty = false

o = s:option(ListValue, "verbose", translate("Logging level"))
o:value("0", "FATAL")
o:value("1", "ERROR")
o:value("2", "WARN")
o:value("3", "INFO")
o:value("4", "DEBUG")
o.default = "3"

o = s:option(ListValue, "upstream_interface", translate("Source interface"))
local upstream_interface = luci.sys.exec("ls -l /sys/class/net/ 2>/dev/null |awk '{print $9}' 2>/dev/null")
for upstream_interface in string.gmatch(upstream_interface, "%S+") do
   o:value(upstream_interface)
end
o:value("", translate("Disable"))
o.default = ""
o.description = translate("Default interface for all upstream traffic (multicast, FCC and RTSP).")

o = s:option(Value, "workers", translate("Workers"))
o.datatype = "uinteger"
o.default = "1"
o.description = translate("Number of worker processes. Set to 1 for resource-constrained devices, or CPU cores for best performance.")

o = s:option(Value, "maxclients", translate("Max clients allowed"))
o.datatype = "uinteger"
o.default = "10"

o = s:option(Value, "buffer_pool_max_size", translate("Max pool buffer"))
o.datatype = "uinteger"
o.default = "16384"
o.description = translate("Maximum number of buffers in zero-copy pool. Default is 16384 (~24MB). Not recommended when running behind reverse proxies.")

o = s:option(Value, "external_m3u", translate("External M3U URL"))
o.default = "file:///mnt/mmcblk0p7/rtp2httpd/tv.m3u"

o = s:option(Value, "external_m3u_update_interval", translate("External M3U update interval"))
o.datatype = "uinteger"
o.default = "86400"
o.description = translate("External M3U automatic update interval in seconds (default: 86400 = 24 hours). Set to 0 to disable automatic updates.")

return m