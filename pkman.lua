-- pkman.lua: A minimal Lua-based package manager for C++ projects
-- This script downloads, builds, and optionally installs dependencies
-- into a local project directory using Git and various build systems.
--
-- Maintainer: Matthew Moltzau
-- Assistant: Chat-GPT, helped with some documentation, brainstorming, and quick fixes
--
-- Comments in this file:
-- `Maintainer's Note`     Simple facts that I may or may not care to address.
-- `CODE REVIEW(MM)`       My initials, signals that a code review may be necessary. Could be a nit.
--
-- Future Changes Wishlist:
--
-- I want the ability to configure the build location.
--
-- ```
-- {
--   'mosra/corrade',
--   external = {
--     path = '~/git/',
--     show_symlink = true,
--   },
-- }
-- ```
--
-- Alternatively, it can be specified like so?:
-- ```
-- build = {
--    external = '~/git/',
--    show_symlink = true,
-- }
-- ```
--
-- Note: apparently symlinks on Windows require privileges.

require("luarocks.loader")

-- LuaFileSystem for directory handling
local lfs = require("lfs")
-- luv library for async process management
local uv = require("luv")

-- json hash serializes configuration to cache builds better
local cjson = require("cjson")
local sha1 = require("sha1")

cjson.encode_escape_forward_slash(false)

--[[
 Logger module
 A minimal and flexible logger for Lua applications.

 Provides:
 - Log levels (INFO, DEBUG)
 - Customizable formats for info/debug messages
 - Dynamic (lazy) parameters: functions are evaluated at runtime
 - Simple newline management and automatic flushing

 This logger is suitable for CLI tools, debugging output, or structured logs
 in small Lua projects.

 Example usage:

    local logger = Logger:new({
      format = "[%s] %s %s: ",
      params = {
        "INFO",
        function() return os.date("%Y-%m-%d %H:%M:%S") end,
        "SYSTEM"
      },
      debug_format = "[%s][%s] %s: ",
      debug_params = {
        "DEBUG",
        function() return os.date("%Y-%m-%d %H:%M:%S") end,
        "SUBSYSTEM"
      },
      loglevel = Logger.DEBUG
    })

    logger:writeln("Server started.")
    logger:debug("Debugging the system.")
]]
local Logger = {}

--- Info log level.
-- Default log level that outputs informational messages.
-- @field INFO
Logger.INFO = 0

--- Debug log level.
-- Outputs verbose debug messages when enabled.
-- @field DEBUG
Logger.DEBUG = 1

-- Converts varargs to strings and joins them with spaces.
local function _stringify(...)
	local vargs = { ... }
	for i = 1, #vargs do
		vargs[i] = tostring(vargs[i])
	end
	return table.concat(vargs, "")
end

-- Evaluates a params table, calling any functions to get dynamic values.
local function _evaluate(params)
	local result = {}
	for i, v in ipairs(params) do
		if type(v) == "function" then
			result[i] = v()
		else
			result[i] = v
		end
	end
	return result
end

-- Formats a log message without writing it.
--
-- This method returns a formatted log string based on the current `loglevel`.
-- It evaluates any dynamic parameters (functions) before applying the format.
-- Additional arguments passed to this method are stringified and appended
-- to the formatted message.
--
-- This is useful if you want to:
-- - Build log messages for later use
-- - Send log messages to multiple destinations
--
-- @param ... (varargs) Additional values to append to the log message after formatting.
-- @treturn string The fully formatted log message.
function Logger:fmt(...)
	local fmt, params
	if self.loglevel >= Logger.DEBUG then
		fmt = self.debug_format
		params = self.debug_params
	else
		fmt = self.format
		params = self.params
	end

	params = _evaluate(params)
	return string.format(fmt, unpack(params)) .. _stringify(...)
end

-- Writes a log message based on the current log level.
--
-- If `loglevel` is `Logger.DEBUG`, the debug format and parameters are used.
-- Additional varargs are appended to the message, converted to strings.
--
-- @param ... Additional message components appended to the log entry.
function Logger:write(...)
	io.write(self:fmt(...))
	if self._add_newline then
		io.write('\n')
		self._add_newline = false
	end
	io.flush()
end

-- Writes a log message and appends a newline.
--
-- Equivalent to calling `write()` but guarantees the message ends with a newline.
--
-- @param ... Additional message components appended to the log entry.
function Logger:writeln(...)
	self._add_newline = true
	self:write(...)
end

-- Writes a debug log message.
--
-- This is equivalent to calling `writeln()` but is only logged when the log
-- level is `Logger.DEBUG`.
--
-- @param ... Additional message components appended to the debug log entry.
function Logger:debug(...)
	if self.loglevel >= Logger.DEBUG then
		self._add_newline = true
		self:write(...)
	end
end

-- Creates a new Logger instance.
--
-- You can customize formats and parameters for different log levels. `params`
-- and `debug_params` may contain functions, which are evaluated at log time.
--
-- @tparam[opt] table args Logger configuration options:
-- @tparam string args.format Format string for info messages (default: "")
-- @tparam table|function args.params Params table or function for `format` (default: {""})
-- @tparam string args.debug_format Format string for debug messages (default: "DEBUG: ")
-- @tparam table|function args.debug_params Params table for `debug_format` (default: {""})
-- @tparam int args.loglevel Minimum log level to output (default: Logger.INFO)
-- @treturn Logger The newly created Logger instance
function Logger:new(args)
	local obj = {}
	args = args or {}
	obj.format = args.format or ""
	obj.params = args.params or {""}
	obj.debug_format = args.debug_format or "DEBUG: "
	obj.debug_params = args.debug_params or {""}
	obj._add_newline = false
	obj.loglevel = args.loglevel or Logger.INFO
	setmetatable(obj, { __index = Logger })
	return obj
end

--[[
 LineStreamReader async module

 A line-based stream reader designed for handling output from asynchronous I/O streams (such as
 `uv.spawn` processes).

 The `LineStreamReader` reads incoming data chunks from a pipe (stdout/stderr), buffers incomplete
 lines, and outputs full lines with optional prefixes and log formatting. It integrates with a
 `Logger` instance for customizable output.

 This module is useful for capturing real-time output from child processes while maintaining clean,
 prefixed log output.

 Example usage (using luv and Logger):

    local stdout_pipe = uv.new_pipe(false)
    local stderr_pipe = uv.new_pipe(false)

    local stdout_reader = LineStreamReader:new(stdout_pipe, "[myprocess]", "stdout")
    local stderr_reader = LineStreamReader:new(stderr_pipe, "[myprocess]", "stderr")

    uv.spawn("mycommand", {
      stdio = { nil, stdout_pipe, stderr_pipe },
    }, function() ... end)

    uv.read_start(stdout_pipe, function(err, chunk) stdout_reader:on_read(err, chunk) end)
    uv.read_start(stderr_pipe, function(err, chunk) stderr_reader:on_read(err, chunk) end)
]]
local LineStreamReader = {}

-- Processes the current buffer for complete lines.
--
-- Extracts the next complete line (terminated by `\r` or `\n`) from the buffer and writes it using
-- the logger.
-- Returns `true` if a line was processed, or `false` if there are no complete lines available yet.
--
-- @return (boolean) Whether a line could be processed
function LineStreamReader:write_line_stream()
	local index = self.buffer:find("[\r\n]")
	if not index then
		return false
	end

	local line = self.buffer:sub(1, index)
	self.buffer = self.buffer:sub(index + 1)

	self.logger:write(line)
	return true
end

-- Callback function for luv's `uv.read_start`.
--
-- Feeds the incoming chunk into the line stream reader. Buffers partial lines and processes
-- complete lines. If the stream closes (chunk is nil), it logs the closure and closes the
-- associated pipe.
--
-- @param err (string|nil) Error returned by luv (nil if no error)
-- @param chunk (string|nil) The latest chunk of data from the pipe. If nil, the stream has closed.
function LineStreamReader:on_read(err, chunk)
	assert(not err, err)
	if not chunk then
		self.logger:debug("close")
		uv.close(self.pipe)
		return
	end
	self.buffer = chunk
	while self:write_line_stream() do end
end

-- Creates a new LineStreamReader instance.
--
-- The reader buffers incoming data and passes complete lines to its logger for formatted output.
--
-- @param pipe (userdata) The luv pipe to read from (stdout/stderr from a spawned process)
-- @param prefix (string) A label or prefix shown at the beginning of each log line (e.g., process
--   ID, thread name)
-- @param stream_name (string) Typically either "stdout" or "stderr"; used in debug messages
-- @return (LineStreamReader) The initialized reader object
function LineStreamReader:new(pipe, prefix, stream_name)
	local obj = {}
	obj.buffer = ""
	obj.pipe = pipe
	-- \27[K clears the line to avoid artifacts when writing \r
	local clear_line = "\27[K"
	obj.logger = Logger:new({
		format = "%s%s ",
		params = { clear_line, prefix },
		debug_format = "%s%s %s: ",
		debug_params = { clear_line, prefix, stream_name }
	})
	setmetatable(obj, { __index = LineStreamReader })
	return obj
end

-- Launches an asynchronous child process.
--
-- Spawns a system process (via `uv.spawn`) and attaches non-blocking readers
-- to its stdout and stderr pipes. The output is streamed and processed line-by-line
-- using a `LineStreamReader` for each stream.
--
-- Useful for concurrently running commands (e.g., `git clone`, `build tools`) and streaming their
-- logs with contextual prefixes.
--
-- Example usage:
--
--    async("mosra/corrade", "git", {
--      "clone", "--progress", "https://github.com/mosra/corrade.git", "./external/corrade"
--    })
--
--    async("mosra/magnum", "git", {
--      "clone", "--progress", "https://github.com/mosra/magnum.git", "./external/magnum"
--    })
--
--    uv.run() -- Process event loop (call once after async() calls)
--
-- @function async
-- @param id (string) A unique identifier for the async task (e.g., project name or job label).
--             This becomes part of the log prefix for identifying logs from different processes.
-- @param cmd (string) The system command to execute (e.g., "git").
-- @param args (table) An array of arguments passed to the command (e.g., { "clone", "..." }).
local function async(id, cmd, args)
	local stdin = nil
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

	local prefix = string.format("[async %s]", id)
	local logger = Logger:new({
		loglevel = Logger.INFO,
		debug_format = "%s DEBUG: ",
		debug_params = { prefix }
	})

	-- Process creation
	local handle, pid
	local callback = function(code, signal)
		logger:debug(string.format("exited with code %s (pid=%s, signal=%s)", code, pid, signal))
		uv.close(handle)
	end
	handle, pid = uv.spawn(cmd, { args = args, stdio = { stdin, stdout, stderr } }, callback)
	logger:debug(string.format("created (pid=%s)", pid))

	-- Handles stdout and stderr from the process, adding extra context
	local stdout_stream = LineStreamReader:new(stdout, prefix, "stdout")
	local stderr_stream = LineStreamReader:new(stderr, prefix, "stderr")
	uv.read_start(stdout, function(err, chunk)
		stdout_stream:on_read(err, chunk)
	end)
	uv.read_start(stderr, function(err, chunk)
		stderr_stream:on_read(err, chunk)
	end)
end

-- This is my attempt for making type hints, but it isn't complete
--
---@class PkmanBuild
---@field system string? "cmake" | "make" | "meson"
---@field install boolean|string? Install flag or install path
---@field options string[]? Extra options for the build system
---@field parallel boolean? Enable parallel builds
---@field local_source boolean? If true, use build flags appropriate for the local project

---@class PkmanDependency
---@field [1] string? GitHub shorthand, "owner/repo"
---@field url string? Git URL
---@field hash string? Short git hash
---@field refspec string? Tag/branch/full SHA
---@field build PkmanBuild? Build configuration

--[[
 `pkman`: A minimal Lua-based package manager for C++ projects.

 `pkman` is a lightweight, Lua-configurable package manager designed
 to download, build, and manage C++ project dependencies from source.
 Inspired by Neovim plugin managers, it uses simple and declarative Lua tables
 to define dependencies, allowing integration with GitHub, Git URLs, and local builds.

 Dependencies are downloaded into the `./external/` directory by default.
 Each dependency may specify its own build configuration and install path.

 Asynchronous downloading (via `luv`) is used to parallelize dependency fetching,
 while building and installation steps are performed sequentially to avoid race conditions.
]]
local pkman = {}

-- Maintainer's Note: This package is not mature enough for a major version release
pkman.version = "0.1.0"

-- Minimal public interface for defining log levels
pkman.Logger = {}
pkman.Logger.INFO = Logger.INFO
pkman.Logger.DEBUG = Logger.DEBUG

pkman.__logger = Logger:new({ format = "[%s] ", params = { "pkman" } })

function pkman.get_logger()
	return pkman.__logger
end

-- Executes a command.
--
-- This function wraps the execution of external system commands with support for:
-- - Synchronous execution via `os.execute()`
-- - Asynchronous execution via `async()`
-- - Capturing output via `io.popen()`
-- - Logging command execution at different verbosity levels
--
-- @function run_command
-- @param cmd (string) The executable or system command to run (e.g., "cmake", "bash", "git").
-- @param args (table) A sequence table of arguments to pass to the command.
-- @param opts (table) Optional table of execution settings:
--
--   - `capture_output` (boolean): If true, captures and returns the command output (blocking).
--     Mutually exclusive with `async`.
--   - `async` (boolean): If true, runs the command asynchronously using `async()`
--     Mutually exclusive with `capture_output`.
--   - `id` (string): An identifier used for logging purposes in async execution.
--     Ignored if not `async`.
--   - `log_command` (boolean): If true, logs the command at `INFO` level instead of `DEBUG` level.
--
-- @return (string|nil) Returns captured command output if `capture_output` is true.
--   Otherwise returns `nil`.
--
-- @error Raises an error if:
-- - `capture_output` and `async` are both true (unsupported combination)
-- - The command fails (non-zero exit status or signal termination)
--
-- @usage
-- -- Run a command normally (blocking):
-- run_command("cmake", {
--   "-S", "./src",
--   "-B", "./build"
-- })
--
-- -- Run a command asynchronously:
-- run_command("bash", {
--   "-c", "echo Hello; sleep 1; echo Done"
-- }, { async = true, id = "build-job" })
--
-- -- Run a command and capture output:
-- local output = run_command("git", {
--   "rev-parse", "HEAD"
-- }, { capture_output = true })
--
local function run_command(cmd, args, opts)
	opts = opts or {}
	assert(
		not (opts.capture_output and opts.async),
		"Option `capture_output` is not compatible with `async`, it is blocking")

	local logger = pkman.get_logger()

	if opts.log_command then
		logger:writeln("Running: " .. cmd .. " " .. table.concat(args, " "))
	else
		logger:debug("Running: " .. cmd .. " " .. table.concat(args, " "))
	end

	if opts.capture_output then
		local handle, err = io.popen(cmd .. " " .. table.concat(args, " "))
		if not handle then
			error(logger:fmt("Failed to execute command: ", err))
		end
		local result = handle:read("*a")
		handle:close()
		return result
	end

	if opts.async then
		async(opts.id or "<no-ident>", cmd, args)
		return
	end

	local success, exit_type, code = os.execute(cmd .. " " .. table.concat(args, " "))
	if not success then
		if exit_type == "exit" then
			logger:writeln("Command failed with exit code: ", code)
			os.exit(code)
		elseif exit_type == "signal" then
			error(logger:fmt("Command was terminated by signal: ", code))
		else
			error(logger:fmt("Command failed with unknown exit type: ", exit_type))
		end
	end
end


-- Resolves a Git refspec for a repository.
--
-- This function resolves a reference to a specific Git commit SHA from a given repository URL.
--
-- The resolution process attempts the following in order:
-- 1. Expand a short hash into a full SHA if `version.hash` is provided.
-- 2. Return `version.refspec` directly if specified (tag, branch, full SHA).
-- 3. Query the repository for the latest commit on `main` or `master`.
--
-- @function resolve_refspec
-- @param repo_url (string) The Git repository URL to query (e.g.,
--   "https://github.com/mosra/corrade.git").
-- @param version (table) A table defining the version to resolve. It may contain:
--   - `hash` (string): A short commit hash to expand into a full SHA.
--   - `refspec` (string): A direct reference (branch name, tag, or SHA).
-- @treturn string The resolved refspec or commit SHA to be checked out.
--
-- @error Raises an error if:
-- - A short hash is provided but cannot be resolved to a full SHA.
-- - No valid refspec or commit is found on `main` or `master` branches.
--
-- @usage
-- local repo_url = "https://github.com/mosra/corrade.git"
-- local version = { hash = "4ee45ba" }
-- local resolved = resolve_refspec(repo_url, version)
--
-- -- or with explicit refspec:
-- local version = { refspec = "v2020.06" }
-- local resolved = resolve_refspec(repo_url, version)
local function resolve_refspec(repo_url, version)

	-- Expand short hash ref into fully-qualified SHA, if possible. First match wins if ambiguous.
	local function _expand_short_commit_hash(hash)
		local result = run_command("git", {"ls-remote", repo_url}, { capture_output = true })
		if not result then
			return nil
		end
		-- Iterate each line of ls-remote and extract the full SHA if substring matches
		for line in result:gmatch("[^\r\n]+") do
			local full_sha, ref = line:match("(%w+)%s+(%S+)")
			if full_sha and ref then
				if full_sha:sub(1, #hash) == hash then
					return full_sha
				end
			end
		end
		return nil
	end

	-- Queries the latest commit from main/master branch
	local function _get_latest_commit()
		local cmd, args = "git", {
			"ls-remote", repo_url,
			"--heads", "refs/heads/main", "refs/heads/master"}
		local result = run_command(cmd, args, { capture_output = true })
		local main, master = "(%w+)%s+refs/heads/main", "(%w+)%s+refs/heads/master"
		return result and (result:match(main) or result:match(master)) or nil
	end

	local logger = pkman.get_logger()

	local hash
	if version.hash then
		hash = _expand_short_commit_hash(version.hash)
		if hash == nil then
			error(logger:fmt("Could not resolve hash: ", version.hash))
		end
	end
	return hash or version.refspec or _get_latest_commit()
end

-- Downloads or updates a Git repository asynchronously.
--
-- This function downloads a Git repository into the specified `source_dir`,
-- or updates an existing clone to the specified `refspec` or commit.
--
-- The version can be specified as:
-- - A `hash` (short or full commit hash)
-- - A `refspec` (branch, tag, or full SHA)
-- If neither is specified, it defaults to the latest commit on `main` or `master`.
--
-- @function download_git_repo
-- @param id (string) Identifier used for logging (typically the dependency name, e.g.,
-- "mosra/corrade").
-- @param url (string) Git repository URL (e.g., "https://github.com/mosra/corrade.git").
-- @param source_dir (string) Target directory where the repository will be cloned or updated
-- (e.g., "./external/corrade").
-- @param version (table) Table defining the version to checkout:
--   - `hash` (string): A short commit hash (will be expanded to a full SHA).
--   - `refspec` (string): Explicit reference (tag, branch, or SHA).
--
-- @error Raises an error if:
-- - No valid refspec or commit is found to checkout.
-- - The short hash cannot be expanded to a full SHA.
--
-- @usage
-- download_git_repo(
--   "mosra/corrade",
--   "https://github.com/mosra/corrade.git",
--   "./external/corrade",
--   { hash = "4ee45ba" }
-- )
--
-- download_git_repo(
--   "mosra/magnum",
--   "https://github.com/mosra/magnum.git",
--   "./external/magnum",
--   { refspec = "v2020.06" }
-- )
local function download_git_repo(id, url, source_dir, version)

	local logger = pkman.get_logger()

	local refspec = resolve_refspec(url, version)
	if not refspec then
		error(logger:fmt("No tags or commits found for dependency ", id))
	end

	local function _async_clone_repo()
		-- Shallow clone of git repository, fetching only one commit
		run_command("sh", {"-c", table.concat({
				"git init " .. source_dir,
				"git -C " .. source_dir .. " remote add origin " .. url,
				"git -C " .. source_dir .. " fetch --progress --depth 1 --tags origin " .. refspec,
				"git -c advice.detachedHead=false -C " .. source_dir .. " checkout " .. refspec}, "; ")
			}, { id = id, async = true })
	end

	local function _async_update_repo()
		-- Updates the repository to the referenced commit, fetching only that commit
		run_command("bash", {"-c", table.concat({
				"git -C " .. source_dir .. " fetch --depth 1 --tags origin " .. refspec,
				"git -c advice.detachedHead=false -C " .. source_dir .. " checkout " .. refspec}, "; ")
			}, { id = id, async = true })
	end

	-- Gets the currently installed version (Git commit hash) for a cloned repository
	local function _get_installed_version(module_dir)
		local cmd, args = "git", {"-C", module_dir, "rev-parse", "HEAD"}
		local result = run_command(cmd , args, { capture_output = true })
		return result and result:gsub("\n", "")
	end

	if not lfs.attributes(source_dir) then
		_async_clone_repo()
		return
	end

	-- Handle cases where clone has already occurred
	local installed_version = _get_installed_version(source_dir)
	if installed_version == refspec then
		local hash = refspec:sub(1, 7)
		logger:writeln(id .. " already installed (commit " .. hash .. ")")
	else
		logger:writeln("Updating dependency \"" .. id .. "\" to " .. refspec)
		_async_update_repo()
	end
end

local function hash_directory_mtime(path)

	local function _collect_mtimes_recursive(dir, mtimes)
		mtimes = mtimes or {}

		for entry in lfs.dir(dir) do
			if entry ~= "." and entry ~= ".." then
				local fullpath = dir .. "/" .. entry
				local attr = lfs.attributes(fullpath)
				if attr.mode == "file" then
					table.insert(mtimes, attr.modification)
				elseif attr.mode == "directory" then
					_collect_mtimes_recursive(fullpath, mtimes)
				end
			end
		end
		return mtimes
	end

	-- String concatenation is technically more correct than addition, but the likihood of summing to
	-- the same number seems highly unlikely. Using integer addition for marginal speed gain.
	local mtimes = _collect_mtimes_recursive(path)
	local sum = 0
	for _, timestamp in ipairs(mtimes) do
		sum = sum + timestamp
	end
	return sha1(tostring(sum))
end

-- Processes a dependency and schedules its download or update.
--
-- This function parses the dependency definition, constructs the appropriate repository URL
-- and paths, and calls `download_git_repo()` to clone or update the dependency.
--
-- It supports two dependency formats:
-- - A **string**: `"owner/project_name"`, implying a GitHub repository.
-- - A **table**: which may contain:
--   - `url`: A custom Git URL (non-GitHub).
--   - `[1]`: A string `"owner/project_name"` for GitHub-style references.
--   - `hash` (optional): A short commit hash to resolve and checkout.
--   - `refspec` (optional): An explicit branch, tag, or commit SHA.
--   - `build` (optional): A table defining build instructions for the dependency.
--
-- If `build` is defined, the function returns build metadata for subsequent processing.
--
-- @function process_dependency
-- @param download_path (string) The base directory where the dependency should be downloaded.
--   Example: `"./external"`.
-- @param dep (string|table) The dependency reference.
--   - A GitHub `"owner/project"` string.
--   - A table with `url`, `hash`, `refspec`, and/or `build`.
--
--- @return { source_dir: string, build_dir: string, build_spec: PkmanBuild }|nil Returns `nil` if no build
--- instructions are specified.
--   Otherwise, returns a table `{ source_dir, build_dir, build_spec }`, where:
--   - `source_dir` (string): The path where the source repo is cloned.
--   - `build_dir` (string): The corresponding build directory (typically `source_dir .. "-build"`).
--   - `build_spec` (table): The `build` table from the dependency describing how to build it.
--
-- @error Raises an error if:
-- - The dependency format is invalid.
-- - Required fields are missing from the dependency table.
--
-- @usage
-- local build_info = process_dependency("./external", "mosra/corrade")
-- -- or with build instructions:
-- local build_info = process_dependency("./external", {
--   "mosra/corrade",
--   hash = "4ee45ba",
--   build = {
--     system = "cmake",
--     options = { "-DCMAKE_BUILD_TYPE=Release" },
--   }
-- })
local function process_dependency(download_path, dep)
	local logger = pkman.get_logger()
	local owner, project_name, url

	if type(dep) == "string" then
		owner, project_name = dep:match("([^/]+)/([^/]+)")
		url = string.format("https://github.com/%s/%s.git", owner, project_name)
	elseif type(dep) == "table" then
		if dep.url then
			owner, project_name = dep.url:match("([^/]+)/([^/]+)")
			url = dep.url
		elseif dep[1] then
			owner, project_name = dep[1]:match("([^/]+)/([^/]+)")
			url = string.format("https://github.com/%s/%s.git", owner, project_name)
		else
			dep.build.local_source = true
			-- Hash serialization of dependency for config caching logic
			dep.build.refhash = { key="local", value={source_hash=hash_directory_mtime("./src"), conf_hash=table.hash(dep)} }
			return { "./src", "./build", dep.build }
		end
	else
		error(logger:fmt("Invalid dependency format: dependency must be either table or string"))
	end

	local source_dir = string.format("%s/%s", download_path, project_name)
	local build_dir = string.format("%s/%s-build", download_path, project_name)

	local ref = string.format("%s/%s", owner, project_name)
	if type(dep) == "string" then
		download_git_repo(ref, url, source_dir)
	elseif type(dep) == "table" then
		download_git_repo(ref, url, source_dir, { hash=dep.hash, refspec=dep.refspec })
	end

	if not dep.build then
		return nil
	end
	-- Hash serialization of dependency for config caching logic
	dep.build.refhash = { key=ref, value={source_hash=hash_directory_mtime(source_dir), conf_hash=table.hash(dep)} }
	return { source_dir, build_dir, dep.build }
end

function table.nonils(t)
	local j = 1
	for i = 1, #t do
		if t[i] ~= nil then
			t[j] = t[i]
			j = j + 1
		end
	end
	for i = j, #t do
		t[i] = nil
	end
	return t
end

function table.make_hashtable_hashable(tbl)
	local keys = {}
	local vals = {}
	local indices = {}

	for k, v in pairs(tbl) do
		if type(v) ~= "function" then
			table.insert(vals, (type(v) == "table" and table.make_hashtable_hashable(v)) or v)
			table.insert(keys, k)
		end
	end

	for i = 1, #keys do
		indices[i] = i
	end
	table.sort(indices, function(a, b)
		-- Tables contain string keys and indexes (integers), which are not comparable
		if type(keys[a]) == type(keys[b]) then return keys[a] < keys[b] end
		return false
	end)

	local sorted_values = {}
	for i, idx in ipairs(indices) do
		sorted_values[i] = vals[idx]
	end
	return sorted_values
end

function table.hash(t)
	return sha1.sha1(cjson.encode(table.make_hashtable_hashable(t)))
end

local function any(tbl, predicate)
	for _, v in ipairs(tbl) do
		if predicate(v) then return true end
	end
	return false
end

-- Builds a project using the specified build system.
--
-- This function handles building and optionally installing a dependency based on
-- the provided build configuration.
--
-- It supports the following build systems:
-- - `"cmake"` (default): Runs `cmake` configure, build, and install steps.
-- - `"make"`: Runs `make` and optionally installs with `DESTDIR`.
-- - `"meson"`: Runs `meson setup`, `compile`, and `install`.
--
-- The function automatically creates the `build_dir` if it doesn't exist.
-- The install step is enabled by default unless explicitly disabled in the `build` table.
--
-- @function build_project
-- @param source_dir (string) The path to the source directory of the project (e.g.,
--   `"./external/corrade"`).
-- @param build_dir (string) The path to the build directory where the project will be built (e.g.,
--   `"./external/corrade-build"`).
-- @param build (table) Build configuration options:
--   - `system` (string): The build system to use. Defaults to `"cmake"`.
--   - `install` (boolean|string): If `true`, installs to `<build_dir>/install`.
--     If `false` (default), disables install.
--     If a string, specifies a custom install path.
--   - `options` (table): Additional arguments to pass to the configure step (`cmake`, etc.).
--   - `parallel` (boolean): Enables parallel build
--
-- @error Raises an error if:
-- - The build system is unsupported.
--
-- @usage
-- build_project("./external/corrade", "./external/corrade-build", {
--   system = "cmake",
--   install = true,
--   options = {
--     "-DCMAKE_BUILD_TYPE=Release"
--   },
--   parallel = true
-- })
--
-- build_project("./external/project", "./external/project-build", {
--   system = "make",
--   install = true,
--   parallel = true
-- })
local function build_project(build_metadata, source_dir, build_dir, build_spec)
	local logger = pkman.get_logger()

	lfs.mkdir(build_dir)

	-- Maintainer's Note: I have not tested make, meson, or any custom builds. Just cmake.
	-- I don't have automated tests, nor have I tested Linux or Windows.
	if build_spec.system == "cmake" then

		-- Set CMAKE_PREFIX_PATH based on dependencies
		if build_spec.dependencies then
			local prefix_paths = {}
			for _, dep_name in ipairs(build_spec.dependencies) do
				local dep_path = build_metadata[dep_name]["install_path"]
				if dep_path then
					-- CODE REVIEW(MM): An actual function to resolve the path would be preferrable. Hopefully
					-- LuaFileSystem will get a function for resolving an absolute path in the future.
					dep_path = lfs.currentdir() .. "/" .. dep_path
					logger:debug(string.format("Adding %s to cmake prefix paths", dep_name))
					table.insert(prefix_paths, dep_path)
				else
					logger:debug("Dependency not found: ", dep_name)
				end
			end

			if #prefix_paths > 0 then
			  table.insert(build_spec.options, '-DCMAKE_PREFIX_PATH="' .. table.concat(prefix_paths, ";") .. '"')
			end
		end

		-- Falsy value must be nil, not false for this to work as intended
		local is_dep = (not build_spec.local_source) or nil
		local install = (build_spec.install) or nil

		run_command("cmake", table.nonils({
			"-B", build_dir,
			is_dep and "-S",
			is_dep and source_dir,
			is_dep and "-Wno-dev",
			install and "-DCMAKE_INSTALL_PREFIX=" .. build_spec.install,
			unpack(build_spec.options)
		}), { log_command = true })

		run_command("cmake", {
			"--build", build_dir,
			unpack({ build_spec.parallel and "--parallel" or "" })
		})

		if build_spec.install then
			-- MM: CMake 3.15 introduces `cmake --install build_dir`, but I like the below because I see
			-- output from the build system. e.g. "make: *** No rule to make target install'.  Stop."
			run_command("cmake", {
				"--build", build_dir,
				"--target", "install",
				unpack({ build_spec.parallel and "--parallel" or "" })
			})
		end

	elseif build_spec.system == "make" then
		run_command("make", {"-C", build_dir, build_spec.parallel and "-j" or ""})
		if build_spec.install then
			run_command("make", {"-C", build_dir, "DESTDIR=" .. build_spec.install})
		end
	elseif build_spec.system == "meson" then
		run_command("meson", {"setup", build_dir, source_dir, "-Wno-dev"})
		run_command("meson", {"compile", "-C", build_dir})
		if build_spec.install then
			run_command("meson", {"install", "-C", "--destdir=" .. build_spec.install})
		end
	else
		error(logger:fmt("Unsupported build system: ", build_spec.system))
	end
end

-- Simple decorator for changing directories.
--
-- Note: It would be preferable to provide decorators that reference directories relevant to the
-- dependency. However, these decorators can't be implemented without a global lookup table.
-- Knowing the correct directory to provide this function is simple, so: wontfix
--
--- @function pkman.with_dir
--- @param dir (string) chdir to this directory
--- @param fn (function) the function to wrap
function pkman.with_dir(dir, fn)
	local logger = pkman.get_logger()
	return function(...)
		local cwd = lfs.currentdir()
		logger:debug("chdir ", dir)
		assert(lfs.chdir(dir))
		local ok, result = pcall(fn, ...)
		logger:debug("chdir ", cwd)
		assert(lfs.chdir(cwd))
		if not ok then
			error(result)
		end
		return result
	end
end

--- Entry point for setting up and building project dependencies.
---
--- This function processes a list of dependencies, downloads them (asynchronously),
--- waits for all downloads to finish, and then builds each dependency sequentially.
---
--- Dependencies are declared in a table format and support both simple and advanced configurations:
---
--- - A string: `"owner/project"` GitHub shorthand reference (e.g., `"mosra/corrade"`).
--- - A table with additional fields, including:
---   - `url`: Explicit Git URL (for non-GitHub repositories).
---   - `hash`: Short Git commit hash (expanded to full SHA).
---   - `refspec`: Git refspec (branch, tag, or full SHA).
---   - `build`: A table defining build options (system, install, options, parallel).
---
--- Dependencies are downloaded into `./external/` by default.
--- Builds happen in sequence after downloads complete.
---
--- @function pkman.setup
--- @param dependencies (string|PkmanDependency)[] List of dependencies to download and build.
---   Each dependency can be a string (GitHub shorthand) or a table with detailed config.
---
--- @usage
--- pkman.setup {
---   {
---     -- github owner/project ref, similar to Neovim
---     'mosra/corrade',
---     -- shortened commit hash
---     hash = '4ee45ba',
---     -- Minimal configuration is simply `build = {}`
---     build = {
---       -- The default build system is 'cmake'
---       system = 'cmake',
---       -- Install may simply be "true", which is its default value.
---       -- The default install path is `"external/<project-name>-build/install"`.
---       install = './external/corrade-build/install'
---       options = {
---         -- The c++ compiler is the default on MacOS
---         '-DCMAKE_CXX_COMPILER=c++',
---       },
---       -- Creates as many threads as there are cores
---       parallel = true,
---     },
---   },
---   {
---     -- An explicit url may be specified, this is useful for non-github repositories.
---     url = 'https://github.com/mosra/corrade.git',
---     -- Refspecs by example: (but obviously you can only specify one in an actual config)
---     -- Fully-qualified SHA
---     refspec = '4ee45ba341febe1744733abd1449460124363c8f',
---     -- branch
---     refspec = 'master',
---     -- tag
---     refspec = 'v2020.06',
---   },
--- }
function pkman.setup(dependencies)
	local build_deps = {}
	local build_metadata = {}
	local external = "external"

	local logger = pkman.get_logger()

	lfs.mkdir(external)
	for _, dep in ipairs(dependencies) do
		local build_args = process_dependency(external, dep)
		if build_args then
			table.insert(build_deps, build_args)
		end
	end

	-- Wait for async functions
	uv.run()

	local dep_cache_from_disk = {}
	local dep_cache_to_disk = {}
	local lockfilename = ".pkman_dep.cache"
	local lockfile = io.open(lockfilename, "r")
	if lockfile then
		logger:debug("Reading from ", lockfilename)
		dep_cache_from_disk = cjson.decode(lockfile:read("*a"))
		lockfile:close()
	end

	for _, build_args in ipairs(build_deps) do
		local source_dir, build_dir, build_spec = unpack(build_args)

		-- The callbacks may change the directory, so the original cwd is kept.
		-- cwd needs to be defined before the goto is used, or it is an error
		local cwd = lfs.currentdir()

		-- Handle default values
		build_spec.system = build_spec.system or "cmake"
		build_spec.install = (build_spec.install == true and build_dir .. "/install") or build_spec.install
		build_spec.options = build_spec.options or {}
		build_spec.dependencies = build_spec.dependencies or {}

		-- build_spec.install => (no install directory => should install), no build_spec.install => no install
		local no_install_needed = (build_spec.install and lfs.attributes(build_spec.install)) or true

		local no_dependency_updates = not any(build_spec.dependencies, function(k)
			return build_metadata[k]["built"]
		end)

		-- Initialize metadata for key
		dep_cache_from_disk[build_spec.refhash.key] = dep_cache_from_disk[build_spec.refhash.key] or {}
		build_metadata[build_spec.refhash.key] = build_metadata[build_spec.refhash.key] or {}
		build_metadata[build_spec.refhash.key]["install_path"] = build_spec.install or nil

		if (not build_spec.force_rebuild and no_install_needed and no_dependency_updates and
			dep_cache_from_disk[build_spec.refhash.key].source_hash == build_spec.refhash.value.source_hash and
			dep_cache_from_disk[build_spec.refhash.key].conf_hash == build_spec.refhash.value.conf_hash and
			lfs.attributes(build_dir)) then
			logger:writeln("Skipping build ", build_spec.refhash.key)
			goto skip_build
		end

		-- Update metadata
		build_metadata[build_spec.refhash.key]["built"] = true

		if build_spec.pre_build then
			build_spec.pre_build()
			lfs.chdir(cwd)
		end

		build_project(build_metadata, source_dir, build_dir, build_spec)

		if build_spec.post_build then
			build_spec.post_build()
			lfs.chdir(cwd)
		end
		::skip_build::
		dep_cache_to_disk[build_spec.refhash.key] = build_spec.refhash.value
	end
	local file = io.open(lockfilename, "w")
	if file then
		logger:debug("Writing to ", lockfilename)
		file:write(cjson.encode(dep_cache_to_disk))
		file:close()
	end
end

return pkman
