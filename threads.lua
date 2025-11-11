local ffi = require("ffi")
local buffer = require("string.buffer")
local threads = {}

require 'ffi.req' 'c.semaphore'

if ffi.os == "Windows" then
	ffi.cdef[[
typedef uint32_t (*thread_callback)(void*);

void* CreateThread(
	void* lpThreadAttributes,
	size_t dwStackSize,
	thread_callback lpStartAddress,
	void* lpParameter,
	uint32_t dwCreationFlags,
	uint32_t* lpThreadId
);
uint32_t WaitForSingleObject(void* hHandle, uint32_t dwMilliseconds);
int CloseHandle(void* hObject);
uint32_t GetLastError(void);
int32_t GetExitCodeThread(void* hThread, uint32_t* lpExitCode);

typedef struct _SYSTEM_INFO {
	union {
		uint32_t dwOemId;
		struct {
			uint16_t wProcessorArchitecture;
			uint16_t wReserved;
		};
	};
	uint32_t dwPageSize;
	void* lpMinimumApplicationAddress;
	void* lpMaximumApplicationAddress;
	size_t dwActiveProcessorMask;
	uint32_t dwNumberOfProcessors;
	uint32_t dwProcessorType;
	uint32_t dwAllocationGranularity;
	uint16_t wProcessorLevel;
	uint16_t wProcessorRevision;
} SYSTEM_INFO;

void GetSystemInfo(SYSTEM_INFO* lpSystemInfo);

void Sleep(uint32_t dwMilliseconds);
    ]]
	local kernel32 = ffi.load("kernel32")

	local function check_win_error(success)
		if success ~= 0 then return end

		local error_code = kernel32.GetLastError()
		local error_messages = {
			[5] = "Access denied",
			[6] = "Invalid handle",
			[8] = "Not enough memory",
			[87] = "Invalid parameter",
			[1455] = "Page file quota exceeded",
		}
		local err_msg = error_messages[error_code] or "unknown error"
		error(string.format("Thread operation failed: %s (Error code: %d)", err_msg, error_code), 2)
	end

	-- Constants
	local INFINITE = 0xFFFFFFFF
	local THREAD_ALL_ACCESS = 0x1F03FF

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("uint32_t[1]")
		local thread_handle = kernel32.CreateThread(
			nil, -- Security attributes (default)
			0, -- Stack size (default)
			ffi.cast("thread_callback", func_ptr),
			udata, -- Thread parameter
			0, -- Creation flags (run immediately)
			thread_id -- Thread identifier
		)

		if thread_handle == nil then check_win_error(0) end

		-- Return both handle and ID for Windows
		return {handle = thread_handle, id = thread_id[0]}
	end

	function threads.join_thread(thread_data)
		local wait_result = kernel32.WaitForSingleObject(thread_data.handle, INFINITE)

		if wait_result == INFINITE then check_win_error(0) end

		local exit_code = ffi.new("uint32_t[1]")

		if kernel32.GetExitCodeThread(thread_data.handle, exit_code) == 0 then
			check_win_error(0)
		end

		if kernel32.CloseHandle(thread_data.handle) == 0 then check_win_error(0) end

		return exit_code[0]
	end

	function threads.get_thread_count()
		local sysinfo = ffi.new("SYSTEM_INFO")
		kernel32.GetSystemInfo(sysinfo)
		return tonumber(sysinfo.dwNumberOfProcessors)
	end

	function threads.sleep(ms)
		ffi.C.Sleep(ms)
	end
else
	ffi.cdef[[
typedef uint64_t pthread_t;

typedef struct {
	uint32_t flags;
	void * stack_base;
	size_t stack_size;
	size_t guard_size;
	int32_t sched_policy;
	int32_t sched_priority;
} pthread_attr_t;

int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start_routine)(void *), void *arg);
int pthread_join(pthread_t thread, void **value_ptr);

long sysconf(int name);

int usleep(unsigned int usecs);
	]]
	--local pt = ffi.load("pthread")
	local pt = ffi.load("libpthread.so.0")

	-- Enhanced pthread error checking
	local function check_pthread(int)
		if int == 0 then return end

		local error_messages = {
			[11] = "System lacks resources or reached thread limit",
			[22] = "Invalid thread attributes specified",
			[1] = "Insufficient permissions to set scheduling parameters",
			[3] = "Thread not found",
			[35] = "Deadlock condition detected",
			[12] = "Insufficient memory to create thread",
		}
		local err_msg = error_messages[int] or "unknown error"

		if err_msg then
			error(string.format("Thread operation failed: %s (Error code: %d)", err_msg, int), 2)
		end
	end

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("pthread_t[1]", 1)
		check_pthread(pt.pthread_create(thread_id, nil, func_ptr, udata))
		return thread_id[0]
	end

	function threads.join_thread(id)
		local out = ffi.new("void*[1]")
		check_pthread(pt.pthread_join(id, out))
		return out[0]
	end

	local FLAG_SC_NPROCESSORS_ONLN = 83

	if ffi.os == "OSX" then FLAG_SC_NPROCESSORS_ONLN = 58 end

	function threads.get_thread_count()
		return tonumber(ffi.C.sysconf(FLAG_SC_NPROCESSORS_ONLN))
	end

	function threads.sleep(ms)
		ffi.C.usleep(ms * 1000)
	end
end

function threads.pointer_encode(obj)
	local buf = buffer.new()
	buf:encode(obj)
	local ptr, len = buf:ref()
	return buf, ptr, len
end

function threads.pointer_decode(ptr, len)
	local buf = buffer.new()
	buf:set(ptr, len)
	return buf:decode()
end

threads.STATUS_UNDEFINED = 0
threads.STATUS_COMPLETED = 1
threads.STATUS_ERROR = 2

local thread_func_signature = ffi.typeof"void *(*)(void *)"
local thread_data_t = ffi.typeof([[
struct {
	char *input_buffer;
	uint32_t input_buffer_len;
	char *output_buffer;
	uint32_t output_buffer_len;
	void *shared_pointer;
	uint8_t status;
}
]])
threads.thread_data_ptr_t = ffi.typeof("$*", thread_data_t)

do
	local Lua = require 'lua'

	local meta = {}
	meta.__index = meta

	-- Automatic cleanup when thread object is garbage collected
	function meta:__gc()
		self:close()
	end

	function meta:close()
		if self.lua then
			self.lua:close()
			self.lua = nil
		end
	end

	function threads.new(func)
		local self = setmetatable({}, meta)
		self.lua = Lua()
		local func_ptr = self.lua([[
local run = ...
local ffi = require("ffi")
local threads = require("pureffi.threads")

local function main(udata)
	local data = ffi.cast(threads.thread_data_ptr_t, udata)

	if data.shared_pointer ~= nil then
		local result = run(data.shared_pointer)

		data.status = threads.STATUS_COMPLETED

		-- Return nothing (results written to shared memory)
		return nil
	end

	local input = threads.pointer_decode(data.input_buffer, tonumber(data.input_buffer_len))
	local buf, ptr, len = threads.pointer_encode(run(input))

	data.output_buffer = ptr
	data.output_buffer_len = len

	data.status = threads.STATUS_COMPLETED

	return nil
end

_G.main_ref = main

local func_closure = ffi.cast("void *(*)(void *)", main)
return func_closure
]],
			func
		)
		self.func_ptr = ffi.cast(thread_func_signature, func_ptr)
		return self
	end

	function meta:run(obj, shared_ptr)
		if shared_ptr then
			self.buffer = nil
			self.shared_ptr_ref = obj
			self.input_data = thread_data_t({shared_pointer = ffi.cast("void *", obj)})
			self.shared_mode = true
		else
			local buf, ptr, len = threads.pointer_encode(obj)
			self.buffer = buf
			self.input_data = thread_data_t({input_buffer = ptr, input_buffer_len = len})
			self.shared_mode = false
		end

		self.id = threads.run_thread(self.func_ptr, self.input_data)
	end

	function meta:is_done()
		return self.input_data and self.input_data.status == threads.STATUS_COMPLETED
	end

	function meta:join()
		threads.join_thread(self.id)

		if self.shared_mode then
			-- Shared memory mode: no result to deserialize
			self.buffer = nil
			self.input_data = nil
			self.shared_ptr_ref = nil
			return nil
		else
			local result = threads.pointer_decode(self.input_data.output_buffer, self.input_data.output_buffer_len)
			local status = self.input_data.status
			self.buffer = nil
			self.input_data = nil

			if status == threads.STATUS_ERROR then
				return result[1], result[2]
			end

			return result
		end
	end
end

-- Thread pool implementation using shared memory
do
	local pool_meta = {}
	pool_meta.__index = pool_meta
	-- Define shared memory structure for thread pool communication
	-- Each thread has: work_available, work_done, should_exit flags
	local thread_control_t = ffi.typeof[[struct {
// using work_done
//	volatile int work_available;
//	volatile int work_done;
// using semaphores
	sem_t semWorkReady;
	sem_t semWorkDone;

	volatile int should_exit;
	const char* worker_func;  // Serialized worker function
	size_t worker_func_len;  // Length of serialized worker function
	const char* work_data;  // Serialized work data
	size_t work_data_len;  // Length of work data
	char* result_data;  // Serialized result data
	size_t result_data_len;  // Length of result data
	int thread_id;
	int padding;  // Alignment
}]]
	threads.thread_control_t = thread_control_t
	threads.thread_control_ptr_t = ffi.typeof("$*", thread_control_t)
	local thread_control_array_t = ffi.typeof("$[?]", thread_control_t)

	-- Create a new thread pool
	function threads.new_pool(worker_func, num_threads, workData)
		local self = setmetatable({}, pool_meta)
		self.num_threads = num_threads or 8
		self.worker_func = worker_func
		self.thread_objects = {}
		-- Allocate shared control structures (one per thread)
		self.control = thread_control_array_t(num_threads)
		local worker_func_str = string.dump(worker_func)

		-- Keep buffers alive so pointers remain valid
		self.work_buffers = {}
		self.result_buffers = {}

		-- Initialize control structures
		for i = 0, num_threads - 1 do
			local ctrl = self.control + i
			ctrl.thread_id = i + 1 -- 1-based for Lua
			--[[ using work_done
			ctrl.work_available = 0
			ctrl.work_done = 1
			--]]
			-- [[ using semaphores
			ffi.C.sem_init(ctrl.semWorkReady, 0, 0)
			ffi.C.sem_init(ctrl.semWorkDone, 0, 0)
			--]]
			ctrl.should_exit = 0
			ctrl.worker_func = worker_func_str
			ctrl.worker_func_len = #worker_func_str
			local ctrlWorkData = workData and workData[i+1]
			if not ctrlWorkData then
				ctrl.work_data = nil
				ctrl.work_data_len = 0
			else
				self:setwork(i+1, ctrlWorkData)
			end
			ctrl.result_data = nil
			ctrl.result_data_len = 0
		end

		-- Create persistent worker that loops waiting for work
		local persistent_worker = function(shared_ptr)
			local ffi = require("ffi")
			local threads = require("pureffi.threads")
			local buffer = require("string.buffer")
			local ctrl = ffi.cast(threads.thread_control_ptr_t, shared_ptr)
			local thread_id = ctrl.thread_id
			-- Get the actual worker function from the serialized input
			local worker_func = assert(load(ffi.string(ctrl.worker_func, ctrl.worker_func_len)))

			-- [[ this was every iteration.  now I'm just doing it once up front.
			local work = threads.pointer_decode(ctrl.work_data, ctrl.work_data_len)
			--]]

			-- Thread loop: wait for work, process it, repeat
			while true do
				--[[ using work_done
				-- Check if we should exit
				if ctrl.should_exit == 1 then break end
				-- Check if work is available
				if ctrl.work_available == 1 then
				--]]
				-- [[ using semaphores
				-- one possible TODO is replace semWorkReady with a mutex wrapping a job queue ptr
				ffi.C.sem_wait(ctrl.semWorkReady)
				-- Check if we should exit
				if ctrl.should_exit == 1 then break end
				do
				--]]
					--[[ me just doing away with work thread update results altogether
					-- Deserialize work data
					local work = threads.pointer_decode(ctrl.work_data, ctrl.work_data_len)
					-- Process it with the worker function
					local result = worker_func(work)
					local buf, result_ptr, result_len = threads.pointer_encode(result)
					-- Store result pointer in ctrl structure
					ctrl.result_data = result_ptr
					ctrl.result_data_len = result_len
					--]]
					-- [[ ... instead
					worker_func(work)
					--]]

					--[[ using work_done
					-- Mark as done
					ctrl.work_available = 0
					ctrl.work_done = 1
					--]]
				end

				-- [[ using semaphores
				ffi.C.sem_post(ctrl.semWorkDone)
				--[[ using work_done
				-- Small sleep to avoid busy-waiting
				threads.sleep(0)
				--]]
			end

			return thread_id
		end

		-- Create and start persistent threads
		local ctrl = self.control + 0
		for i = 1, num_threads do
			local thread = threads.new(persistent_worker)
			-- Pass the control structure pointer as shared memory
			-- and the worker function as serialized data
			thread:run(ctrl, true)
			self.thread_objects[i] = thread
			ctrl = ctrl + 1
		end

		return self
	end

	-- set work info for a specific thread (without submitting)
	function pool_meta:setwork(thread_id, work)
		local idx = thread_id - 1
		local ctrl = self.control + idx

		--[[ using work_done
		assert(ctrl.work_done == 1, "Thread " .. thread_id .. " is still busy")
		--]]
		local buf, work_ptr, work_len = threads.pointer_encode(work)
		self.work_buffers[thread_id] = buf -- Keep buffer alive
		-- Set work data in shared control structure
		ctrl.work_data = work_ptr
		ctrl.work_data_len = work_len
	end

	-- sets a specific thread's work-ready status to true
	function pool_meta:ready(thread_id)
		local idx = thread_id - 1
		local ctrl = self.control + idx

		--[[ using work_done
		ctrl.work_done = 0
		ctrl.work_available = 1
		--]]
		-- [[ using semaphores
		ffi.C.sem_post(ctrl.semWorkReady)
		--]]
	end

	-- Submit work to a specific thread
	function pool_meta:submit(thread_id, work)
		self:setwork(thread_id, work)
		self:ready(thread_id)
	end

	-- Wait for a specific thread to complete
	function pool_meta:wait(thread_id)
		local idx = thread_id - 1
		local ctrl = self.control + idx

		--[[ using work_done
		while ctrl.work_done == 0 do
			threads.sleep(0)
		end
		--]]
		-- [[ using semaphores
		ffi.C.sem_wait(ctrl.semWorkDone)
		--]]

		return threads.pointer_decode(ctrl.result_data, ctrl.result_data_len)
	end

	-- Submit work to all threads
	function pool_meta:submit_all(work_items)
		if #work_items ~= self.num_threads then
			error("Must provide work for all " .. self.num_threads .. " threads")
		end

		for i = 1, self.num_threads do
			self:submit(i, work_items[i])
		end
	end

	-- Wait for all threads to complete
	function pool_meta:wait_all()
		local results = {}

		for i = 1, self.num_threads do
			results[i] = self:wait(i)
		end

		return results
	end

	function pool_meta:iterate()
		for i=0,self.num_threads - 1 do
			ffi.C.sem_post(self.control[i].semWorkReady)
		end
		for i=0,self.num_threads - 1 do
			ffi.C.sem_wait(self.control[i].semWorkDone)
		end
	end

	-- Shutdown the thread pool
	function pool_meta:shutdown()
		-- Signal all threads to exit
		local ctrl = self.control + 0
		for i = 0,self.num_threads - 1 do
			ctrl.should_exit = 1
			-- [[ using semaphores
			-- wake it up from looking for work to have it quit
			ffi.C.sem_post(ctrl.semWorkReady)
			--]]
			ctrl = ctrl + 1
		end

		-- Wait for threads to exit and clean up
		ctrl = self.control + 0
		for i = 1,self.num_threads do
			self.thread_objects[i]:join()
			-- [[ using semaphores
			ffi.C.sem_destroy(ctrl.semWorkReady)
			ffi.C.sem_destroy(ctrl.semWorkDone)
			--]]
			self.thread_objects[i]:close()
			ctrl = ctrl + 1
		end

		self.thread_objects = {}
	end

	-- Cleanup on garbage collection
	function pool_meta:__gc()
		if self.thread_objects and #self.thread_objects > 0 then self:shutdown() end
	end
end

return threads
