local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Client = require("zoterocite/client")
local Doi = require("zoterocite/doi")

local ZoteroCite = WidgetContainer:extend{
    name = "zoterocite",
}

function ZoteroCite:init()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("15_zoterocite", function(this)
            return {
                text = _("Add to Zotero"),
                show_in_highlight_dialog_func = function()
                    local text = this.selected_text.text
                    return Doi.find(text) ~= nil or Doi.isCitation(text)
                end,
                callback = function()
                    local text = this.selected_text.text
                    local doi = Doi.find(text)
                    this:onClose()
                    if doi then return self:lookup(doi) end
                    self:search(text)
                end,
            }
        end)
    end
    if not self.ui.link then return end
    self.ui.link:registerScheme("doi")
    self.ui.link:addToExternalLinkDialog("15_zoterocite", function(link_module, link_url)
        return {
            text = _("Add to Zotero"),
            callback = function()
                UIManager:close(link_module.external_link_dialog)
                self:lookup(Doi.extract(link_url))
            end,
            show_in_dialog_func = function(url) return Doi.extract(url) ~= nil end,
        }
    end)
end

local function showError(text)
    UIManager:show(InfoMessage:new{ text = text, icon = "notice-warning" })
end

local function withProgress(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, result, err = pcall(fn)
    UIManager:close(msg)
    if ok then return result, err end
    logger.warn("ZoteroCite:", result)
    return nil, tostring(result)
end

function ZoteroCite:lookup(doi)
    local creds = Client.credentials()
    if not creds then
        return showError(_("No Zotero account configured. Set an API key in Zotero cite settings, or configure the Zotero plugin."))
    end
    NetworkMgr:runWhenOnline(function()
        local entry, err = withProgress(T(_("Looking up %1…"), doi), function()
            local csl, e = Doi.resolve(Client, doi)
            if not csl then return nil, e end
            local item, e2 = Doi.toZotero(csl, Client.template)
            if not item then return nil, e2 end
            return { item = item, duplicate = Client.findDuplicate(creds, item) }
        end)
        if not entry then return showError(T(_("Could not look up %1:\n%2"), doi, err)) end
        entry.creds = creds
        entry.collection = Client.lastCollection(creds)
        self:showPreview(entry)
    end)
end

function ZoteroCite:search(text)
    NetworkMgr:runWhenOnline(function()
        local matches, err = withProgress(_("Searching Crossref…"), function()
            return Doi.search(Client, text)
        end)
        if not matches then return showError(T(_("Could not search Crossref:\n%1"), err)) end
        if #matches == 0 then return showError(_("No matching reference found on Crossref.")) end
        local dialog
        local buttons = {}
        for _, m in ipairs(matches) do
            table.insert(buttons, {
                {
                    text = m.label,
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        self:lookup(m.doi)
                    end,
                },
            })
        end
        table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
        dialog = ButtonDialog:new{
            title = _("Select reference"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
    end)
end

local function describe(item)
    local names = {}
    for i, c in ipairs(item.creators) do
        if i > 10 then
            table.insert(names, _("et al."))
            break
        end
        table.insert(names, c.name or (c.firstName .. " " .. c.lastName))
    end
    local source = item.publicationTitle or item.bookTitle or item.proceedingsTitle or item.publisher or ""
    local details = {}
    if item.volume and item.volume ~= "" then
        table.insert(details, item.volume .. (item.issue ~= "" and item.issue and "(" .. item.issue .. ")" or ""))
    end
    if item.pages and item.pages ~= "" then table.insert(details, item.pages) end
    if item.date and item.date ~= "" then table.insert(details, item.date) end
    if source ~= "" then table.insert(details, 1, source) end

    local lines = { item.title ~= "" and item.title or _("(untitled)"), "" }
    if #names > 0 then table.insert(lines, table.concat(names, ", ")) end
    if #details > 0 then table.insert(lines, table.concat(details, ", ")) end
    table.insert(lines, T(_("Type: %1"), item.itemType))
    if item.DOI then table.insert(lines, "DOI: " .. item.DOI) end
    if item.abstractNote and item.abstractNote ~= "" then
        table.insert(lines, "")
        table.insert(lines, item.abstractNote)
    end
    return table.concat(lines, "\n")
end

local function collectionLabel(collection)
    return T(_("Collection: %1"), collection and collection.name or _("none"))
end

local function duplicateNotice(entry)
    local data = entry.duplicate.data
    local lines = { _("ALREADY IN YOUR ZOTERO LIBRARY"), "" }
    table.insert(lines, T(_("Existing item: %1"), data.title or ""))
    if type(data.dateAdded) == "string" then
        table.insert(lines, T(_("Added on: %1"), data.dateAdded:sub(1, 10)))
    end
    local names = {}
    for _, c in ipairs(Client.localCollections(entry.creds) or {}) do names[c.key] = c.name end
    local found = {}
    for _, key in ipairs(type(data.collections) == "table" and data.collections or {}) do
        table.insert(found, names[key] or key)
    end
    table.insert(lines, T(_("In collections: %1"), #found > 0 and table.concat(found, ", ") or _("none")))
    table.insert(lines, _("Adding it again will create a duplicate."))
    table.insert(lines, "")
    table.insert(lines, "────────────────────")
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

function ZoteroCite:showPreview(entry)
    local text = describe(entry.item)
    if entry.duplicate then text = duplicateNotice(entry) .. text end
    local viewer
    viewer = TextViewer:new{
        title = entry.duplicate and _("Already in Zotero") or _("Add to Zotero"),
        text = text,
        text_type = "book_info",
        buttons_table = {
            {
                {
                    id = "collection",
                    text = collectionLabel(entry.collection),
                    callback = function()
                        self:pickCollection(entry, function()
                            local button = viewer.button_table:getButtonById("collection")
                            button:setText(collectionLabel(entry.collection), button.width)
                            UIManager:setDirty(viewer, "ui")
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(viewer) end,
                },
                {
                    text = entry.duplicate and _("Add anyway") or _("Add"),
                    callback = function()
                        UIManager:close(viewer)
                        self:add(entry)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

function ZoteroCite:pickCollection(entry, on_change, refresh)
    local collections = not refresh and Client.localCollections(entry.creds)
    if not collections then
        local err
        collections, err = withProgress(_("Loading collections…"), function()
            return Client.fetchCollections(entry.creds)
        end)
        if not collections then return showError(T(_("Could not load collections:\n%1"), err)) end
    end

    local dialog
    local function choose(collection)
        UIManager:close(dialog)
        entry.collection = collection
        on_change()
    end
    local buttons = {
        {
            { text = _("No collection"), callback = function() choose(nil) end },
            {
                text = _("Refresh"),
                callback = function()
                    UIManager:close(dialog)
                    self:pickCollection(entry, on_change, true)
                end,
            },
        },
    }
    for _, c in ipairs(collections) do
        table.insert(buttons, {
            {
                text = string.rep("    ", c.depth) .. c.name,
                align = "left",
                callback = function() choose({ key = c.key, name = c.name }) end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Add to collection"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ZoteroCite:add(entry)
    NetworkMgr:runWhenOnline(function()
        local key, err = withProgress(_("Adding to Zotero…"), function()
            return Client.createItem(entry.creds, entry.item, entry.collection and entry.collection.key)
        end)
        if not key then return showError(T(_("Could not add to Zotero:\n%1"), err)) end
        Client.setLastCollection(entry.creds, entry.collection)
        UIManager:show(InfoMessage:new{ text = T(_("Added to Zotero:\n%1"), entry.item.title), timeout = 3 })
    end)
end

function ZoteroCite:editCredentials()
    local own = Client.settings
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Zotero account"),
        fields = {
            { description = _("API key (with write access)"), text = own:readSetting("api_key", "") },
            { description = _("Library type (user or group)"), text = own:readSetting("library_type", "user") },
            { description = _("User or group ID"), text = own:readSetting("library_id", ""), input_type = "number" },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    callback = function()
                        local f = dialog:getFields()
                        local key, library_type, id = f[1]:match("^%s*(.-)%s*$"), f[2]:lower():match("^%s*(.-)%s*$"), f[3]:match("^%s*(.-)%s*$")
                        if key == "" then return showError(_("API key is required.")) end
                        if library_type ~= "user" and library_type ~= "group" then
                            return showError(_("Library type must be 'user' or 'group'."))
                        end
                        if not id:match("^%d+$") then return showError(_("Library ID must be a number.")) end
                        Client.setOwnCredentials(key, library_type, id)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ZoteroCite:addToMainMenu(menu_items)
    menu_items.zoterocite = {
        text = _("Zotero cite"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    local creds = Client.credentials()
                    if not creds then return _("Account: not configured") end
                    local source = creds.source == "own" and _("own key") or _("from Zotero plugin")
                    return T(_("Account: %1 (%2)"), creds.prefix, source)
                end,
                enabled_func = function() return false end,
            },
            {
                text = _("Set API key and library"),
                keep_menu_open = true,
                callback = function() self:editCredentials() end,
            },
            {
                text = _("Use Zotero plugin account"),
                enabled_func = function() return Client.ownCredentials() ~= nil and Client.syncCredentials() ~= nil end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Client.clearOwnCredentials()
                    touchmenu_instance:updateItems()
                end,
            },
        },
    }
end

return ZoteroCite
