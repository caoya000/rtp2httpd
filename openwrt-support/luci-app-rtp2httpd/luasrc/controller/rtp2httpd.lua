
module("luci.controller.rtp2httpd", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/rtp2httpd") then
		return
	end

	local page
	page = entry({"admin", "services", "rtp2httpd"}, cbi("rtp2httpd"), _("Rtp2httpd"), 60)
	page.dependent = true
	page = entry({"admin", "services", "rtp2httpd", "status"}, call("act_status"))
	page.leaf = true
end

local function is_running()
	return luci.sys.call("pidof rtp2httpd >/dev/null") == 0
end

function act_status()
	local e = {}
	e.running = is_running()
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
