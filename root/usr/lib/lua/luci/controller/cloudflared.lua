module("luci.controller.cloudflared", package.seeall)

function index()
    entry({"admin", "services", "cloudflared"},
        cbi("cloudflared/main"),
        _("Cloudflared"), 90).dependent = true
end
