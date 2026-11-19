local rapidjson = require("rapidjson")
local util = require("util")

local Doi = {}

-- Crossref returns its own type names, DataCite returns CSL ones.
local TYPES = {
    ["journal-article"] = "journalArticle",
    ["article-journal"] = "journalArticle",
    ["article-magazine"] = "magazineArticle",
    ["article-newspaper"] = "newspaperArticle",
    book = "book",
    monograph = "book",
    ["edited-book"] = "book",
    ["reference-book"] = "book",
    chapter = "bookSection",
    ["book-chapter"] = "bookSection",
    ["book-section"] = "bookSection",
    ["book-part"] = "bookSection",
    ["paper-conference"] = "conferencePaper",
    ["proceedings-article"] = "conferencePaper",
    report = "report",
    ["report-component"] = "report",
    thesis = "thesis",
    dissertation = "thesis",
    dataset = "dataset",
    software = "computerProgram",
    ["posted-content"] = "preprint",
    article = "preprint",
    webpage = "webpage",
    ["entry-encyclopedia"] = "encyclopediaArticle",
    ["reference-entry"] = "encyclopediaArticle",
    ["entry-dictionary"] = "dictionaryEntry",
    standard = "standard",
    patent = "patent",
}

-- CSL keys, then the Zotero fields that may hold them; the first one valid for the item type wins.
local FIELDS = {
    { { "title" }, { "title" } },
    { { "container-title" }, { "publicationTitle", "bookTitle", "proceedingsTitle", "websiteTitle",
        "encyclopediaTitle", "dictionaryTitle", "blogTitle", "forumTitle" } },
    { { "container-title-short", "short-container-title" }, { "journalAbbreviation" } },
    { { "collection-title" }, { "series" } },
    { { "volume" }, { "volume" } },
    { { "issue" }, { "issue" } },
    { { "page" }, { "pages" } },
    { { "number-of-pages" }, { "numPages" } },
    { { "edition" }, { "edition" } },
    { { "publisher" }, { "publisher", "repository", "company", "institution", "university" } },
    { { "publisher-place" }, { "place" } },
    { { "event-title", "event" }, { "conferenceName" } },
    { { "ISSN" }, { "ISSN" } },
    { { "ISBN" }, { "ISBN" } },
    { { "language" }, { "language" } },
    { { "version" }, { "versionNumber" } },
    { { "DOI" }, { "DOI" } },
}

local function str(v)
    if type(v) == "table" then v = v[1] end
    if v == nil or v == rapidjson.null then return nil end
    v = util.htmlEntitiesToUtf8(tostring(v))
    if v == "" then return nil end
    return v
end

function Doi.extract(link)
    local decoded = util.urlDecode(link)
    local doi = decoded:match("^[Dd][Oo][Ii]:%s*(10%.%d+/.+)$")
    if not doi then
        local host, path = decoded:match("^https?://([^/]+)/(.+)$")
        if not host then return nil end
        host = host:lower()
        if host ~= "doi.org" and not host:match("%.doi%.org$") then return nil end
        doi = path:match("^(10%.%d+/.+)$")
    end
    if not doi then return nil end
    doi = doi:gsub("[?#].*$", ""):gsub("[%.,;]+$", "")
    return doi
end

function Doi.resolve(client, doi)
    local encoded = doi:gsub("[^%w%-%._~/:;()%[%]<>]", function(c) return string.format("%%%02X", c:byte()) end)
    local csl, err, code = client.getJSON("https://doi.org/" .. encoded, {
        accept = "application/vnd.citationstyles.csl+json",
    })
    if code == 404 then return nil, "DOI not found: " .. doi end
    return csl, err
end

local function date(csl)
    local d = csl.issued
    if type(d) ~= "table" then return nil end
    local parts = type(d["date-parts"]) == "table" and d["date-parts"][1]
    local year = type(parts) == "table" and tonumber(parts[1])
    if not year then return str(d.literal) or str(d.raw) end
    local out = tostring(year)
    local month, day = tonumber(parts[2]), tonumber(parts[3])
    if month then out = out .. string.format("-%02d", month) end
    if month and day then out = out .. string.format("-%02d", day) end
    return out
end

local function abstract(text)
    text = str(text)
    if not text then return nil end
    text = text:gsub("<jats:title>.-</jats:title>", "")
        :gsub("</?jats:p[^>]*>", "\n")
        :gsub("<[^>]+>", "")
    text = util.htmlEntitiesToUtf8(text)
    local paragraphs = {}
    for line in text:gmatch("[^\n]+") do
        line = line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        if line ~= "" then table.insert(paragraphs, line) end
    end
    return table.concat(paragraphs, "\n\n")
end

local function creators(csl, tpl)
    local out = rapidjson.array({})
    for _, role in ipairs({ "author", "editor", "translator" }) do
        local ctype = role == "author" and tpl.primary
            or tpl.creator_types[role] and role
            or tpl.creator_types.contributor and "contributor"
        for _, p in ipairs(ctype and type(csl[role]) == "table" and csl[role] or {}) do
            local family, given = str(p.family), str(p.given)
            if family and given then
                table.insert(out, { creatorType = ctype, lastName = family, firstName = given })
            elseif family or str(p.literal) or str(p.name) then
                table.insert(out, { creatorType = ctype, name = family or str(p.literal) or str(p.name) })
            end
        end
    end
    return out
end

function Doi.toZotero(csl, template)
    local item_type = TYPES[csl.type] or "document"
    local tpl = template(item_type)
    if not tpl and item_type ~= "document" then
        item_type = "document"
        tpl = template(item_type)
    end
    if not tpl then return nil, "Could not load the Zotero item template" end

    local item = {}
    for k, v in pairs(tpl.fields) do item[k] = v end
    for _, m in ipairs(FIELDS) do
        local value
        for _, key in ipairs(m[1]) do value = value or str(csl[key]) end
        for _, field in ipairs(value and m[2] or {}) do
            if item[field] ~= nil then
                item[field] = value
                break
            end
        end
    end
    item.creators = creators(csl, tpl)
    if item.date ~= nil then item.date = date(csl) or "" end
    if item.abstractNote ~= nil then item.abstractNote = abstract(csl.abstract) or "" end
    if item.ISSN ~= nil and type(csl.ISSN) == "table" then item.ISSN = table.concat(csl.ISSN, ", ") end
    local link = str(csl.URL)
    if item.url ~= nil and link and not link:match("doi%.org/") then item.url = link end
    if item.DOI == nil and item.extra ~= nil and str(csl.DOI) then item.extra = "DOI: " .. str(csl.DOI) end
    return item
end

return Doi
