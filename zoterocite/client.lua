local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")

local API = "https://api.zotero.org/"
local SYNC_DIR = DataStorage:getDataDir() .. "/zotero/"

local Client = {
    settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/zoterocite.lua"),
}

local templates = {}

function Client.request(target, opts)
    opts = opts or {}
    for _ = 1, 5 do
        local chunks, headers = {}, {}
        for k, v in pairs(opts.headers or {}) do headers[k] = v end
        if opts.body then
            headers["content-type"] = "application/json"
            headers["content-length"] = tostring(#opts.body)
        end
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, res, code, resp_headers = pcall(http.request, {
            url = target,
            method = opts.method or "GET",
            headers = headers,
            redirect = false,
            source = opts.body and ltn12.source.string(opts.body),
            sink = ltn12.sink.table(chunks),
        })
        socketutil:reset_timeout()
        if not ok then return nil, tostring(res) end
        if res ~= 1 then return nil, tostring(code) end
        code = tonumber(code)
        local location = resp_headers and resp_headers.location
        if not (code >= 300 and code < 400 and location) then
            return code, table.concat(chunks), resp_headers
        end
        target = url.absolute(target, location)
    end
    return nil, "Too many redirects"
end

function Client.getJSON(target, headers)
    local code, body = Client.request(target, { headers = headers })
    if not code then return nil, body end
    if code ~= 200 then return nil, "HTTP " .. code, code end
    local data = rapidjson.decode(body)
    if data == nil then return nil, "Invalid JSON response" end
    return data
end

local function prefix(library_type, id)
    return (library_type == "group" and "groups/" or "users/") .. id
end

local function headers(creds)
    return { ["zotero-api-key"] = creds.key, ["zotero-api-version"] = "3" }
end

local function syncSettings()
    if not lfs.attributes(SYNC_DIR .. "meta.lua", "mode") then return nil end
    return LuaSettings:open(SYNC_DIR .. "meta.lua")
end

function Client.ownCredentials()
    local s = Client.settings
    local key, id = s:readSetting("api_key"), s:readSetting("library_id")
    if not key or key == "" or not id or id == "" then return nil end
    return { key = key, prefix = prefix(s:readSetting("library_type", "user"), id), source = "own" }
end

-- Read-only reuse of zotero.koplugin's account so a single key serves both plugins.
function Client.syncCredentials()
    local meta = syncSettings()
    if not meta then return nil end
    local library_type = meta:readSetting("library_type", "user")
    local key = meta:readSetting("api_key")
    local id = meta:readSetting(library_type == "group" and "group_id" or "user_id")
    if not key or key == "" or not id or id == "" then return nil end
    return { key = key, prefix = prefix(library_type, id), source = "sync" }
end

function Client.credentials()
    return Client.ownCredentials() or Client.syncCredentials()
end

function Client.setOwnCredentials(key, library_type, id)
    local s = Client.settings
    s:saveSetting("api_key", key)
    s:saveSetting("library_type", library_type)
    s:saveSetting("library_id", id)
    s:flush()
end

function Client.clearOwnCredentials()
    local s = Client.settings
    s:delSetting("api_key")
    s:delSetting("library_type")
    s:delSetting("library_id")
    s:flush()
end

function Client.lastCollection(creds)
    return Client.settings:readSetting("last_collection", {})[creds.prefix]
end

function Client.setLastCollection(creds, collection)
    local last = Client.settings:readSetting("last_collection", {})
    last[creds.prefix] = collection and { key = collection.key, name = collection.name } or nil
    Client.settings:saveSetting("last_collection", last)
    Client.settings:flush()
end

local function tree(list)
    local known, children = {}, {}
    for _, c in ipairs(list) do known[c.key] = true end
    for _, c in ipairs(list) do
        local parent = known[c.parent] and c.parent or false
        children[parent] = children[parent] or {}
        table.insert(children[parent], c)
    end
    local out = {}
    local function walk(parent, depth)
        local kids = children[parent]
        if not kids then return end
        table.sort(kids, function(a, b) return a.name:lower() < b.name:lower() end)
        for _, c in ipairs(kids) do
            c.depth = depth
            table.insert(out, c)
            walk(c.key, depth + 1)
        end
    end
    walk(false, 0)
    return out
end

function Client.localCollections(creds)
    local meta = syncSettings()
    if not meta or meta:readSetting("cache_library") ~= creds.prefix then return nil end
    local f = io.open(SYNC_DIR .. "collections.json", "r")
    if not f then return nil end
    local data = rapidjson.decode(f:read("*a"))
    f:close()
    if type(data) ~= "table" then return nil end
    local list = {}
    for key, c in pairs(data) do
        table.insert(list, { key = key, name = c.data.name, parent = c.data.parentCollection })
    end
    return tree(list)
end

function Client.fetchCollections(creds)
    local list, start = {}, 0
    repeat
        local page, err = Client.getJSON(API .. creds.prefix .. "/collections?limit=100&start=" .. start, headers(creds))
        if not page then return nil, err end
        for _, c in ipairs(page) do
            table.insert(list, { key = c.key, name = c.data.name, parent = c.data.parentCollection })
        end
        start = start + 100
    until #page < 100
    return tree(list)
end

function Client.template(item_type)
    if templates[item_type] == nil then
        local fields = Client.getJSON(API .. "items/new?itemType=" .. item_type)
        local creator_types = Client.getJSON(API .. "itemTypeCreatorTypes?itemType=" .. item_type)
        templates[item_type] = false
        if fields and creator_types and creator_types[1] then
            local allowed = {}
            for _, c in ipairs(creator_types) do allowed[c.creatorType] = true end
            templates[item_type] = { fields = fields, creator_types = allowed, primary = creator_types[1].creatorType }
        end
    end
    return templates[item_type] or nil
end

local function normalize(title)
    return (title:lower():gsub("[^%w]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function matches(data, doi, title)
    if doi ~= "" and type(data.DOI) == "string" and data.DOI:lower() == doi then return true end
    if doi ~= "" and type(data.extra) == "string" and data.extra:lower():find("doi: " .. doi, 1, true) then return true end
    return title ~= "" and type(data.title) == "string" and normalize(data.title) == title
end

local function localItems(creds)
    local meta = syncSettings()
    if not meta or meta:readSetting("cache_library") ~= creds.prefix then return nil end
    local f = io.open(SYNC_DIR .. "items.json", "r")
    if not f then return nil end
    local data = rapidjson.decode(f:read("*a"))
    f:close()
    return type(data) == "table" and data or nil
end

-- The web API quick search does not index DOI, so prefer the synced cache and fall back to a title search.
function Client.findDuplicate(creds, item)
    local doi, title = (item.DOI or ""):lower(), normalize(item.title or "")
    local cached = localItems(creds)
    if cached then
        for _, it in pairs(cached) do
            if it.data.itemType ~= "attachment" and it.data.itemType ~= "note" and matches(it.data, doi, title) then
                return it
            end
        end
    end
    local words = {}
    for word in title:gmatch("%w%w%w+") do
        if #words < 8 then table.insert(words, word) end
    end
    if #words == 0 then return nil end
    local target = API .. creds.prefix .. "/items/top?qmode=titleCreatorYear&limit=25&q=" .. util.urlEncode(table.concat(words, " "))
    for _, it in ipairs(Client.getJSON(target, headers(creds)) or {}) do
        if matches(it.data, doi, title) then return it end
    end
end

local function writeToken()
    local parts = {}
    for i = 1, 4 do parts[i] = string.format("%08x", math.random(0, 0x7fffffff)) end
    return table.concat(parts)
end

function Client.createItem(creds, item, collection_key)
    item.collections = rapidjson.array(collection_key and { collection_key } or {})
    local h = headers(creds)
    h["zotero-write-token"] = writeToken()
    local code, body = Client.request(API .. creds.prefix .. "/items", {
        method = "POST",
        headers = h,
        body = rapidjson.encode(rapidjson.array({ item })),
    })
    if not code then return nil, body end
    if code == 403 then return nil, "The API key has no write access to " .. creds.prefix end
    if code ~= 200 then return nil, "HTTP " .. code .. ": " .. tostring(body) end
    local res = rapidjson.decode(body)
    if type(res) ~= "table" then return nil, "Invalid JSON response" end
    local failed = res.failed and res.failed["0"]
    if failed then return nil, tostring(failed.message) end
    local success = res.successful and res.successful["0"]
    return success and success.key or res.success and res.success["0"]
end

math.randomseed(os.time())

return Client
