--[[
Add "Generate QR code" to TextViewer's formatting menu, including plain
full-text windows opened from annotation details. Enrich annotation QR
codes in reader bookmarks, BookmarkBrowser, Bookshelf and AnnotationsViewer.

Uses KOReader's QRMessage, just like the built-in QR clipboard plugin.
Encodes the complete annotation: book title, author(s), page, chapter,
date, highlighted text and any additional note, when available.
Install in koreader/patches/ and restart KOReader. No plugin is required.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Screen = require("device").screen
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local util = require("util")
local userpatch = require("userpatch")
local _ = require("gettext")

-- These are ReaderBookmark.display_prefix's highlight/note markers, also
-- used by BookmarkBrowser, Bookshelf's quote patch and AnnotationsViewer.
-- Recognize the content rather than translated window titles or plugins.
local HIGHLIGHT_PREFIX = "\u{2592}\u{2002}"
local NOTE_PREFIX = "\u{F040}\u{2002}"

local function getHighlightText(viewer)
    local text = viewer.text
    if type(text) ~= "string" then return end

    -- Prefer the annotation itself when its details panel supplies it.
    -- Display text and icons can differ between plugin versions/views.
    local metadata = viewer._highlight_qr_book
    if metadata and type(metadata.highlight) == "string" then
        local highlight = util.cleanupSelectedText(metadata.highlight)
        if highlight ~= "" then
            return highlight, metadata.note, ""
        end
    end

    local start
    if text:sub(1, #HIGHLIGHT_PREFIX) == HIGHLIGHT_PREFIX then
        start = #HIGHLIGHT_PREFIX + 1
    else
        local _, last = text:find("\n" .. HIGHLIGHT_PREFIX, 1, true)
        if last then start = last + 1 end
    end
    if not start then
        -- Plain full-text windows (Find/top/bottom/Close) have no marker.
        -- QR availability must not depend on a plugin or metadata hook.
        text = util.trim(text)
        if text ~= "" then return text, nil, "" end
        return
    end

    local note_start = text:find("\n\n" .. NOTE_PREFIX, start, true)
    local highlight = text:sub(start, note_start and note_start - 1 or #text)
    -- Apply the same text cleanup as KOReader's highlight QR action.
    highlight = util.cleanupSelectedText(highlight)
    if highlight ~= "" then
        local note = note_start and text:sub(note_start + 2 + #NOTE_PREFIX)
        local header = text:sub(1, start - #HIGHLIGHT_PREFIX - 1)
        return highlight, note, header
    end
end

-- Save metadata on the panel itself, so changing books or opening a quote
-- from another book cannot substitute the currently open reader's metadata.
local function addBookMetadata(module, method_name, get_metadata)
    local original = module[method_name]
    module[method_name] = function(self, ...)
        local metadata = get_metadata(self, ...)
        local previous_viewer = UIManager:getTopmostVisibleWidget()
        local result = original(self, ...)
        local viewer = UIManager:getTopmostVisibleWidget()
        -- Retain the annotation on intermediate detail/edit panels too:
        -- their rows may open a separate TextViewer on a second tap.
        if metadata and viewer and viewer ~= previous_viewer then
            viewer._highlight_qr_book = metadata
        end
        return result
    end
end

local function getReaderBookmarkMetadata(self, item_or_index)
    local props = self.ui.doc_props
        or (self.ui.doc_settings and self.ui.doc_settings:readSetting("doc_props", {})) or {}
    local bm_menu = self.bookmark_menu and self.bookmark_menu[1]
    local item = bm_menu and item_or_index or self.ui.annotation.annotations[item_or_index]
    return {
        title = props.display_title or props.title,
        authors = props.authors,
        page = item.mandatory or self:getBookmarkPageString(item.page),
        chapter = item.chapter,
        datetime = item.datetime,
        note = item.note,
        highlight = item.text_orig or item.text,
    }
end

local function getBrowserBookmarkMetadata(self, item)
    local book = self.bm_list.item_table[item.book_idx]
    local props = book.doc_props or {}
    -- book.authors is shortened for display; prefer the complete metadata.
    return {
        title = props.display_title or props.title,
        authors = props.authors or book.authors,
        page = item.mandatory or item.pageref or item.pageno or tonumber(item.page),
        chapter = item.chapter,
        datetime = item.datetime,
        note = item.note,
        highlight = item.text_orig or item.text,
    }
end

local function getAnnotationPage(plugin, note)
    if note.pageref or note.pageno then return note.pageref or note.pageno end
    if not note.page or note.page == 0 then return end
    if tonumber(note.page) then return note.page end
    -- AnnotationsViewer retains the navigation xpointer as note.page for
    -- EPUBs. Resolve it only against this book; never export it as a page.
    local ui = plugin.ui
    if ui and ui.document and ui.document.file == note.book_path and ui.bookmark then
        return ui.bookmark:getBookmarkPageString(note.page)
    end
    if not note.book_path then return end
    local DocSettings = require("docsettings")
    if not DocSettings:hasSidecarFile(note.book_path) then return end
    local ok, settings = pcall(DocSettings.open, DocSettings, note.book_path)
    if not ok or not settings then return end
    for _, annotation in ipairs(settings:readSetting("annotations", {})) do
        if annotation.page == note.page and (not note.datetime or note.datetime == ""
                or annotation.datetime == note.datetime) then
            return annotation.pageref or annotation.pageno
        end
    end
end

local function patchAnnotationViewer(plugin)
    if plugin._highlight_qr_patched or type(plugin.showNoteDetails) ~= "function" then return end
    addBookMetadata(plugin, "showNoteDetails", function(self, note)
        return {
            title = note.book_title,
            authors = note.book_authors,
            page = getAnnotationPage(self, note),
            chapter = note.chapter,
            datetime = note.datetime,
            note = note.user_note,
            highlight = note.highlighted_text,
        }
    end)
    plugin._highlight_qr_patched = true
end

local function patchBookshelfHighlights()
    local ok, Highlights = pcall(require, "lib/bookshelf_book_highlights")
    if not ok or type(Highlights.showDetail) ~= "function" or Highlights._highlight_qr_patched then return end
    addBookMetadata(Highlights, "showDetail", function(_, filepath, highlight, modal)
        -- _showBookDetail's header_builder captures the exact book displayed
        -- in the general sheet. The shelf's preview may be a different book.
        if not modal or type(modal.header_builder) ~= "function" then return end
        local book = userpatch.getUpValue(modal.header_builder, "book")
        if type(book) ~= "table" or book.filepath ~= filepath then return end
        local authors = book.authors
        if type(authors) == "table" then authors = table.concat(authors, ", ") end
        if not authors or authors == "" then authors = book.author end
        return {
            title = book.title or book.filename,
            authors = authors,
            page = highlight.pageref or highlight.pageno or tonumber(highlight.page),
            chapter = highlight.chapter,
            datetime = highlight.datetime,
            note = highlight.note,
            highlight = highlight.text,
        }
    end)
    Highlights._highlight_qr_patched = true
end

local function getQRText(viewer, highlight, displayed_note, displayed_header)
    local metadata = viewer._highlight_qr_book
    local parts = {}
    local function add(value, label)
        if type(value) ~= "string" and type(value) ~= "number" then return end
        value = util.trim(tostring(value))
        if value ~= "" then
            parts[#parts + 1] = label and T(_("%1: %2"), label, value) or value
        end
    end
    if metadata then
        add(metadata.title)
        add(type(metadata.authors) == "string" and metadata.authors:gsub("\n", ", "))
        add(metadata.page, _("Page"))
        add(metadata.chapter, _("Chapter"))
        add(metadata.datetime, _("Date"))
    else
        -- Bookshelf's direct-quote panel already has the complete header,
        -- including chapter, page and date. Remove only display formatting;
        -- keep its metadata and translated labels without parsing them.
        local header = displayed_header:gsub("\u{FFF1}", "")
            :gsub("\u{FFF2}", ""):gsub("\u{FFF3}", "")
        add(header ~= "" and header or viewer.title)
    end
    local header = table.concat(parts, "\n")
    local text = header ~= "" and header .. "\n\n" .. highlight or highlight
    local note = metadata and metadata.note or displayed_note
    if type(note) == "string" and util.trim(note) ~= "" then
        -- Preserve paragraphs and spacing in personal notes.
        text = text .. "\n\n" .. _("Note") .. ":\n" .. util.trim(note)
    end
    return text
end

local original_onShowMenu = TextViewer.onShowMenu

function TextViewer:onShowMenu(...)
    if not self.show_menu then return end
    local highlight, note, header = getHighlightText(self)
    if not highlight then
        return original_onShowMenu(self, ...)
    end

    -- Keep TextViewer's standard formatting controls and menu placement.
    local dialog
    local buttons = {
        {{
            text_func = function()
                return T(_("Font size: %1"), self.text_font_size)
            end,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = _("Font size"),
                    value = self.text_font_size,
                    value_min = 12,
                    value_max = 30,
                    default_value = self.monospace_font and 16 or 20,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        self.text_font_size = spin.value
                        self:reinit()
                    end,
                })
            end,
        }},
        {{
            text = _("Monospace font"),
            checked_func = function()
                return self.monospace_font
            end,
            align = "left",
            callback = function()
                self.monospace_font = not self.monospace_font
                self:reinit()
            end,
        }},
        {{
            text = _("Justify"),
            checked_func = function()
                return self.justified
            end,
            align = "left",
            callback = function()
                self.justified = not self.justified
                self:reinit()
            end,
        }},
        {{
            text = _("Generate QR code"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                local QRMessage = require("ui/widget/qrmessage")
                UIManager:show(QRMessage:new{
                    text = getQRText(self, highlight, note, header),
                    width = Screen:getWidth(),
                    height = Screen:getHeight(),
                })
            end,
        }},
    }
    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        buttons = buttons,
        anchor = function()
            return self.titlebar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

-- Install metadata enhancements after the shared menu, so the QR action
-- also works independently of optional plugin APIs and private widgets.
addBookMetadata(require("apps/reader/modules/readerbookmark"), "showBookmarkDetails", getReaderBookmarkMetadata)
addBookMetadata(require("ui/widget/bookmarkbrowser"), "showBookmarkDetails", getBrowserBookmarkMetadata)

-- PluginLoader merges _meta.lua over the class: its effective name is
-- "annotationsviewer", even though main.lua names the class "allnotesviewer".
userpatch.registerPatchPluginFunc("annotationsviewer", patchAnnotationViewer)
userpatch.registerPatchPluginFunc("allnotesviewer", patchAnnotationViewer)
userpatch.registerPatchPluginFunc("bookshelf", patchBookshelfHighlights)

-- KeyValueItem is private to KeyValuePage. Pass the complete annotation
-- from its details page to the standard full-text window opened by a row.
local KeyValuePage = require("ui/widget/keyvaluepage")
local KeyValueItem = userpatch.getUpValue(KeyValuePage._populateItems, "KeyValueItem")
if KeyValueItem then
    addBookMetadata(KeyValueItem, "onShowKeyValue", function(self)
        return self.kv_page and self.kv_page._highlight_qr_book
    end)
end
