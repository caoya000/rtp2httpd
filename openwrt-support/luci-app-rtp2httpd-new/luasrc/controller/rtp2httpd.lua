module("luci.controller.rtp2httpd", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/rtp2httpd") then
        return
    end
    
    entry({"admin", "services", "rtp2httpd"}, cbi("rtp2httpd/rtp2httpd"), _("Rtp2httpd"), 60).dependent = true
    entry({"admin", "services", "rtp2httpd", "status"}, call("act_status")).leaf=true
end

function act_status()
    local e={}
    e.running=luci.sys.call("pgrep rtp2httpd >/dev/null")==0
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end