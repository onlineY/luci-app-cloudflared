local http = require "luci.http"
local dsp  = require "luci.dispatcher"
local sys = require "luci.sys"
local fs  = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local jsonc = require "luci.jsonc"


-- ===== Helper Functions =====

local function shellquote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Auto-detect cloudflared binary path
local function find_binary(base)
    local custom = uci:get("cloudflared", "main", "cloudflared_path") or ""
    if custom ~= "" and fs.access(custom) then
        return custom
    end
    if fs.access(base .. "/cloudflared") then
        return base .. "/cloudflared"
    end
    local dir = fs.dir(base)
    if dir then
        for file in dir do
            if file:match("^cloudflared%-linux%-") then
                return base .. "/" .. file
            end
        end
    end
    if fs.access("/usr/bin/cloudflared") then
        return "/usr/bin/cloudflared"
    end
    return nil
end

-- Resolve cert path (custom or default)
local function resolve_cert(base)
    local custom = uci:get("cloudflared", "main", "cert_path") or ""
    if custom ~= "" then return custom end
    return base .. "/cert.pem"
end

-- Get tunnel ID from JSON filename
local function get_tunnel_info(base)
    local dir = fs.dir(base)
    if dir then
        for file in dir do
            if file:match("%.json$") then
                return file:match("([%w%-]+)%.json"), base .. "/" .. file
            end
        end
    end
    return nil, nil
end

-- Call Cloudflare API via curl
local function cf_api(method, path, token)
    if not token or token == "" then return nil end
    local cmd = string.format(
        "curl -s -X %s %s -H %s -H 'Content-Type: application/json' 2>/dev/null",
        method,
        shellquote("https://api.cloudflare.com/client/v4" .. path),
        shellquote("Authorization: Bearer " .. token)
    )
    local result = sys.exec(cmd)
    if not result or result == "" then return nil end
    return jsonc.parse(result)
end

local function get_zone_id(token, domain)
    if not domain or domain == "" then return nil end
    local data = cf_api("GET", "/zones?name=" .. domain, token)
    if data and data.success and data.result and #data.result > 0 then
        return data.result[1].id
    end
    return nil
end

local function fetch_tunnel_dns(token, tunnel_id, domain)
    local records = {}
    if not token or not tunnel_id or not domain then return records end

    local zone_id = get_zone_id(token, domain)
    if not zone_id then return records end

    local target = tunnel_id .. ".cfargotunnel.com"
    local data = cf_api("GET",
        "/zones/" .. zone_id .. "/dns_records?type=CNAME&per_page=100", token)
    if data and data.success and data.result then
        for _, r in ipairs(data.result) do
            if r.content == target then
                records[r.name] = { id = r.id, zone_id = zone_id }
            end
        end
    end
    return records
end

local function do_dns_sync()
    local b = uci:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
    local cfd_bin = find_binary(b) or "/usr/bin/cloudflared"
    local cert = resolve_cert(b)
    local tk = uci:get("cloudflared", "main", "api_token") or ""
    local domain = uci:get("cloudflared", "main", "domain") or ""
    local tid = get_tunnel_info(b)
    if not tid or tk == "" or domain == "" then return end

    local hosts = {}
    uci:foreach("cloudflared", "ingress", function(sec)
        if sec.hostname and sec.hostname ~= "" then
            hosts[sec.hostname] = true
        end
    end)

    local records = fetch_tunnel_dns(tk, tid, domain)

    for host, _ in pairs(hosts) do
        if not records[host] then
            sys.call(string.format(
                "%s tunnel --origincert %s route dns %s %s >/dev/null 2>&1",
                shellquote(cfd_bin), shellquote(cert),
                shellquote(tid), shellquote(host)))
        end
    end

    for host, info in pairs(records) do
        if not hosts[host] then
            cf_api("DELETE",
                "/zones/" .. info.zone_id .. "/dns_records/" .. info.id, tk)
        end
    end
end


-- ===== Map =====

m = Map("cloudflared",
        translate("Cloudflared Tunnel"),
        translate("Configure Cloudflare Tunnel"))


-- ===== Read paths from UCI =====

local base = uci:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
local bin_path = find_binary(base)
local cert_path = resolve_cert(base)


-- ===== Status detection =====

local status = sys.call("pgrep -f cloudflared >/dev/null 2>&1") == 0
local status_text

if status then
    status_text = "<span style='color:green;font-weight:bold'>" .. translate("Running") .. "</span>"
else
    status_text = "<span style='color:red;font-weight:bold'>" .. translate("Stopped") .. "</span>"
end

local warnings = ""

if not fs.access(base) then
    warnings = warnings .. "<br><span style='color:red'>⚠ " .. translate("Base path not found") .. "</span>"
end

if not fs.access(cert_path) then
    warnings = warnings .. "<br><span style='color:red'>⚠ " .. translate("cert.pem missing") .. "</span>"
end

local tunnel_id_val = get_tunnel_info(base)
if not tunnel_id_val then
    warnings = warnings .. "<br><span style='color:red'>⚠ " .. translate("Tunnel JSON missing") .. "</span>"
end

if not bin_path then
    warnings = warnings .. "<br><span style='color:red'>⚠ " .. translate("Cloudflared binary missing") .. "</span>"
end

m.description = translate("Cloudflared Status") .. ": " .. status_text .. warnings


-- ===== Main Settings =====

s = m:section(TypedSection, "main", translate("Main Settings"))
s.anonymous = true
s.addremove = false

local o_base = s:option(Value, "base_path", translate("Cloudflare Base Path"),
    translate("Directory for config.yml, cert.pem and tunnel JSON."))
o_base.default = "/opt/cloudflare"

local o_bin = s:option(Value, "cloudflared_path", translate("Cloudflared Binary Path"),
    translate("Leave empty to auto-detect from base path."))
o_bin.placeholder = bin_path or translate("Not found")
o_bin.rmempty = true

local o_cert = s:option(Value, "cert_path", translate("Certificate Path"),
    translate("Leave empty to use <base_path>/cert.pem."))
o_cert.placeholder = cert_path
o_cert.rmempty = true

local o_token = s:option(Value, "api_token", translate("Cloudflare API Token"))
o_token.password = true

local o_domain = s:option(Value, "domain", translate("Domain"),
    translate("Your root domain (e.g. example.com). Used for DNS record sync."))
o_domain.placeholder = "example.com"
o_domain.datatype = "hostname"


-- ===== DNS pre-load =====

local token = uci:get("cloudflared", "main", "api_token") or ""
local user_domain = uci:get("cloudflared", "main", "domain") or ""
local tunnel_id_display = get_tunnel_info(base)

local dns_records = {}
local dns_ready = false

if token ~= "" and user_domain ~= "" and tunnel_id_display then
    dns_records = fetch_tunnel_dns(token, tunnel_id_display, user_domain)
    dns_ready = true
end


-- ===== Ingress Rules =====

local ing_desc = translate("Save &amp; Apply will auto-sync DNS CNAME records.")
if not dns_ready then
    if token == "" then
        ing_desc = ing_desc .. "<br><em style='color:#888'>" .. translate("DNS status: API Token not configured.") .. "</em>"
    elseif user_domain == "" then
        ing_desc = ing_desc .. "<br><em style='color:#888'>" .. translate("DNS status: Domain not configured.") .. "</em>"
    elseif not tunnel_id_display then
        ing_desc = ing_desc .. "<br><em style='color:#888'>" .. translate("DNS status: Tunnel JSON not found.") .. "</em>"
    end
end

-- Detect orphaned DNS records
local orphaned = {}
if dns_ready then
    local ingress_set = {}
    uci:foreach("cloudflared", "ingress", function(sec)
        if sec.hostname and sec.hostname ~= "" then
            ingress_set[sec.hostname] = true
        end
    end)
    for name, _ in pairs(dns_records) do
        if not ingress_set[name] then
            orphaned[#orphaned + 1] = name
        end
    end
    if #orphaned > 0 then
        ing_desc = ing_desc ..
            "<br><span style='color:#e67e22;font-weight:bold'>⚠ " ..
            translate("Orphaned DNS (will be deleted on save)") .. ": " ..
            table.concat(orphaned, ", ") .. "</span>"
    end
end

-- Add manual DNS sync button in ingress description
if dns_ready then
    ing_desc = ing_desc ..
        '<br><button type="button" class="btn cbi-button cbi-button-apply" ' ..
        'style="margin-top:6px" id="btn_dns_sync" onclick="cfDnsSync()">' ..
        translate("Sync DNS Now") .. '</button>' ..
        '<script>' ..
        'function cfDnsSync(){' ..
            'var btn=document.getElementById("btn_dns_sync");' ..
            'btn.disabled=true;btn.innerText="' .. translate("Syncing...") .. '";' ..
            'var f=document.createElement("form");' ..
            'f.method="POST";f.action=window.location.pathname;' ..
            'var h=document.createElement("input");' ..
            'h.type="hidden";h.name="_dns_sync_action";h.value="1";f.appendChild(h);' ..
            'var tk=document.querySelector("input[name=token]");' ..
            'if(tk){var t=document.createElement("input");' ..
            't.type="hidden";t.name="token";t.value=tk.value;f.appendChild(t);}' ..
            'document.body.appendChild(f);f.submit();}' ..
        '</script>'
end

ing = m:section(TypedSection, "ingress", translate("Ingress Rules"), ing_desc)
ing.template = "cbi/tblsection"
ing.anonymous = true
ing.addremove = true

-- Subdomain column
hostname = ing:option(Value, "hostname", translate("Subdomain"))
hostname.placeholder = "example"

hostname.cfgvalue = function(self, section)
    local h = Value.cfgvalue(self, section) or ""
    if user_domain ~= "" then
        local suffix = "." .. user_domain
        if h:sub(-#suffix) == suffix then
            return h:sub(1, -#suffix - 1)
        end
    end
    return h
end

-- Domain suffix column (read-only)
local domain_suffix = ing:option(DummyValue, "_domain_suffix", "")
domain_suffix.rawhtml = true
domain_suffix.width = "auto"
domain_suffix.cfgvalue = function(self, section)
    if user_domain ~= "" then
        return "<strong>." .. user_domain .. "</strong>"
    end
    return "<em style='color:#aaa'>—</em>"
end

hostname.write = function(self, section, value)
    if user_domain ~= "" and value and value ~= "" then
        if not value:match("%.") then
            value = value .. "." .. user_domain
        end
    end
    Value.write(self, section, value)
end

-- Protocol column
local proto = ing:option(ListValue, "_protocol", translate("Protocol"))
proto:value("http", "HTTP")
proto:value("https", "HTTPS")
proto:value("tcp", "TCP")
proto:value("ssh", "SSH")
proto:value("rdp", "RDP")
proto:value("smb", "SMB")
proto.default = "http"

proto.cfgvalue = function(self, section)
    local svc = uci:get("cloudflared", section, "service") or ""
    return svc:match("^(%w+)://") or "http"
end

proto.write = function(self, section, value)
    local ip_val = http.formvalue("cbid.cloudflared." .. section .. "._ip") or ""
    local port_val = http.formvalue("cbid.cloudflared." .. section .. "._port") or ""
    if ip_val ~= "" and port_val ~= "" then
        uci:set("cloudflared", section, "service", value .. "://" .. ip_val .. ":" .. port_val)
    end
end

-- IP address column
local ip = ing:option(Value, "_ip", translate("IP Address"))
ip.placeholder = "192.168.31.1"
ip.datatype = "ipaddr"

ip.cfgvalue = function(self, section)
    local svc = uci:get("cloudflared", section, "service") or ""
    return svc:match("://([%d%.]+)") or ""
end

ip.write = function(self, section, value)
    local proto_val = http.formvalue("cbid.cloudflared." .. section .. "._protocol") or "http"
    local port_val = http.formvalue("cbid.cloudflared." .. section .. "._port") or ""
    if value ~= "" and port_val ~= "" then
        uci:set("cloudflared", section, "service", proto_val .. "://" .. value .. ":" .. port_val)
    end
end

-- Port column (assembles protocol://ip:port into service)
local port = ing:option(Value, "_port", translate("Port"))
port.placeholder = "8080"
port.datatype = "port"

port.cfgvalue = function(self, section)
    local svc = uci:get("cloudflared", section, "service") or ""
    return svc:match(":(%d+)$") or ""
end

port.write = function(self, section, value)
    local proto_val = http.formvalue("cbid.cloudflared." .. section .. "._protocol") or "http"
    local ip_val = http.formvalue("cbid.cloudflared." .. section .. "._ip") or ""
    local port_val = value or ""
    if ip_val ~= "" and port_val ~= "" then
        uci:set("cloudflared", section, "service", proto_val .. "://" .. ip_val .. ":" .. port_val)
    end
end

-- Common IP datalist injection
local ip_hints = uci:get_list("cloudflared", "main", "common_ips") or {}
if #ip_hints > 0 then
    local js_options = ""
    for _, v in ipairs(ip_hints) do
        js_options = js_options .. '<option value="' .. v .. '">'
    end
    local inject = ing:option(DummyValue, "_ip_datalist")
    inject.rawhtml = true
    inject.width = "0"
    inject.cfgvalue = function()
        return '<datalist id="cf-common-ips">' .. js_options .. '</datalist>' ..
            '<script>' ..
            'document.querySelectorAll("input[id*=\\\"._ip\\\"]").forEach(function(el){' ..
            'el.setAttribute("list","cf-common-ips");' ..
            '});' ..
            '</script>'
    end
end

-- DNS status column
local dns_col = ing:option(DummyValue, "_dns_status", translate("DNS"))
dns_col.rawhtml = true
dns_col.width = "120px"

function dns_col.cfgvalue(self, section)
    local host = uci:get("cloudflared", section, "hostname") or ""
    if host == "" then
        return "<span style='color:#ccc'>—</span>"
    end
    if not dns_ready then
        return "<span style='color:#aaa' title='" .. translate("Cannot check: missing config") .. "'>● " .. translate("Unknown") .. "</span>"
    end
    if dns_records[host] then
        return "<span style='color:#27ae60;font-weight:bold' title='" .. translate("CNAME record exists") .. "'>● " .. translate("Synced") .. "</span>"
    else
        return "<span style='color:#e67e22;font-weight:bold' title='" .. translate("Will be created on next save") .. "'>● " .. translate("Pending") .. "</span>"
    end
end


-- ===== Auto-generate config.yml + DNS sync =====

function m.on_after_commit(self)

    local base = uci:get("cloudflared", "main", "base_path") or "/opt/cloudflare"
    local cloudflared_bin = find_binary(base) or "/usr/bin/cloudflared"
    local cert = resolve_cert(base)
    local tk = uci:get("cloudflared", "main", "api_token") or ""

    -- Find tunnel json
    local tunnel_json
    local dir = fs.dir(base)
    if dir then
        for file in dir do
            if file:match("%.json$") then
                tunnel_json = base .. "/" .. file
                break
            end
        end
    end

    if not tunnel_json then return end

    local tunnel_id = tunnel_json:match("([%w%-]+)%.json")
    local config_path = base .. "/config.yml"

    -- Generate config.yml
    local yaml = ""
    yaml = yaml .. "tunnel: " .. tunnel_id .. "\n"
    yaml = yaml .. "credentials-file: " .. tunnel_json .. "\n"
    yaml = yaml .. "origincert: " .. cert .. "\n\n"
    yaml = yaml .. "ingress:\n"

    local ingress_hosts = {}

    uci:foreach("cloudflared", "ingress", function(sec)
        if sec.hostname and sec.service then
            yaml = yaml .. "  - hostname: " .. sec.hostname .. "\n"
            yaml = yaml .. "    service: " .. sec.service .. "\n\n"
            ingress_hosts[sec.hostname] = true
        end
    end)

    yaml = yaml .. "  - service: http_status:404\n"

    -- Rolling backup
    if fs.access(config_path) then
        if fs.access(config_path .. ".bak2") then
            fs.remove(config_path .. ".bak2")
        end
        if fs.access(config_path .. ".bak1") then
            fs.rename(config_path .. ".bak1", config_path .. ".bak2")
        end
        fs.rename(config_path, config_path .. ".bak1")
    end

    fs.writefile(config_path, yaml)

    -- DNS incremental sync
    local domain = uci:get("cloudflared", "main", "domain") or ""
    if tk ~= "" and tunnel_id and domain ~= "" then
        local dns_records = fetch_tunnel_dns(tk, tunnel_id, domain)

        -- Create missing DNS records
        for host, _ in pairs(ingress_hosts) do
            if not dns_records[host] then
                sys.call(string.format(
                    "%s tunnel --origincert %s route dns %s %s >/dev/null 2>&1",
                    shellquote(cloudflared_bin),
                    shellquote(cert),
                    shellquote(tunnel_id),
                    shellquote(host)
                ))
            end
        end

        -- Delete orphaned DNS records
        for host, info in pairs(dns_records) do
            if not ingress_hosts[host] then
                cf_api("DELETE",
                    "/zones/" .. info.zone_id .. "/dns_records/" .. info.id, tk)
            end
        end
    end

    -- Restart service
    sys.call("/etc/init.d/cloudflared restart >/dev/null 2>&1")
end


-- ===== Service Control =====

local ctrl = m:section(TypedSection, "main", translate("Service Control"))
ctrl.anonymous = true
ctrl.addremove = false

local btn_start = ctrl:option(Button, "_start")
btn_start.title = translate("Start Service")
btn_start.inputtitle = translate("Start")
btn_start.inputstyle = "apply"

function btn_start.write(self, section)
    sys.call("/etc/init.d/cloudflared start >/dev/null 2>&1")
    http.redirect(dsp.build_url("admin/services/cloudflared"))
end

local btn_stop = ctrl:option(Button, "_stop")
btn_stop.title = translate("Stop Service")
btn_stop.inputtitle = translate("Stop")
btn_stop.inputstyle = "reset"

function btn_stop.write(self, section)
    sys.call("/etc/init.d/cloudflared stop >/dev/null 2>&1")
    http.redirect(dsp.build_url("admin/services/cloudflared"))
end

local btn_restart = ctrl:option(Button, "_restart")
btn_restart.title = translate("Restart Service")
btn_restart.inputtitle = translate("Restart")
btn_restart.inputstyle = "reload"

function btn_restart.write(self, section)
    sys.call("/etc/init.d/cloudflared restart >/dev/null 2>&1")
    http.redirect(dsp.build_url("admin/services/cloudflared"))
end

-- Handle manual DNS sync POST
if http.formvalue("_dns_sync_action") then
    do_dns_sync()
    http.redirect(dsp.build_url("admin/services/cloudflared"))
end

return m
