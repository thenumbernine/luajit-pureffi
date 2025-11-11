local ffi = require 'ffi'

local LUA_GLOBALSINDEX = -10002
ffi.cdef[[
typedef struct lua_State lua_State;
lua_State *luaL_newstate(void);
void luaL_openlibs(lua_State *L);
void lua_close(lua_State *L);
int luaL_loadstring(lua_State *L, const char *s);
int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
void lua_getfield(lua_State *L, int index, const char *k);
void lua_settop(lua_State *L, int index);
void lua_pop(lua_State *L, int n);
const char *lua_tolstring(lua_State *L, int index, size_t *len);
ptrdiff_t lua_tointeger(lua_State *L, int index);
int lua_gettop(lua_State *L);
void lua_pushstring(lua_State *L, const char *s);
const void *lua_topointer(lua_State *L, int index);
double lua_tonumber(lua_State *L, int index);
void *lua_touserdata(lua_State *L, int idx);
void lua_pushlstring(lua_State *L, const char *p, size_t len);
]]

local function create_state()
	local L = ffi.C.luaL_newstate()

	if L == nil then error("Failed to create new Lua state: Out of memory", 2) end

	ffi.C.luaL_openlibs(L)
	return L
end

local function close_state(L)
	ffi.C.lua_close(L)
end

local function check_error(L, ret)
	if ret == 0 then return end

	local chr = ffi.C.lua_tolstring(L, -1, nil)
	local msg = ffi.string(chr)
	error(msg, 2)
end

local function get_function_pointer(L, code, func)
	check_error(L, ffi.C.luaL_loadstring(L, code))
	local str = string.dump(func)
	ffi.C.lua_pushlstring(L, str, #str)
	check_error(L, ffi.C.lua_pcall(L, 1, 1, 0))
	local ptr = ffi.C.lua_topointer(L, -1)
	ffi.C.lua_settop(L, -2)
	local box = ffi.cast("uintptr_t*", ptr)
	return box[0]
end

local mt = {}
mt.__index = mt
mt.__gc = function(self)
	-- any harm in calling this twice? nope?
	lua.close_state(L)
end
mt.close = close_state
mt.check_error = check_error
mt.get_function_pointer = get_function_pointer
ffi.metatype('lua_State', mt)

return {
	create_state = create_state,
	close_state = close_state,
	check_error = check_error,
	get_function_pointer = get_function_pointer,
}
