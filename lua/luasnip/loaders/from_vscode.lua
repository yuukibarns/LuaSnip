local ls = require("luasnip")
local cache = require("luasnip.loaders._caches").vscode
local util = require("luasnip.util.util")
local loader_util = require("luasnip.loaders.util")
local Path = require("luasnip.util.path")
local sp = require("luasnip.nodes.snippetProxy")

local function json_decode(data)
	local status, result = pcall(util.json_decode, data)
	if status then
		return result
	else
		return nil, result
	end
end

local function load_snippet_files(lang, files)
	for _, file in ipairs(files) do
		if not Path.exists(file) then
			goto continue
		end

		-- TODO: make check if file was already parsed once, we can store+reuse the
		-- snippets.

		local lang_snips = {}
		local auto_lang_snips = {}

		local cached_path = cache.path_snippets[file]
		if cached_path then
			lang_snips = cached_path.snippets
			auto_lang_snips = cached_path.autosnippets
		else
			local data = Path.read_file(file)
			local snippet_set_data = json_decode(data)
			if snippet_set_data == nil then
				return
			end

			for name, parts in pairs(snippet_set_data) do
				local body = type(parts.body) == "string" and parts.body
					or table.concat(parts.body, "\n")

				-- There are still some snippets that fail while loading
				pcall(function()
					-- Sometimes it's a list of prefixes instead of a single one
					local prefixes = type(parts.prefix) == "table"
							and parts.prefix
						or { parts.prefix }
					for _, prefix in ipairs(prefixes) do
						local ls_conf = parts.luasnip or {}

						local snip = sp({
							trig = prefix,
							name = name,
							dscr = parts.description or name,
							wordTrig = true,
						}, body)

						if ls_conf.autotrigger then
							table.insert(auto_lang_snips, snip)
						else
							table.insert(lang_snips, snip)
						end
					end
				end)
			end

			-- store snippets to prevent parsing the same file more than once.
			cache.path_snippets[file] = {
				snippets = lang_snips,
				autosnippets = auto_lang_snips,
			}
		end

		-- difference to lua-loader: one file may contribute snippets to
		-- multiple filetypes, so the ft has to be included in the unique!!
		-- augroup.
		vim.cmd(string.format(
			[[
				augroup luasnip_watch_reload
				autocmd BufWritePost %s ++once lua require("luasnip.loaders.from_vscode").reload_file("%s", "%s")
				augroup END
			]],
			-- escape for autocmd-pattern.
			file:gsub(" ", "\\ "),
			-- args for reload.
			lang,
			file
		))

		ls.add_snippets(lang, lang_snips, {
			type = "snippets",
			-- again, include filetype, same reasoning as with augroup.
			key = string.format("__%s_snippets_%s", lang, file),
			refresh_notify = false,
		})
		ls.add_snippets(lang, auto_lang_snips, {
			type = "autosnippets",
			key = string.format("__%s_autosnippets_%s", lang, file),
			refresh_notify = false,
		})

		::continue::
	end

	ls.refresh_notify(lang)
end

--- Find all files+associated filetypes in a package.
---@param root string, directory of the package (immediate parent of the
--- package.json)
---@param filter function that filters filetypes, generate from in/exclude-list
--- via loader_util.ft_filter.
---@return table, string -> string[] (ft -> files).
local function package_files(root, filter)
	local package = Path.join(root, "package.json")
	local data = Path.read_file(package)
	local package_data = json_decode(data)
	if
		not (
			package_data
			and package_data.contributes
			and package_data.contributes.snippets
		)
	then
		-- root doesn't contain a package.json, return no snippets.
		return {}
	end

	-- stores ft -> files(string[]).
	local ft_files = {}

	for _, snippet_entry in pairs(package_data.contributes.snippets) do
		local langs = snippet_entry.language

		if type(langs) ~= "table" then
			langs = { langs }
		end
		for _, ft in ipairs(langs) do
			if filter(ft) then
				if not ft_files[ft] then
					ft_files[ft] = {}
				end
				table.insert(ft_files[ft], Path.join(root, snippet_entry.path))
			end
		end
	end

	return ft_files
end

local function get_snippet_rtp()
	return vim.tbl_map(function(itm)
		return vim.fn.fnamemodify(itm, ":h")
	end, vim.api.nvim_get_runtime_file("package.json", true))
end

-- sanitizes opts and returns ft -> files-map for `opts` (respects in/exclude).
local function get_snippet_files(opts)
	opts = opts or {}

	local paths
	-- list of paths to crawl for loading (could be a table or a comma-separated-list)
	if not opts.paths then
		paths = get_snippet_rtp()
	elseif type(opts.paths) == "string" then
		paths = vim.split(opts.paths, ",")
	else
		paths = opts.paths
	end
	paths = vim.tbl_map(Path.expand, paths) -- Expand before deduping, fake paths will become nil
	paths = util.deduplicate(paths) -- Remove doppelgänger paths and ditch nil ones

	local ft_paths = {}

	local ft_filter = loader_util.ft_filter(opts.exclude, opts.include)
	for _, root_path in ipairs(paths) do
		loader_util.extend_ft_paths(
			ft_paths,
			package_files(root_path, ft_filter)
		)
	end

	return ft_paths
end

local M = {}
function M.load(opts)
	local ft_files = get_snippet_files(opts)

	loader_util.extend_ft_paths(cache.ft_paths, ft_files)

	for ft, files in pairs(ft_files) do
		load_snippet_files(ft, files)
	end
end

function M._luasnip_vscode_lazy_load()
	local fts = util.get_snippet_filetypes()
	for _, ft in ipairs(fts) do
		if not cache.lazy_loaded_ft[ft] then
			cache.lazy_loaded_ft[ft] = true
			load_snippet_files(ft, cache.lazy_load_paths[ft] or {})
		end
	end
end

function M.lazy_load(opts)
	local ft_files = get_snippet_files(opts)

	loader_util.extend_ft_paths(cache.ft_paths, ft_files)

	-- immediately load filetypes that have already been loaded.
	-- They will not be loaded otherwise.
	for ft, files in pairs(ft_files) do
		if cache.lazy_loaded_ft[ft] then
			-- instantly load snippets if they were already loaded...
			load_snippet_files(ft, files)

			-- don't load these files again.
			ft_files[ft] = nil
		end
	end
	loader_util.extend_ft_paths(cache.lazy_load_paths, ft_files)
end

function M.edit_snippet_files()
	loader_util.edit_snippet_files(cache.ft_paths)
end

function M.reload_file(ft, file)
	if cache.path_snippets[file] then
		cache.path_snippets[file] = nil
		load_snippet_files(ft, { file })

		ls.clean_invalidated({ inv_limit = 100 })
	end
end

return M
