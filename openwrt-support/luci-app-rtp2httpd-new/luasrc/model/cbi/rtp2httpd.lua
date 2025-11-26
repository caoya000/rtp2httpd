require ("nixio.fs")
require ("luci.sys")
require ("luci.http")
require ("luci.dispatcher")
require "luci.model.uci".cursor()

local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local port = uci:get("rtp2httpd", "@rtp2httpd[0]", "port") or "5140"
local status_page_path = uci:get("rtp2httpd", "@rtp2httpd[0]", "status_page_path") or "/status"
local player_page_path = uci:get("rtp2httpd", "@rtp2httpd[0]", "player_page_path") or "/player"
local router_ip = http.getenv("SERVER_NAME")
local button_staus_url = string.format("http://%s:%s%s", router_ip, port, status_page_path)
local button_player_url = string.format("http://%s:%s%s", router_ip, port, player_page_path)
local button_staus_text = translate("Open Status Dashboard")
local button_player_text = translate("Open Player Page")
local s_collecting_data = translate("Collecting data...")
local s_running = translate("RUNNING")
local s_not_running = translate("NOT RUNNING")

m = Map("rtp2httpd")
m.title = translate("Rtp2httpd")
m.description = translate("rtp2httpd converts RTP/UDP/RTSP media into http stream.")

-- 实时状态显示部分
s = m:section(SimpleSection)
s.anonymous = true

o = s:option(DummyValue, "_status")
o.rawhtml = true
local status_url = dispatcher.build_url("admin", "services", "rtp2httpd", "status")
o.value = string.format([[
	<div id="rtp2httpd_status"><em>%s</em></div>
	<script type="text/javascript">
		XHR.poll(3, '%s', null,
			function(x, data) {
				var tb = document.getElementById('rtp2httpd_status');
				if (data && tb) {
					var status_text = '';
					if (data.running) {
						status_text = '<b><font color="green">rtp2httpd - %s</font></b>';
					} else {
						status_text = '<b><font color="red">rtp2httpd - %s</font></b>';
					}
					tb.innerHTML = status_text;
				}
			}
		);
	</script>
]], s_collecting_data, status_url, s_running, s_not_running)

-- 主要配置部分
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
o.description = translate("Enable zero-copy send with MSG_ZEROCOPY for better performance. Requires kernel 4.14+. On supported devices, this can improve throughput and reduce CPU usage, especially under high concurrent load.")

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

o = s:option(Value, "buffer_pool_max_size", translate("Buffer Pool Max Size"))
o.datatype = "uinteger"
o.default = "65536"
o.description = translate("Maximum number of buffers in zero-copy pool. Default is 16384 (~24MB). Not recommended when running behind reverse proxies.")

o = s:option(Value, "external_m3u", translate("External M3U URL"))
o.default = "file:///www/iptv/tv.m3u"
o.description = translate("Fetch M3U playlist from a URL (file://, http://, https:// supported)")

o = s:option(Value, "external_m3u_update_interval", translate("External M3U update interval"))
o.datatype = "uinteger"
o.default = "86400"
o.description = translate("External M3U automatic update interval in seconds (default: 7200 = 2 hours). Set to 0 to disable automatic updates.")

o = s:option(Value, "mcast_rejoin_interval", translate("Multicast Rejoin Interval"))
o.datatype = "uinteger"
o.default = "0"
o.description = translate("Multicast rejoin interval in seconds (default 0, disabled). Set to a positive value (e.g., 60) to periodically rejoin multicast groups. Recommended value: 30-120 seconds (less than typical switch timeout of 260s). Only use when experiencing multicast stream interruptions.")

o = s:option(Value, "fcc_listen_port_range", translate("FCC Listen Port Range"))
o.default = "40000-40100"
o.description = translate("Local UDP port range for FCC client sockets (format: start-end, e.g., 40000-40100). Leave empty to use random ports.")

return m