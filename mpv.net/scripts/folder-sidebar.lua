local mp = require("mp")
local utils = require("mp.utils")

----------------------------------------------------------------------
-- FOLDER SIDEBAR FOR MPV / MPV.NET
--
-- The current folder's audio files are made into the actual mpv
-- playlist. The sidebar is a UI for that playlist.
--
-- Features:
--   * Auto-opens when a local audio file is loaded.
--   * Toggle with TOGGLE_KEY.
--   * Natural filename sorting in the sidebar.
--   * Real mpv playlist containing every audio file in the folder.
--   * Loop: normal / repeat current song / repeat folder.
--   * Shuffle the real mpv playlist.
--   * Keyboard navigation.
--   * Page scrolling.
--   * Mouse-wheel scrolling.
--   * Click a song to play it.
--   * Hover highlighting.
--   * H opens a small hardcoded sidebar-controls legend.
--
-- IMPORTANT:
--   The legend only documents controls owned by this sidebar.
--   It is NOT a general mpv controls/help screen.
----------------------------------------------------------------------

----------------------------------------------------------------------
-- CONFIGURATION
----------------------------------------------------------------------

local TOGGLE_KEY = "x"
local HELP_KEY = "h"
local SHUFFLE_KEY = "s"

-- Default whenever a new folder playlist is created.
--   "normal" = no repeat
--   "song"   = repeat current song
--   "folder" = repeat entire folder

local DEFAULT_LOOP_MODE = "song"

-- Vertical reference resolution for the whole UI. Horizontal resolution
-- is intentionally NOT fixed here — see the overlay.res_x comment below.
local RES_Y = 1080

local SIDEBAR_WIDTH = 520

-- Small legend panel beside the sidebar.
local HELP_X = SIDEBAR_WIDTH + 22
local HELP_WIDTH = 485
local HELP_TOP = 45
local HELP_HEIGHT = 650

local VISIBLE_ROWS = 20
local ROW_HEIGHT = 42
local LIST_X = 54
local LIST_Y = 190

-- Shared left margin for header text (title, status, legend hint).
local HEADER_X = 46

-- Legend hint line (between the folder name/status and the song list).
-- Named so the click hit-region below always matches where it's drawn.
local LEGEND_Y = 113
local LEGEND_FS = 18

local TITLE_FS = 34
local SMALL_FS = 18
local SONG_FS = 25
local HELP_TITLE_FS = 28
local HELP_FS = 21
local HELP_SMALL_FS = 17

local WHEEL_SCROLL_ROWS = 4

local AUDIO_EXTENSIONS = {
    mp3 = true,
    flac = true,
    m4a = true,
    m4b = true,
    aac = true,
    ogg = true,
    oga = true,
    opus = true,
    wav = true,
    aiff = true,
    aif = true,
    caf = true,
    alac = true,
    ape = true,
    wv = true,
    tta = true,
    dsf = true,
    dff = true,
    mka = true,
}

----------------------------------------------------------------------

math.randomseed(os.time() + math.floor(os.clock() * 100000))

local overlay = mp.create_osd_overlay("ass-events")

-- res_x is intentionally left dynamic (0). mpv then derives the
-- horizontal PlayRes from the real window/OSD aspect ratio every frame,
-- so our canvas always exactly fills the window on both axes. Pinning
-- both res_x and res_y to fixed 16:9 values (as before) makes mpv
-- letterbox/pillarbox the canvas whenever the window isn't 16:9,
-- which is what left black bezels around the sidebar.
overlay.res_x = 0
overlay.res_y = RES_Y
overlay.z = 100
overlay.hidden = true

local sidebar_visible = false
local controls_visible = false

local songs = {}
local selected = 1
local scroll_offset = 1

local current_dir = nil
local current_filename = nil

local managed_dir = nil
local rebuilding_playlist = false

local loop_mode = DEFAULT_LOOP_MODE
local shuffle_enabled = false

local hover_song = nil

local active_bindings = {}

-- Explicit forward declarations.
local refresh_ui
local shuffle_folder_playlist
local reorder_playlist_to_filenames

----------------------------------------------------------------------

local function ass_escape(text)
    text = tostring(text or "")

    text = text:gsub("\\", "\\\\")
    text = text:gsub("{", "\\{")
    text = text:gsub("}", "\\}")
    text = text:gsub("\r", " ")
    text = text:gsub("\n", " ")

    return text
end

----------------------------------------------------------------------

local function truncate_utf8(text, max_chars)
    text = tostring(text or "")

    local chars = {}

    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char

        if #chars >= max_chars then
            break
        end
    end

    if #chars < max_chars then
        return text
    end

    return table.concat(chars) .. "..."
end

----------------------------------------------------------------------

local function estimate_char_units(ch)
    if ch == " " then
        return 0.30
    end

    if ch == "W" or ch == "M" or ch == "w" or ch == "m" then
        return 0.82
    end

    if ch:match("[%.,;:'`!|%[%]%(%){}]") then
        return 0.38
    end

    if ch:match("[%d]") then
        return 0.58
    end

    if ch:match("[%u]") then
        return 0.68
    end

    if ch:match("[%l]") then
        return 0.54
    end

    return 0.62
end

----------------------------------------------------------------------

-- Approximate rendered width, in pixels, of `text` at `font_size`.
-- Built on the same per-character unit table truncate_sidebar_text
-- uses, so it stays consistent with the rest of the UI's text-width
-- estimates without needing real font metrics.
local function measure_text_px(text, font_size)
    local units = 0

    for char in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        units = units + estimate_char_units(char)
    end

    return units * font_size
end

----------------------------------------------------------------------

-- Truncate using an approximate rendered width rather than only a
-- character count. This keeps long filenames inside the sidebar.
local function truncate_sidebar_text(text)
    text = tostring(text or "")

    local available_px =
        SIDEBAR_WIDTH - LIST_X - 24

    local max_units =
        (available_px / SONG_FS) * 0.90

    local ellipsis_units = 1.15

    local units = 0
    local chars = {}
    local truncated = false

    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local char_units = estimate_char_units(char)

        if units + char_units + ellipsis_units > max_units then
            truncated = true
            break
        end

        chars[#chars + 1] = char
        units = units + char_units
    end

    if #chars == 0 then
        return "..."
    end

    if truncated then
        return table.concat(chars) .. "..."
    end

    return text
end

----------------------------------------------------------------------

local function is_audio_file(filename)
    local ext = filename:match("%.([^%.]+)$")

    if not ext then
        return false
    end

    return AUDIO_EXTENSIONS[ext:lower()] == true
end

----------------------------------------------------------------------

local function natural_sort(a, b)
    local al = a:lower()
    local bl = b:lower()

    local ia = 1
    local ib = 1

    while ia <= #al and ib <= #bl do
        local ca = al:sub(ia, ia)
        local cb = bl:sub(ib, ib)

        local da = ca:match("%d")
        local db = cb:match("%d")

        if da and db then
            local enda = ia

            while enda <= #al and al:sub(enda, enda):match("%d") do
                enda = enda + 1
            end

            local endb = ib

            while endb <= #bl and bl:sub(endb, endb):match("%d") do
                endb = endb + 1
            end

            local na = tonumber(al:sub(ia, enda - 1))
            local nb = tonumber(bl:sub(ib, endb - 1))

            if na ~= nb then
                return na < nb
            end

            ia = enda
            ib = endb
        else
            if ca ~= cb then
                return ca < cb
            end

            ia = ia + 1
            ib = ib + 1
        end
    end

    return #al < #bl
end

----------------------------------------------------------------------

local function normalize_path(path)
    if not path then
        return ""
    end

    local s = tostring(path):gsub("/", "\\")
    s = s:gsub("\\+$", "")

    if package.config:sub(1, 1) == "\\" then
        s = s:lower()
    end

    return s
end

----------------------------------------------------------------------

local function get_current_file()
    local path = mp.get_property("path")

    if not path or path == "" then
        return nil, nil
    end

    if path:match("^%a[%w+.-]*://") then
        return nil, nil
    end

    local dir, filename = utils.split_path(path)

    return dir, filename
end

----------------------------------------------------------------------

local function get_folder_name(dir)
    if not dir or dir == "" then
        return ""
    end

    local clean = dir:gsub("[\\/]+$", "")

    return clean:match("[^\\/]+$") or clean
end

----------------------------------------------------------------------

local function find_current_sidebar_index()
    if not current_filename then
        return nil
    end

    for i, filename in ipairs(songs) do
        if filename == current_filename then
            return i
        end
    end

    return nil
end

----------------------------------------------------------------------

local function ensure_selected_visible()
    if #songs == 0 then
        selected = 1
        scroll_offset = 1
        return
    end

    if selected < 1 then
        selected = 1
    elseif selected > #songs then
        selected = #songs
    end

    if selected < scroll_offset then
        scroll_offset = selected
    end

    local last_visible =
        scroll_offset + VISIBLE_ROWS - 1

    if selected > last_visible then
        scroll_offset =
            selected - VISIBLE_ROWS + 1
    end

    local max_scroll =
        math.max(1, #songs - VISIBLE_ROWS + 1)

    scroll_offset =
        math.max(
            1,
            math.min(scroll_offset, max_scroll)
        )
end

----------------------------------------------------------------------

local function scan_current_directory()
    local dir, filename = get_current_file()

    if not dir then
        current_dir = nil
        current_filename = nil
        songs = {}
        selected = 1
        scroll_offset = 1

        return false
    end

    current_dir = dir
    current_filename = filename

    local entries, err =
        utils.readdir(dir, "files")

    if not entries then
        songs = {}
        selected = 1
        scroll_offset = 1

        mp.msg.error(
            "folder-sidebar: cannot read directory: "
            .. tostring(err)
        )

        return false
    end

    songs = {}

    for _, entry in ipairs(entries) do
        if is_audio_file(entry) then
            songs[#songs + 1] = entry
        end
    end

    table.sort(songs, natural_sort)

    local current_index =
        find_current_sidebar_index()

    selected = current_index or 1

    ensure_selected_visible()

    return #songs > 0
end

----------------------------------------------------------------------

local function get_playlist()
    local playlist =
        mp.get_property_native("playlist")

    if type(playlist) ~= "table" then
        return {}
    end

    return playlist
end

----------------------------------------------------------------------

local function playlist_index_for_path(path)
    local wanted = normalize_path(path)
    local playlist = get_playlist()

    for index, item in ipairs(playlist) do
        if type(item) == "table" then
            local candidate =
                item.filename
                or item.path
                or item.url

            if normalize_path(candidate) == wanted then
                return index - 1
            end
        end
    end

    return nil
end

----------------------------------------------------------------------

local function playlist_is_our_folder()
    if not managed_dir or not current_dir then
        return false
    end

    if normalize_path(managed_dir)
        ~= normalize_path(current_dir) then
        return false
    end

    local playlist = get_playlist()

    if #playlist ~= #songs then
        return false
    end

    local expected = {}

    for _, filename in ipairs(songs) do
        local path =
            utils.join_path(
                current_dir,
                filename
            )

        expected[normalize_path(path)] = true
    end

    for _, item in ipairs(playlist) do
        if type(item) ~= "table" then
            return false
        end

        local candidate =
            item.filename
            or item.path
            or item.url

        if not expected[normalize_path(candidate)] then
            return false
        end
    end

    return true
end

----------------------------------------------------------------------

local function apply_loop_mode()
    if loop_mode == "song" then
        mp.set_property("loop-file", "inf")
        mp.set_property("loop-playlist", "no")

    elseif loop_mode == "folder" then
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "inf")

    else
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "no")
    end
end

----------------------------------------------------------------------

local function draw_rect(
    ass,
    x,
    y,
    w,
    h,
    color,
    alpha
)
    ass[#ass + 1] =
        string.format(
            "{\\p1\\bord0\\shad0\\1c%s\\alpha%s}" ..
            "m %d %d l %d %d l %d %d l %d %d{\\p0}",
            color,
            alpha or "&H00&",
            x,
            y,
            x + w,
            y,
            x + w,
            y + h,
            x,
            y + h
        )
end

----------------------------------------------------------------------

-- Renderer is defined before navigation functions.
-- UI renderer.
refresh_ui = function()
    if not sidebar_visible then
        return
    end

    local ass = {}

    --------------------------------------------------------------
    -- Sidebar background
    --------------------------------------------------------------

    draw_rect(
        ass,
        0,
        0,
        SIDEBAR_WIDTH,
        RES_Y,
        "&H181818&",
        "&H18&"
    )

    draw_rect(
        ass,
        SIDEBAR_WIDTH - 3,
        0,
        3,
        RES_Y,
        "&H444444&",
        "&H00&"
    )

    --------------------------------------------------------------
    -- Header
    --------------------------------------------------------------

    local folder_name =
        truncate_utf8(
            get_folder_name(current_dir),
            32
        )

    ass[#ass + 1] =
        string.format(
            "{\\an7\\pos(%d,30)\\fs%d\\b1\\c&HFFFFFF&}%s",
            HEADER_X,
            TITLE_FS,
            ass_escape(folder_name)
        )

    local loop_text

    if loop_mode == "folder" then
        loop_text = "Repeat folder"
    elseif loop_mode == "song" then
        loop_text = "Repeat song"
    else
        loop_text = "Normal"
    end

    local status =
        string.format(
            "%d songs   •   %s%s",
            #songs,
            loop_text,
            shuffle_enabled
                and "   •   Shuffle"
                or ""
        )

    ass[#ass + 1] =
        string.format(
            "{\\an7\\pos(%d,75)\\fs%d\\c&HAAAAAA&}%s",
            HEADER_X,
            SMALL_FS,
            ass_escape(status)
        )

    --------------------------------------------------------------
    -- Small legend hint (between folder name and the playlist)
    --------------------------------------------------------------

    ass[#ass + 1] =
        string.format(
            "{\\an7\\pos(%d,%d)\\fs%d\\c&H777777&}" ..
            "↑ ↓   %s = controls",
            HEADER_X,
            LEGEND_Y,
            LEGEND_FS,
            HELP_KEY:upper()
        )

    -- Thin divider separating the header block from the song list.
    draw_rect(
        ass,
        30,
        150,
        SIDEBAR_WIDTH - 60,
        2,
        "&H333333&",
        "&H40&"
    )

    --------------------------------------------------------------
    -- Hover highlight
    --------------------------------------------------------------

    if hover_song then
        local row =
            hover_song - scroll_offset

        if row >= 0 and row < VISIBLE_ROWS then
            local y =
                LIST_Y + row * ROW_HEIGHT - 25

            draw_rect(
                ass,
                36,
                y,
                SIDEBAR_WIDTH - 56,
                ROW_HEIGHT,
                "&H333333&",
                "&H18&"
            )
        end
    end

    --------------------------------------------------------------
    -- Song list
    --------------------------------------------------------------

    local first = scroll_offset

    local last =
        math.min(
            #songs,
            scroll_offset + VISIBLE_ROWS - 1
        )

    local row = 0

    for i = first, last do
        local filename = songs[i]

        local y =
            LIST_Y + row * ROW_HEIGHT

        local prefix = "  "
        local color = "&HDDDDDD&"

        if i == selected then
            prefix = "▶ "
            color = "&H80FF80&"

        elseif filename == current_filename then
            prefix = "♫ "
            color = "&H80D0FF&"
        end

        local display_name =
            truncate_sidebar_text(filename)

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\c%s}%s%s",
                LIST_X,
                y,
                SONG_FS,
                color,
                prefix,
                ass_escape(display_name)
            )

        row = row + 1
    end

    --------------------------------------------------------------
    -- Scroll arrows
    --------------------------------------------------------------

    if scroll_offset > 1 then
        ass[#ass + 1] =
            "{\\an7\\pos(470,155)\\fs20\\c&HAAAAAA&}▲"
    end

    if scroll_offset + VISIBLE_ROWS <= #songs then
        ass[#ass + 1] =
            "{\\an7\\pos(470,1015)\\fs20\\c&HAAAAAA&}▼"
    end

    --------------------------------------------------------------
    -- SIDEBAR-ONLY CONTROLS LEGEND
    --------------------------------------------------------------

    if controls_visible then

        draw_rect(
            ass,
            HELP_X,
            HELP_TOP,
            HELP_WIDTH,
            HELP_HEIGHT,
            "&H181818&",
            "&H18&"
        )

        draw_rect(
            ass,
            HELP_X,
            HELP_TOP,
            HELP_WIDTH,
            3,
            "&H555555&",
            "&H00&"
        )

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\b1\\c&HFFFFFF&}CONTROLS",
                HELP_X + 28,
                HELP_TOP + 38,
                HELP_TITLE_FS
            )

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\c&H777777&}" ..
                "Sidebar-only controls",
                HELP_X + 28,
                HELP_TOP + 72,
                HELP_SMALL_FS
            )

        ----------------------------------------------------------
        -- Navigation
        ----------------------------------------------------------

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\b1\\c&HFFFFFF&}NAVIGATION",
                HELP_X + 28,
                HELP_TOP + 118,
                HELP_FS
            )

        local nav = {
            { "↑ / ↓", "Navigate selection" },
            { "PGUP / PGDWN", "Scroll one page" },
            { "Wheel", "Scroll list" },
            { "Click", "Play song" },
            { "Enter", "Play selected" },
            { "R", "Refresh folder" },
            { "Click controls", "Change loop / shuffle" },
        }

        -- Compute the description column's X position from the widest
        -- key label actually in use, so the two columns always line up
        -- no matter how the key text above changes.
        local nav_key_x = HELP_X + 38
        local nav_key_col_width = 0

        for _, row in ipairs(nav) do
            nav_key_col_width =
                math.max(
                    nav_key_col_width,
                    measure_text_px(row[1], HELP_FS)
                )
        end

        local nav_desc_x = nav_key_x + nav_key_col_width + 20

        local y = HELP_TOP + 155

        for _, row in ipairs(nav) do
            ass[#ass + 1] =
                string.format(
                    "{\\an7\\pos(%d,%d)\\fs%d\\c&HDDDDDD&\\b1}%s",
                    nav_key_x,
                    y,
                    HELP_FS,
                    ass_escape(row[1])
                )

            ass[#ass + 1] =
                string.format(
                    "{\\an7\\pos(%d,%d)\\fs%d\\c&HCCCCCC&}%s",
                    nav_desc_x,
                    y,
                    HELP_FS,
                    ass_escape(row[2])
                )

            y = y + 34
        end

        ----------------------------------------------------------
        -- Loop
        ----------------------------------------------------------

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\b1\\c&HFFFFFF&}LOOP",
                HELP_X + 28,
                HELP_TOP + 390,
                HELP_FS
            )

        local loop_rows = {
            { "1", "Normal", "normal" },
            { "2", "Repeat song", "song" },
            { "3", "Repeat folder", "folder" },
        }

        y = HELP_TOP + 428

        for _, item in ipairs(loop_rows) do
            local key = item[1]
            local label = item[2]
            local mode = item[3]

            local marker =
                loop_mode == mode
                and "●"
                or "○"

            local color =
                loop_mode == mode
                and "&H80FF80&"
                or "&HCCCCCC&"

            ass[#ass + 1] =
                string.format(
                    "{\\an7\\pos(%d,%d)\\fs%d\\c%s}" ..
                    "%s  %s   %s",
                    HELP_X + 38,
                    y,
                    HELP_FS,
                    color,
                    marker,
                    key,
                    ass_escape(label)
                )

            y = y + 38
        end

        ----------------------------------------------------------
        -- Shuffle
        ----------------------------------------------------------

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\b1\\c&HFFFFFF&}SHUFFLE",
                HELP_X + 28,
                HELP_TOP + 545,
                HELP_FS
            )

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\c%s}%s   Shuffle",
                HELP_X + 38,
                HELP_TOP + 583,
                HELP_FS,
                shuffle_enabled
                    and "&H80FF80&"
                    or "&HCCCCCC&",
                shuffle_enabled
                    and "●  S"
                    or "○  S"
            )

        ----------------------------------------------------------
        -- Legend/sidebar keys
        ----------------------------------------------------------

        ass[#ass + 1] =
            string.format(
                "{\\an7\\pos(%d,%d)\\fs%d\\c&H777777&}" ..
                "%s   Hide/show sidebar     %s   Hide/show legend",
                HELP_X + 28,
                HELP_TOP + 630,
                HELP_SMALL_FS,
                TOGGLE_KEY:upper(),
                HELP_KEY:upper()
            )
    end

    overlay.data =
        table.concat(ass, "\n")

    overlay.hidden = false
    overlay:update()
end

----------------------------------------------------------------------

local function set_loop_mode(mode)
    if mode ~= "normal"
        and mode ~= "song"
        and mode ~= "folder" then
        return
    end

    loop_mode = mode

    apply_loop_mode()

    if sidebar_visible then
        refresh_ui()
    end
end

----------------------------------------------------------------------

local function rebuild_folder_playlist()
    if rebuilding_playlist then
        return false
    end

    if not current_dir
        or not current_filename
        or #songs == 0 then
        return false
    end

    rebuilding_playlist = true

    -- playlist-clear keeps the currently playing file.
    -- Append every other audio file exactly once.
    mp.commandv("playlist-clear")

    for _, filename in ipairs(songs) do
        if filename ~= current_filename then
            mp.commandv(
                "loadfile",
                utils.join_path(
                    current_dir,
                    filename
                ),
                "append"
            )
        end
    end

    managed_dir = current_dir

    -- The files are already in natural folder order. Do not run a second
    -- full playlist permutation here; that used to remove and reinsert
    -- every playlist entry and caused a noticeable first-load delay.

    apply_loop_mode()

    rebuilding_playlist = false
    return true
end

----------------------------------------------------------------------

local function ensure_folder_playlist()
    if rebuilding_playlist then
        return false
    end

    if not current_dir
        or not current_filename then
        return false
    end

    if playlist_is_our_folder() then
        apply_loop_mode()
        return true
    end

    if scan_current_directory() then
        return rebuild_folder_playlist()
    end

    return false
end

----------------------------------------------------------------------

local function sync_selection_to_current_song()
    if rebuilding_playlist then
        return
    end

    local dir, filename =
        get_current_file()

    if dir and filename then
        current_dir = dir
        current_filename = filename
    end

    local index =
        find_current_sidebar_index()

    if index then
        selected = index
        ensure_selected_visible()
    end
end

----------------------------------------------------------------------

local function move_selection(delta)
    if #songs == 0 then
        return
    end

    selected = selected + delta

    if selected < 1 then
        selected = 1

    elseif selected > #songs then
        selected = #songs
    end

    ensure_selected_visible()

    refresh_ui()
end

----------------------------------------------------------------------

local function page_move(delta)
    if #songs == 0 then
        return
    end

    selected =
        selected + delta * VISIBLE_ROWS

    if selected < 1 then
        selected = 1

    elseif selected > #songs then
        selected = #songs
    end

    ensure_selected_visible()

    refresh_ui()
end

----------------------------------------------------------------------

local function scroll_by(delta)
    if #songs == 0 then
        return
    end

    local max_scroll =
        math.max(
            1,
            #songs - VISIBLE_ROWS + 1
        )

    scroll_offset =
        scroll_offset + delta

    scroll_offset =
        math.max(
            1,
            math.min(
                scroll_offset,
                max_scroll
            )
        )

    if selected < scroll_offset then
        selected = scroll_offset
    end

    local last_visible =
        scroll_offset + VISIBLE_ROWS - 1

    if selected > last_visible then
        selected =
            math.min(
                last_visible,
                #songs
            )
    end

    refresh_ui()
end

----------------------------------------------------------------------

local function play_song(filename)
    if not filename or not current_dir then
        return
    end

    local path =
        utils.join_path(
            current_dir,
            filename
        )

    local index =
        playlist_index_for_path(path)

    if index == nil then
        if not playlist_is_our_folder() then
            if not scan_current_directory() then
                return
            end

            if not rebuild_folder_playlist() then
                return
            end

            index =
                playlist_index_for_path(path)
        end
    end

    if index ~= nil then
        mp.commandv(
            "playlist-play-index",
            tostring(index)
        )
    end
end

----------------------------------------------------------------------

local function play_selected()
    local filename = songs[selected]

    if filename then
        play_song(filename)
    end
end

----------------------------------------------------------------------

local function playlist_entry_filename(item)
    if type(item) ~= "table" then
        return nil
    end

    return item.filename or item.path or item.url
end

----------------------------------------------------------------------

-- Rebuild the order of our folder playlist without reloading the
-- currently playing file. The current entry is never removed.
--
-- This is more reliable than playlist-move for arbitrary permutations:
-- we remove all non-current entries, leaving only the current song, then
-- insert the desired entries around it. Playback therefore continues
-- from the same point without restarting.
----------------------------------------------------------------------
reorder_playlist_to_filenames = function(target_filenames)
    if not current_dir
        or not current_filename
        or #target_filenames == 0 then
        return false
    end

    local current_path = utils.join_path(
        current_dir,
        current_filename
    )
    local wanted_current = normalize_path(current_path)

    local playlist = get_playlist()
    if #playlist == 0 then
        return false
    end

    local current_present = false
    local current_playlist_index = nil

    for i, item in ipairs(playlist) do
        local candidate = playlist_entry_filename(item)
        if normalize_path(candidate) == wanted_current then
            current_present = true
            current_playlist_index = i - 1
            break
        end
    end

    if not current_present then
        return false
    end

    -- Validate that the target contains the current file exactly once.
    local target_current_index = nil

    for i, filename in ipairs(target_filenames) do
        if filename == current_filename then
            if target_current_index ~= nil then
                return false
            end
            target_current_index = i - 1
        end
    end

    if target_current_index == nil then
        return false
    end

    -- Remove every non-current playlist entry. Iterate backwards so
    -- indexes remain valid while removing.
    for i = #playlist - 1, 0, -1 do
        local item = playlist[i + 1]
        local candidate = playlist_entry_filename(item)

        if normalize_path(candidate) ~= wanted_current then
            mp.commandv(
                "playlist-remove",
                tostring(i)
            )
        end
    end

    -- The current song is now the only playlist entry, at index 0.
    -- Insert the desired entries that belong before it.
    local insert_index = 0

    for i = 1, target_current_index do
        local filename = target_filenames[i]

        mp.commandv(
            "loadfile",
            utils.join_path(
                current_dir,
                filename
            ),
            "insert-at",
            tostring(insert_index)
        )

        insert_index = insert_index + 1
    end

    -- The current file has now moved to target_current_index.
    -- Insert all files after it.
    insert_index = target_current_index + 1

    for i = target_current_index + 2, #target_filenames do
        local filename = target_filenames[i]

        mp.commandv(
            "loadfile",
            utils.join_path(
                current_dir,
                filename
            ),
            "insert-at",
            tostring(insert_index)
        )

        insert_index = insert_index + 1
    end

    -- Keep track of where the current entry is expected to be. This is
    -- informational only; mpv continues playing the same entry.
    managed_dir = current_dir

    return true
end

----------------------------------------------------------------------

shuffle_folder_playlist = function()
    if not current_dir
        or not current_filename
        or #songs < 2 then
        return false
    end

    local playlist = get_playlist()
    if #playlist < 2 then
        return false
    end

    local current_path = utils.join_path(
        current_dir,
        current_filename
    )
    local current_playlist_index =
        playlist_index_for_path(current_path)

    if current_playlist_index == nil then
        return false
    end

    -- Shuffle every other track. The currently playing track stays
    -- where it is, so enabling shuffle never restarts the song.
    local remaining = {}

    for _, filename in ipairs(songs) do
        if filename ~= current_filename then
            remaining[#remaining + 1] = filename
        end
    end

    for i = #remaining, 2, -1 do
        local j = math.random(i)
        remaining[i], remaining[j] =
            remaining[j], remaining[i]
    end

    -- Build the desired playlist order with the current song fixed in
    -- its present playlist slot. This means only the other entries move.
    local desired = {}
    local r = 1

    for i = 0, #songs - 1 do
        if i == current_playlist_index then
            desired[#desired + 1] = current_filename
        else
            desired[#desired + 1] = remaining[r]
            r = r + 1
        end
    end

    -- Extremely small chance of producing the existing order is possible
    -- with a random shuffle. Avoid that when there are at least 3 tracks.
    -- (Reuses `playlist` fetched above — nothing has changed it since.)
    local current_order_same = true
    for i, item in ipairs(playlist) do
        local candidate =
            type(item) == "table"
            and (item.filename or item.path or item.url)
            or nil

        if normalize_path(candidate)
            ~= normalize_path(utils.join_path(
                current_dir,
                desired[i]
            )) then
            current_order_same = false
            break
        end
    end

    if current_order_same and #remaining >= 2 then
        remaining[1], remaining[2] =
            remaining[2], remaining[1]

        desired = {}
        r = 1
        for i = 0, #songs - 1 do
            if i == current_playlist_index then
                desired[#desired + 1] = current_filename
            else
                desired[#desired + 1] = remaining[r]
                r = r + 1
            end
        end
    end

    if not reorder_playlist_to_filenames(desired) then
        return false
    end

    -- The sidebar should mirror the real shuffled playlist.
    -- Keep the natural folder list only when shuffle is OFF.
    songs = desired

    managed_dir = current_dir
    apply_loop_mode()
    sync_selection_to_current_song()

    return true
end

local function toggle_shuffle()
    if not playlist_is_our_folder() then
        if not ensure_folder_playlist() then
            return
        end
    end

    if shuffle_enabled then
        -- Turning shuffle off restores natural folder order without
        -- restarting the currently playing file.
        shuffle_enabled = false

        -- Re-scan so `songs` is restored to natural folder order.
        if not scan_current_directory() then
            shuffle_enabled = true
            return
        end

        if not reorder_playlist_to_filenames(songs) then
            shuffle_enabled = true
            return
        end
    else
        -- Turning shuffle on creates a fresh random playlist order.
        shuffle_enabled = true

        if not shuffle_folder_playlist() then
            shuffle_enabled = false
            return
        end
    end

    sync_selection_to_current_song()
    refresh_ui()
end

----------------------------------------------------------------------

local function toggle_controls()
    controls_visible =
        not controls_visible

    refresh_ui()
end

----------------------------------------------------------------------

local function get_mouse_canvas_position()
    local mouse =
        mp.get_property_native(
            "mouse-pos"
        )

    if type(mouse) ~= "table"
        or mouse.x == nil
        or mouse.y == nil then
        return nil, nil, false
    end

    if mouse.hover == false then
        return nil, nil, false
    end

    local osd_h =
        mp.get_property_number(
            "osd-height",
            0
        )

    if osd_h <= 0 then
        -- Real OSD size isn't known yet; we cannot safely convert this
        -- click into canvas coordinates.
        return nil, nil, false
    end

    -- res_x = 0 makes mpv keep PlayResX = RES_Y * (osd_w / osd_h), i.e.
    -- always matching the real window aspect. That means one scale
    -- factor converts real OSD pixels to canvas units on BOTH axes.
    local scale = RES_Y / osd_h

    return
        mouse.x * scale,
        mouse.y * scale,
        true
end

----------------------------------------------------------------------

local function hit_test_song(x, y)
    if x < 0
        or x > SIDEBAR_WIDTH
        or y < LIST_Y
        or y >=
            LIST_Y
            + VISIBLE_ROWS
            * ROW_HEIGHT then
        return nil
    end

    local row =
        math.floor(
            (y - LIST_Y)
            / ROW_HEIGHT
        )

    local index =
        scroll_offset + row

    if index < 1
        or index > #songs then
        return nil
    end

    return index
end

----------------------------------------------------------------------

local function hit_test_controls(x, y)
    if not controls_visible then
        return nil
    end

    if x < HELP_X
        or x > HELP_X + HELP_WIDTH
        or y < HELP_TOP
        or y > HELP_TOP + HELP_HEIGHT then
        return nil
    end

    local loop_y = HELP_TOP + 428

    if y >= loop_y - 18 and y < loop_y + 18 then
        return "loop-normal"
    end

    loop_y = loop_y + 38

    if y >= loop_y - 18 and y < loop_y + 18 then
        return "loop-song"
    end

    loop_y = loop_y + 38

    if y >= loop_y - 18 and y < loop_y + 18 then
        return "loop-folder"
    end

    local shuffle_y = HELP_TOP + 583

    if y >= shuffle_y - 30 and y < shuffle_y + 30 then
        return "shuffle"
    end

    return nil
end

----------------------------------------------------------------------

local function handle_left_click()
    if not sidebar_visible then
        return
    end

    local x, y, valid =
        get_mouse_canvas_position()

    if not valid then
        return
    end

    -- The controls panel has priority when it is open.
    if controls_visible then
        local control =
            hit_test_controls(x, y)

        if control == "loop-normal" then
            set_loop_mode("normal")
            return
        end

        if control == "loop-song" then
            set_loop_mode("song")
            return
        end

        if control == "loop-folder" then
            set_loop_mode("folder")
            return
        end

        if control == "shuffle" then
            toggle_shuffle()
            return
        end

        -- Clicking outside the controls panel but inside the sidebar
        -- continues to behave normally.
    end

    local index =
        hit_test_song(x, y)

    if index then
        selected = index

        ensure_selected_visible()

        play_selected()

        refresh_ui()

        return
    end

    -- Click the legend hint line to toggle the controls panel (mirrors
    -- the H key). Uses the same LEGEND_Y/HEADER_X constants as the
    -- drawing code above so this can't drift out of sync again.
    if x >= HEADER_X - 10
        and x <= SIDEBAR_WIDTH - 20
        and y >= LEGEND_Y - 12
        and y <= LEGEND_Y + LEGEND_FS + 10 then
        toggle_controls()
    end
end

----------------------------------------------------------------------

local function handle_wheel_up()
    local x, _, valid =
        get_mouse_canvas_position()

    if valid
        and x >= 0
        and x <= SIDEBAR_WIDTH then
        scroll_by(-WHEEL_SCROLL_ROWS)
    end
end

----------------------------------------------------------------------

local function handle_wheel_down()
    local x, _, valid =
        get_mouse_canvas_position()

    if valid
        and x >= 0
        and x <= SIDEBAR_WIDTH then
        scroll_by(WHEEL_SCROLL_ROWS)
    end
end

----------------------------------------------------------------------

local function handle_mouse_move()
    if not sidebar_visible then
        return
    end

    local x, y, valid =
        get_mouse_canvas_position()

    if not valid then
        if hover_song ~= nil then
            hover_song = nil
            refresh_ui()
        end
        return
    end

    local new_hover =
        hit_test_song(x, y)

    if new_hover ~= hover_song then
        hover_song = new_hover
        refresh_ui()
    end
end

----------------------------------------------------------------------

local function clear_sidebar_bindings()
    for _, name in ipairs(active_bindings) do
        mp.remove_key_binding(name)
    end

    active_bindings = {}
end

----------------------------------------------------------------------

local function bind_sidebar_key(
    key,
    name,
    fn,
    options
)
    mp.add_forced_key_binding(
        key,
        name,
        fn,
        options or {}
    )

    active_bindings[#active_bindings + 1] =
        name
end

----------------------------------------------------------------------

local function hide_sidebar()
    sidebar_visible = false
    controls_visible = false
    hover_song = nil

    overlay.hidden = true
    overlay:update()

    clear_sidebar_bindings()
end

----------------------------------------------------------------------

local function bind_sidebar_mouse(
    key,
    name,
    fn
)
    mp.add_forced_key_binding(
        key,
        name,
        fn
    )

    active_bindings[#active_bindings + 1] =
        name
end

----------------------------------------------------------------------

local function show_sidebar()
    if not current_dir
        or #songs == 0 then
        return
    end

    sidebar_visible = true
    overlay.hidden = false

    if #active_bindings == 0 then

        bind_sidebar_key(
            "UP",
            "folder-sidebar-up",
            function()
                move_selection(-1)
            end,
            { repeatable = true }
        )

        bind_sidebar_key(
            "DOWN",
            "folder-sidebar-down",
            function()
                move_selection(1)
            end,
            { repeatable = true }
        )

        -- mpv's actual Page Up / Page Down names.
        bind_sidebar_key(
            "PGUP",
            "folder-sidebar-pgup",
            function()
                page_move(-1)
            end,
            { repeatable = true }
        )

        bind_sidebar_key(
            "PGDWN",
            "folder-sidebar-pgdwn",
            function()
                page_move(1)
            end,
            { repeatable = true }
        )

        bind_sidebar_key(
            "ENTER",
            "folder-sidebar-enter",
            play_selected
        )

        bind_sidebar_key(
            "1",
            "folder-sidebar-loop-normal",
            function()
                set_loop_mode("normal")
            end
        )

        bind_sidebar_key(
            "2",
            "folder-sidebar-loop-song",
            function()
                set_loop_mode("song")
            end
        )

        bind_sidebar_key(
            "3",
            "folder-sidebar-loop-folder",
            function()
                set_loop_mode("folder")
            end
        )

        bind_sidebar_key(
            SHUFFLE_KEY,
            "folder-sidebar-shuffle",
            toggle_shuffle
        )

        bind_sidebar_key(
            HELP_KEY,
            "folder-sidebar-help",
            toggle_controls
        )

        bind_sidebar_key(
            "r",
            "folder-sidebar-refresh",
            function()
                scan_current_directory()
                rebuild_folder_playlist()
                sync_selection_to_current_song()
                refresh_ui()
            end
        )

        bind_sidebar_key(
            "ESC",
            "folder-sidebar-esc",
            function()
                if controls_visible then
                    controls_visible = false
                    refresh_ui()
                else
                    hide_sidebar()
                end
            end
        )

        bind_sidebar_key(
            TOGGLE_KEY,
            "folder-sidebar-toggle-open",
            hide_sidebar
        )

        -- Click songs.
        bind_sidebar_mouse(
            "MBTN_LEFT",
            "folder-sidebar-click",
            handle_left_click
        )

        -- Wheel is only intercepted while the sidebar is open.
        bind_sidebar_key(
            "WHEEL_UP",
            "folder-sidebar-wheel-up",
            handle_wheel_up,
            { repeatable = true }
        )

        bind_sidebar_key(
            "WHEEL_DOWN",
            "folder-sidebar-wheel-down",
            handle_wheel_down,
            { repeatable = true }
        )
    end

    refresh_ui()
end

----------------------------------------------------------------------

local function toggle_sidebar()
    if sidebar_visible then
        hide_sidebar()
        return
    end

    if not current_dir
        or not current_filename
        or not is_audio_file(current_filename) then
        return
    end

    scan_current_directory()

    if not playlist_is_our_folder() then
        rebuild_folder_playlist()
    else
        apply_loop_mode()
    end

    show_sidebar()
end

----------------------------------------------------------------------

mp.add_forced_key_binding(
    TOGGLE_KEY,
    "folder-sidebar-toggle",
    toggle_sidebar
)

----------------------------------------------------------------------

mp.register_event(
    "file-loaded",
    function()
        if rebuilding_playlist then
            return
        end

        local dir, filename =
            get_current_file()

        if not dir or not filename then
            hide_sidebar()
            return
        end

        -- This script is strictly audio-only. A video/image/other media
        -- file in the same folder must never activate or rebuild the
        -- sidebar playlist.
        if not is_audio_file(filename) then
            managed_dir = nil
            current_dir = nil
            current_filename = nil
            songs = {}
            selected = 1
            scroll_offset = 1
            shuffle_enabled = false
            hide_sidebar()
            return
        end

        local same_folder =
            managed_dir ~= nil
            and normalize_path(managed_dir)
                == normalize_path(dir)

        current_dir = dir
        current_filename = filename

        if not same_folder then
            -- A different folder starts a new playlist in natural order.
            shuffle_enabled = false
            scan_current_directory()
            rebuild_folder_playlist()

        elseif shuffle_enabled then
            -- IMPORTANT: keep the shuffled `songs` array and the shuffled
            -- mpv playlist intact when playback advances to the next song.
            -- Re-scanning the filesystem here would sort `songs` back into
            -- folder order, making the sidebar appear to unshuffle itself.
            apply_loop_mode()
            sync_selection_to_current_song()

        else
            -- With shuffle disabled, the sidebar follows natural folder
            -- order, so rescanning is correct here.
            scan_current_directory()
            apply_loop_mode()
            sync_selection_to_current_song()
        end

        show_sidebar()
    end
)

----------------------------------------------------------------------

----------------------------------------------------------------------
-- In normal mode, explicitly stop when the last playlist entry ends.
--
-- mpv's normal loop-playlist=no already means "do not loop", but
-- mpv.net users may have keep-open or other playback behavior enabled.
-- This handler ensures the sidebar's Normal mode has unambiguous
-- playlist semantics: after the final song, playback stops while the
-- playlist itself remains intact.
----------------------------------------------------------------------

mp.register_event(
    "end-file",
    function(event)
        if rebuilding_playlist then
            return
        end

        if loop_mode ~= "normal" then
            return
        end

        if type(event) ~= "table"
            or event.reason ~= "eof" then
            return
        end

        local pos =
            mp.get_property_number(
                "playlist-pos",
                -1
            )

        local count =
            mp.get_property_number(
                "playlist-count",
                0
            )

        if pos >= 0
            and count > 0
            and pos >= count - 1 then
            mp.commandv(
                "stop",
                "keep-playlist"
            )
        end
    end
)

----------------------------------------------------------------------

mp.observe_property(
    "playlist-pos",
    "native",
    function()
        if rebuilding_playlist then
            return
        end

        sync_selection_to_current_song()

        if sidebar_visible then
            refresh_ui()
        end
    end
)

----------------------------------------------------------------------

mp.observe_property(
    "mouse-pos",
    "native",
    function()
        if sidebar_visible then
            handle_mouse_move()
        end
    end
)

----------------------------------------------------------------------

mp.observe_property(
    "osd-dimensions",
    "native",
    function()
        if sidebar_visible then
            refresh_ui()
        end
    end
)

----------------------------------------------------------------------

-- Initialize immediately if a file is already loaded when the script starts.
-- The file-loaded event above handles subsequent file loads.
do
    local dir, filename = get_current_file()

    if dir and filename and is_audio_file(filename) then
        current_dir = dir
        current_filename = filename

        scan_current_directory()

        if not playlist_is_our_folder() then
            rebuild_folder_playlist()
        else
            apply_loop_mode()
        end

        sync_selection_to_current_song()
        show_sidebar()
    end
end

----------------------------------------------------------------------

overlay.hidden = true
overlay:update()

mp.msg.info(
    "folder-sidebar loaded. Toggle with "
    .. TOGGLE_KEY
)