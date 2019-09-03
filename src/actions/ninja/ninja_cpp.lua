--
-- GENie - Project generator tool
-- https://github.com/bkaradzic/GENie#license
--

premake.ninja.cpp = { }
local ninja = premake.ninja
local cpp   = premake.ninja.cpp
local p     = premake

local function wrap_ninja_cmd(c)
	if os.is("windows") then
		return 'cmd /c "' .. c .. '"'
	else
		return c
	end
end

-- generate project + config build file
	function ninja.generate_cpp(prj)
		local pxy = ninja.get_proxy("prj", prj)
		local tool = premake.gettool(prj)

		-- build a list of supported target platforms that also includes a generic build
		local platforms = premake.filterplatforms(prj.solution, tool.platforms, "Native")

		for _, platform in ipairs(platforms) do
			for cfg in p.eachconfig(pxy, platform) do
				p.generate(cfg, cfg:getprojectfilename(), function() cpp.generate_config(prj, cfg) end)
			end
		end
	end

	function cpp.generate_config(prj, cfg)
		local tool = premake.gettool(prj)

		_p('# Ninja build project file autogenerated by GENie')
		_p('# https://github.com/bkaradzic/GENie')
		_p("")

		-- needed for implicit outputs, introduced in 1.7
		_p("ninja_required_version = 1.7")
		_p("")

		local flags = {
			defines   = ninja.list(tool.getdefines(cfg.defines)),
			includes  = ninja.list(table.join(tool.getincludedirs(cfg.includedirs), tool.getquoteincludedirs(cfg.userincludedirs), tool.getsystemincludedirs(cfg.systemincludedirs))),
			cppflags  = ninja.list(tool.getcppflags(cfg)),
			asmflags  = ninja.list(table.join(tool.getcflags(cfg), cfg.buildoptions, cfg.buildoptions_asm)),
			cflags    = ninja.list(table.join(tool.getcflags(cfg), cfg.buildoptions, cfg.buildoptions_c)),
			cxxflags  = ninja.list(table.join(tool.getcflags(cfg), tool.getcxxflags(cfg), cfg.buildoptions, cfg.buildoptions_cpp)),
			objcflags = ninja.list(table.join(tool.getcflags(cfg), tool.getcxxflags(cfg), cfg.buildoptions, cfg.buildoptions_objc)),
		}

		_p("")

		_p("# core rules for " .. cfg.name)
		_p("rule cc")
		_p("  command     = " .. wrap_ninja_cmd(tool.cc .. " $defines $includes $flags -MMD -MF $out.d -c -o $out $in"))
		_p("  description = cc $out")
		_p("  depfile     = $out.d")
		_p("  deps        = gcc")
		_p("")
		_p("rule cxx")
		_p("  command     = " .. wrap_ninja_cmd(tool.cxx .. " $defines $includes $flags -MMD -MF $out.d -c -o $out $in"))
		_p("  description = cxx $out")
		_p("  depfile     = $out.d")
		_p("  deps        = gcc")
		_p("")
		_p("rule ar")
		_p("  command         = " .. wrap_ninja_cmd(tool.ar .. " $flags $out @$out.rsp " .. (os.is("MacOSX") and " 2>&1 > /dev/null | sed -e '/.o) has no symbols$$/d'" or "")))
		_p("  description     = ar $out")
		_p("  rspfile         = $out.rsp")
		_p("  rspfile_content = $in $libs")
		_p("")

		local link = iif(cfg.language == "C", tool.cc, tool.cxx)
		_p("rule link")
		local startgroup = ''
		local endgroup = ''
		if (cfg.flags.LinkSupportCircularDependencies) then
			startgroup = '-Wl,--start-group'
			endgroup = '-Wl,--end-group'
		end
		_p("  command         = " .. wrap_ninja_cmd("$pre_link " .. link .. " -o $out @$out.rsp $all_ldflags $post_build"))
		_p("  description     = link $out")
		_p("  rspfile         = $out.rsp")
  		_p("  rspfile_content = $all_outputfiles " .. string.format("%s $libs %s", startgroup, endgroup))
		_p("")

		_p("rule exec")
		_p("  command     = " .. wrap_ninja_cmd("$command"))
		_p("  description = Run $type commands")
		_p("")

		if #cfg.prebuildcommands > 0 then
			_p("build __prebuildcommands_" .. premake.esc(prj.name) .. ": exec")
			_p(1, "command = " .. wrap_ninja_cmd("echo Running pre-build commands && " .. table.implode(cfg.prebuildcommands, "", "", " && ")))
			_p(1, "type    = pre-build")
			_p("")
		end

		cfg.pchheader_full = cfg.pchheader
		for _, incdir in ipairs(cfg.includedirs) do
			-- convert this back to an absolute path for os.isfile()
			local abspath = path.getabsolute(path.join(cfg.project.location, cfg.shortname, incdir))

			local testname = path.join(abspath, cfg.pchheader_full)
			if os.isfile(testname) then
				cfg.pchheader_full = path.getrelative(cfg.location, testname)
				break
			end
		end

		cpp.custombuildtask(prj, cfg)

		cpp.dependencyRules(prj, cfg)

		cpp.file_rules(prj, cfg, flags)

		local objfiles = {}

		for _, file in ipairs(cfg.files) do
			if path.issourcefile(file) then
				table.insert(objfiles, cpp.objectname(cfg, file))
			end
		end
		_p('')

		cpp.linker(prj, cfg, objfiles, tool, flags)

		_p("")
	end

	function cpp.custombuildtask(prj, cfg)
		local cmd_index = 1
		local seen_commands = {}
		local command_by_name = {}
		local command_files = {}

		local prebuildsuffix = #cfg.prebuildcommands > 0 and "||__prebuildcommands_" .. premake.esc(prj.name) or ""

		for _, custombuildtask in ipairs(prj.custombuildtask or {}) do
			for _, buildtask in ipairs(custombuildtask or {}) do
				for _, cmd in ipairs(buildtask[4] or {}) do
					local num = 1

					-- replace dependencies in the command with actual file paths
					for _, depdata in ipairs(buildtask[3] or {}) do
						cmd = string.gsub(cmd,"%$%(" .. num .."%)", string.format("%s ", path.getrelative(cfg.location, depdata)))
						num = num + 1
					end

					-- replace $(<) and $(@) with $in and $out
					cmd = string.gsub(cmd, '%$%(<%)', '$in')
					cmd = string.gsub(cmd, '%$%(@%)', '$out')

					local cmd_name -- shortened command name

					-- generate shortened rule names for the command, may be nonsensical
					-- in some cases but it will at least be unique.
					if seen_commands[cmd] == nil then
						local _, _, name = string.find(cmd, '([.%w]+)%s')
						name = 'cmd' .. cmd_index .. '_' .. string.gsub(name, '[^%w]', '_')

						seen_commands[cmd] = {
							name = name,
							index = cmd_index,
						}

						cmd_index = cmd_index + 1
						cmd_name = name
					else
						cmd_name = seen_commands[cmd].name
					end

					local index = seen_commands[cmd].index

					if command_files[index] == nil then
						command_files[index] = {}
					end

					local cmd_set = command_files[index]

					table.insert(cmd_set, {
						buildtask[1],
						buildtask[2],
						buildtask[3],
						seen_commands[cmd].name,
					})

					command_files[index] = cmd_set
					command_by_name[cmd_name] = cmd
				end
			end
		end

		_p("# custom build rules")
		for command, details in pairs(seen_commands) do
			_p("rule " .. details.name)
			_p(1, "command = " .. wrap_ninja_cmd(command))
		end

		for cmd_index, cmdsets in ipairs(command_files) do
			for _, cmdset in ipairs(cmdsets) do
				local file_in = path.getrelative(cfg.location, cmdset[1])
				local file_out = path.getrelative(cfg.location, cmdset[2])
				local deps = ''
				for i, dep in ipairs(cmdset[3]) do
					deps = deps .. path.getrelative(cfg.location, dep) .. ' '
				end
				_p("build " .. file_out .. ': ' .. cmdset[4] .. ' ' .. file_in .. ' | ' .. deps .. prebuildsuffix)
				_p("")
			end
		end
	end

	function cpp.dependencyRules(prj, cfg)
		local extra_deps = {}
		local order_deps = {}
		local extra_flags = {}

		for _, dependency in ipairs(prj.dependency or {}) do
			for _, dep in ipairs(dependency or {}) do
				-- This is assuming that the depending object is (going to be) an .o file
				local objfilename = cpp.objectname(cfg, path.getrelative(prj.location, dep[1]))
				local dependency = path.getrelative(cfg.location, dep[2])

				-- ensure a table exists for the dependent object file
				if extra_deps[objfilename] == nil then
					extra_deps[objfilename] = {}
				end

				table.insert(extra_deps[objfilename], dependency)
			end
		end

		local pchfilename = cfg.pchheader_full and cpp.pchname(cfg, cfg.pchheader_full) or ''
		for _, file in ipairs(cfg.files) do
			local objfilename = file == cfg.pchheader and cpp.pchname(cfg, file) or cpp.objectname(cfg, file)
			if path.issourcefile(file) or file == cfg.pchheader then
				if #cfg.prebuildcommands > 0 then
					if order_deps[objfilename] == nil then
						order_deps[objfilename] = {}
					end
					table.insert(order_deps[objfilename], '__prebuildcommands_' .. premake.esc(prj.name))
				end
			end
			if path.issourcefile(file) then
				if cfg.pchheader_full and not cfg.flags.NoPCH then
					local nopch = table.icontains(prj.nopch, file)
					if not nopch then
						local suffix = path.isobjcfile(file) and '_objc' or ''
						if extra_deps[objfilename] == nil then
							extra_deps[objfilename] = {}
						end
						table.insert(extra_deps[objfilename], pchfilename .. suffix .. ".gch")

						if extra_flags[objfilename] == nil then
							extra_flags[objfilename] = {}
						end
						table.insert(extra_flags[objfilename], '-include ' .. pchfilename .. suffix)
					end
				end
			end
		end

		-- store prepared deps for file_rules() phase
		cfg.extra_deps = extra_deps
		cfg.order_deps = order_deps
		cfg.extra_flags = extra_flags
	end

	function cpp.objectname(cfg, file)
		return path.join(cfg.objectsdir, path.trimdots(path.removeext(file)) .. ".o")
	end

	function cpp.pchname(cfg, file)
		return path.join(cfg.objectsdir, path.trimdots(file))
	end

	function cpp.file_rules(prj,cfg, flags)
		_p("# build files")

		for _, file in ipairs(cfg.files) do
			_p("# FILE: " .. file)
			if cfg.pchheader_full == file then
				local pchfilename = cpp.pchname(cfg, file)
				local extra_deps = #cfg.extra_deps and '| ' .. table.concat(cfg.extra_deps[pchfilename] or {}, ' ') or ''
				local order_deps = #cfg.order_deps and '|| ' .. table.concat(cfg.order_deps[pchfilename] or {}, ' ') or ''
				local extra_flags = #cfg.extra_flags and ' ' .. table.concat(cfg.extra_flags[pchfilename] or {}, ' ') or ''
				_p("build " .. pchfilename .. ".gch : cxx " .. file .. extra_deps .. order_deps)
				_p(1, "flags    = " .. flags['cxxflags'] .. extra_flags .. iif(prj.language == "C", "-x c-header", "-x c++-header"))
				_p(1, "includes = " .. flags.includes)
				_p(1, "defines  = " .. flags.defines)

				_p("build " .. pchfilename .. "_objc.gch : cxx " .. file .. extra_deps .. order_deps)
				_p(1, "flags    = " .. flags['objcflags'] .. extra_flags .. iif(prj.language == "C", "-x objective-c-header", "-x objective-c++-header"))
				_p(1, "includes = " .. flags.includes)
				_p(1, "defines  = " .. flags.defines)
			elseif path.issourcefile(file) then
				local objfilename = cpp.objectname(cfg, file)
				local extra_deps = #cfg.extra_deps and '| ' .. table.concat(cfg.extra_deps[objfilename] or {}, ' ') or ''
				local order_deps = #cfg.order_deps and '|| ' .. table.concat(cfg.order_deps[objfilename] or {}, ' ') or ''
				local extra_flags = #cfg.extra_flags and ' ' .. table.concat(cfg.extra_flags[objfilename] or {}, ' ') or ''
		
				local cflags = "cflags"
				if path.isobjcfile(file) then
					_p("build " .. objfilename .. ": cxx " .. file .. extra_deps .. order_deps)
					cflags = "objcflags"
				elseif path.isasmfile(file) then
					_p("build " .. objfilename .. ": cc " .. file .. extra_deps .. order_deps)
					cflags = "asmflags"
				elseif path.iscfile(file) and not cfg.options.ForceCPP then
					_p("build " .. objfilename .. ": cc " .. file .. extra_deps .. order_deps)
				else
					_p("build " .. objfilename .. ": cxx " .. file .. extra_deps .. order_deps)
					cflags = "cxxflags"
				end
	
				_p(1, "flags    = " .. flags[cflags] .. extra_flags)
				_p(1, "includes = " .. flags.includes)
				_p(1, "defines  = " .. flags.defines)
			elseif path.isresourcefile(file) then
				-- TODO
			end
		end

		_p("")
	end

	function cpp.linker(prj, cfg, objfiles, tool)
		local all_ldflags = ninja.list(table.join(tool.getlibdirflags(cfg), tool.getldflags(cfg), cfg.linkoptions))
		local lddeps      = ninja.list(premake.getlinks(cfg, "siblings", "fullpath"))
		local libs        = lddeps .. " " .. ninja.list(tool.getlinkflags(cfg))

		local prebuildsuffix = #cfg.prebuildcommands > 0 and "||__prebuildcommands" or ""

		local function writevars()
			_p(1, "all_ldflags     = " .. all_ldflags)
			_p(1, "libs            = " .. libs)
			_p(1, "all_outputfiles = " .. table.concat(objfiles, " "))
			if #cfg.prelinkcommands > 0 then
				_p(1, 'pre_link        = echo Running pre-link commands && ' .. table.implode(cfg.prelinkcommands, "", "", " && ") .. " && ")
			end
			if #cfg.postbuildcommands > 0 then
				_p(1, 'post_build      = && echo Running post-build commands && ' .. table.implode(cfg.postbuildcommands, "", "", " && "))
			end
		end

		if cfg.kind == "StaticLib" then
			local ar_flags = ninja.list(tool.getarchiveflags(cfg, cfg, false))
			_p("# link static lib")
			_p("build " .. cfg:getoutputfilename() .. ": ar " .. table.concat(objfiles, " ") .. " | " .. lddeps .. prebuildsuffix)
			_p(1, "flags = " .. ninja.list(tool.getarchiveflags(cfg, cfg, false)))
			_p(1, "all_outputfiles = " .. table.concat(objfiles, " "))
		elseif cfg.kind == "SharedLib" or cfg.kind == "Bundle" then
			local output = cfg:getoutputfilename()
			_p("# link shared lib")
			_p("build " .. output .. ": link " .. table.concat(objfiles, " ") .. " | " .. lddeps .. prebuildsuffix)
			writevars()
		elseif (cfg.kind == "ConsoleApp") or (cfg.kind == "WindowedApp") then
			_p("# link executable")
			_p("build " .. cfg:getoutputfilename() .. ": link " .. table.concat(objfiles, " ") .. " | " .. lddeps .. prebuildsuffix)
			writevars()
		else
			p.error("ninja action doesn't support this kind of target " .. cfg.kind)
		end

	end



