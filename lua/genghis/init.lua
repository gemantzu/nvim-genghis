local M = {}

local expand = vim.fn.expand
local fn = vim.fn
local cmd = vim.cmd

local mv = require("genghis.file-movement")
local u = require("genghis.utils")

--------------------------------------------------------------------------------

---Performing common file operation tasks
---@param op "rename"|"duplicate"|"new"|"newFromSel"|"move-rename"
local function fileOp(op)
	local oldFilePath = vim.api.nvim_buf_get_name(0)
	local oldName = vim.fs.basename(oldFilePath)
	local dir = vim.fs.dirname(oldFilePath) -- same directory, *not* pwd
	local oldNameNoExt = oldName:gsub("%.%w+$", "")
	local oldExt = expand("%:e")
	if oldExt ~= "" then oldExt = "." .. oldExt end

	local prevReg
	if op == "newFromSel" then
		prevReg = fn.getreg("z")
		u.leaveVisualMode()
		cmd([['<,'>delete z]])
	end

	local promptStr, prefill
	if op == "duplicate" then
		promptStr = "Duplicate File as: "
		prefill = oldNameNoExt .. "-1"
	elseif op == "rename" then
		promptStr = mv.lspSupportsRenaming() and "Rename File & Update Imports:" or "Rename File to:"
		prefill = oldNameNoExt
	elseif op == "move-rename" then
		promptStr = mv.lspSupportsRenaming() and "Move-Rename File & Update Imports:"
			or "Move & Rename File to:"
		prefill = dir .. "/"
	elseif op == "new" or op == "newFromSel" then
		promptStr = "Name for New File: "
		prefill = ""
	end

	-- INFO completion = "dir" allows for completion via cmp-omni
	vim.ui.input({
		prompt = promptStr,
		default = prefill,
		completion = "dir",
	}, function(newName)
		cmd.redraw() -- Clear message area from ui.input prompt

		-- VALIDATION OF FILENAME
		if not newName then return end -- input has been canceled

		if newName:find("/$") then
			newName = newName .. oldName -- use the new directory with the old name
		end

		local invalidName = newName:find("^%s+$")
			or newName:find("[\\:]")
			or (newName:find("^/") and not op == "move-rename")
		local sameName = newName == oldName
		local emptyInput = newName == ""

		if invalidName or sameName or (emptyInput and op ~= "new") then
			if op == "newFromSel" then
				cmd.undo() -- undo deletion
				fn.setreg("z", prevReg) -- restore register content
			end
			if invalidName or emptyInput then
				u.notify("Invalid filename.", "error")
			elseif sameName then
				u.notify("Cannot use the same filename.", "error")
			end
			return
		end

		-- exception: new file creaton allows for empty input
		if emptyInput and op == "new" then newName = "Untitled" end

		-- DETERMINE PATH AND EXTENSION
		local hasPath = newName:find("/")
		if hasPath then
			local newFolder = vim.fs.dirname(newName)
			fn.mkdir(newFolder, "p") -- create folders if necessary
		end

		local extProvided = newName:find(".%.[^/]*$") -- non-leading dot to not include dotfiles without extension
		if not extProvided then newName = newName .. oldExt end
		local newFilePath = (op == "move-rename") and newName or dir .. "/" .. newName

		if u.fileExists(newFilePath) then
			u.notify(("File with name %q already exists."):format(newFilePath), "error")
			return
		end

		-- EXECUTE FILE OPERATION
		cmd.update() -- save current file; needed for users with `vim.opt.hidden=false`
		if op == "duplicate" then
			local success = vim.loop.fs_copyfile(oldFilePath, newFilePath)
			if success then
				cmd.edit(newFilePath)
				u.notify(("Duplicated %q as %q."):format(oldName, newName))
			end
		elseif op == "rename" or op == "move-rename" then
			mv.onRename(oldFilePath, newFilePath)
			local success = mv.moveFile(oldFilePath, newFilePath)
			if success then
				cmd.edit(newFilePath)
				u.bwipeout("#")
				u.notify(("Renamed %q to %q."):format(oldName, newName))
			end
		elseif op == "new" or op == "newFromSel" then
			cmd.edit(newFilePath)
			if op == "newFromSel" then
				cmd("put z") -- cmd.put("z") does not work
				fn.setreg("z", prevReg) -- restore register content
			end
			cmd.write(newFilePath)
		end
	end)
end

function M.renameFile() fileOp("rename") end
function M.moveAndRenameFile() fileOp("move-rename") end
function M.duplicateFile() fileOp("duplicate") end
function M.createNewFile() fileOp("new") end
function M.moveSelectionToNewFile() fileOp("newFromSel") end

--------------------------------------------------------------------------------

---copying file information
---@param expandOperation string
local function copyOp(expandOperation)
	local reg = '"'
	local clipboardOpt = vim.opt.clipboard:get()
	local useSystemClipb = vim.g.genghis_use_systemclipboard
		or (#clipboardOpt > 0 and clipboardOpt[1]:find("unnamed"))
	if useSystemClipb then reg = "+" end

	local toCopy = expand(expandOperation)
	fn.setreg(reg, toCopy)
	vim.notify(toCopy, vim.log.levels.INFO, { title = "Copied" })
end

function M.copyFilepath() copyOp("%:p") end
function M.copyFilename() copyOp("%:t") end
function M.copyRelativePath() copyOp("%:~:.") end
function M.copyDirectoryPath() copyOp("%:p:h") end
function M.copyRelativeDirectoryPath() copyOp("%:~:.:h") end

--------------------------------------------------------------------------------

---Makes current file executable
function M.chmodx()
	local filename = vim.api.nvim_buf_get_name(0)
	local perm = fn.getfperm(filename)
	perm = perm:gsub("r(.)%-", "r%1x") -- add x to every group that has r
	fn.setfperm(filename, perm)
	u.notify("Execution Permission granted.")
	cmd.edit()
end

---@param opts? {trashLocation: string}
function M.trashFile(opts)
	cmd.update { bang = true }
	local trash
	local home = os.getenv("HOME")
	local oldFilePath = vim.api.nvim_buf_get_name(0)
	local oldName = vim.fs.basename(oldFilePath)

	-- Default trash locations
	if fn.has("linux") == 1 then
		local xdg_data = os.getenv("XDG_DATA_HOME")
		trash = xdg_data and xdg_data .. "/Trash/" or home .. "/.local/share/Trash/"
	elseif fn.has("macunix") == 1 then
		-- INFO macOS moves files to the icloud trash, if they are deleted from
		-- icloud folder, otherwise they go the user trash folder
		local iCloudPath = home .. "/Library/Mobile Documents/com~apple~CloudDocs"
		local isInICloud = fn.expand("%:p:h"):sub(1, #iCloudPath) == iCloudPath
		trash = isInICloud and iCloudPath .. "/.Trash/" or home .. "/.Trash/"
	else
		-- TODO better support for windows
		trash = home .. "/.Trash/"
	end

	-- overwrite trash location, if specified by user
	if opts and opts.trashLocation then
		trash = opts.trashLocation
		if not (trash:find("/$")) then trash = trash .. "/" end
	end

	fn.mkdir(trash, "p")
	if u.fileExists(trash .. oldName) then oldName = oldName .. "~" end

	if mv.moveFile(oldFilePath, trash .. oldName) then
		u.bwipeout()
		u.notify(("%q deleted"):format(oldName))
	end
end

--------------------------------------------------------------------------------
return M