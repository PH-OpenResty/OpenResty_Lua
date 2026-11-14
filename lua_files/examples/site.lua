-- Public example only. Copy into your runtime sites directory after configuration.
return {
    name = "demo",
    enabled = false,
    server_names = { "www.example.com" },
    root = "",
    upstream = "127.0.0.1:8080",
    cache = { layer = "off" },
    ssl = { cert = "", key = "" },
    rate_limit = { enabled = false, req_per_sec = 0, burst = 0 },
    waf = { enabled = true, groups = { "sqli", "xss" }, threshold = 5 },
}
