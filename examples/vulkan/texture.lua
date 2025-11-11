local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local shaderc = require("shaderc")
local wnd = cocoa.window()
local Color = require("helpers.structs.color")
local png = require("helpers.png")
local Buffer = require("helpers.buffer")
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetMetalLayer()),
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
local window_target = renderer:CreateWindowRenderTarget()
local file = io.open("examples/vulkan/capsadmin.png", "rb")
local file_data = file:read("*a")
file:close()
local file_buffer = Buffer.New(file_data, #file_data)
local img = png.decode(file_buffer)
local texture_image = renderer.device:CreateImage(
	img.width,
	img.height,
	"R8G8B8A8_UNORM",
	{"sampled", "transfer_dst", "transfer_src"},
	"device_local"
)
renderer:UploadToImage(
	texture_image,
	img.buffer:GetBuffer(),
	texture_image:GetWidth(),
	texture_image:GetHeight()
)
local texture_view = texture_image:CreateView()
local PushConstants = ffi.typeof([[
	struct {
		struct {
			float r;
			float g;
			float b;
		} color;
		float alpha;
	}
]])
local texture_sampler = renderer.device:CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)
local vertex_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = {
			-- top-left (red) + UV (0, 0)
			-0.5, -- x
			-0.5, -- y
			1.0, -- r
			1.0, -- g
			1.0, -- b
			0.0, -- u
			0.0, -- v
			-- top-right (green) + UV (1, 0)
			0.5,
			-0.5,
			1.0,
			1.0,
			1.0,
			1.0,
			0.0,
			-- bottom-right (blue) + UV (1, 1)
			0.5,
			0.5,
			1.0,
			1.0,
			1.0,
			1.0,
			1.0,
			-- bottom-left (yellow) + UV (0, 1)
			-0.5,
			0.5,
			1.0,
			1.0,
			1.0,
			0.0,
			1.0,
		},
	}
)
local index_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = {
			0,
			1,
			2, -- first triangle (top-left, top-right, bottom-right)
			2,
			3,
			0, -- second triangle (bottom-right, bottom-left, top-left)
		},
	}
)
-- Create pipeline once at startup with dynamic viewport/scissor
local graphics_pipeline = renderer:CreatePipeline(
	{
		render_pass = window_target:GetRenderPass(),
		dynamic_states = {"viewport", "scissor"},
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450

					layout(location = 0) in vec2 in_position;
					layout(location = 1) in vec3 in_color;
					layout(location = 2) in vec2 in_uv;

					layout(location = 0) out vec3 out_color;
					layout(location = 1) out vec2 out_uv;

					void main() {
						gl_Position = vec4(in_position, 0.0, 1.0);
						out_color = in_color;
						out_uv = in_uv;
					}
				]],
				bindings = {
					{
						binding = 0,
						stride = ffi.sizeof("float") * 7, -- vec2 + vec3 + vec2
						input_rate = "vertex",
					},
				},
				attributes = {
					{
						binding = 0,
						location = 0, -- in_position
						format = "R32G32_SFLOAT", -- vec2
						offset = 0,
					},
					{
						binding = 0,
						location = 1, -- in_color
						format = "R32G32B32_SFLOAT", -- vec3
						offset = ffi.sizeof("float") * 2,
					},
					{
						binding = 0,
						location = 2, -- in_uv
						format = "R32G32_SFLOAT", -- vec2
						offset = ffi.sizeof("float") * 5,
					},
				},
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450

					layout(binding = 0) uniform ColorUniform1 {
						vec3 color_multiplier;
					} ubo1;

					layout(push_constant) uniform PushConstants {
						vec3 color_multiplier;
						float alpha;
					} pc;

					layout(binding = 1) uniform sampler2D tex_sampler;

					// from vertex shader
					layout(location = 0) in vec3 frag_color;
					layout(location = 1) in vec2 frag_uv;

					// output color
					layout(location = 0) out vec4 out_color;

					void main() {
						vec4 tex_color = texture(tex_sampler, frag_uv);
						out_color.rgb = tex_color.rgb * frag_color * pc.color_multiplier * ubo1.color_multiplier;
						out_color.a = pc.alpha * tex_color.a;
					}
				]],
				descriptor_sets = {
					{
						type = "uniform_buffer",
						binding_index = 0,
						args = {
							renderer:CreateBuffer(
								{
									byte_size = 16, -- vec3 in std140 layout has 16-byte alignment
									buffer_usage = "uniform_buffer",
									data = Color(1.0, 1.0, 1.0),
								}
							),
						},
					},
					{
						type = "combined_image_sampler",
						binding_index = 1,
						args = {texture_view, texture_sampler},
					},
				},
				push_constants = {
					size = ffi.sizeof(PushConstants),
					offset = 0,
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "back",
			front_face = "clockwise",
			depth_bias = 0,
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {
				{
					blend = true,
					src_color_blend_factor = "src_alpha",
					dst_color_blend_factor = "one_minus_src_alpha",
					color_blend_op = "add",
					src_alpha_blend_factor = "one",
					dst_alpha_blend_factor = "zero",
					alpha_blend_op = "add",
					color_write_mask = {"r", "g", "b", "a"},
				},
			},
		},
		multisampling = {
			sample_shading = false,
			rasterization_samples = "1",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
)
wnd:Initialize()
wnd:OpenWindow()
local frame_count = 0

while true do
	local events = wnd:ReadEvents()

	for _, event in ipairs(events) do
		if event.type == "window_close" then
			renderer:WaitForIdle()
			os.exit()
		end

		if event.type == "window_resize" then window_target:RecreateSwapchain() end
	end

	if window_target:BeginFrame() then
		local cmd = window_target:GetCommandBuffer()
		cmd:BeginRenderPass(
			window_target:GetRenderPass(),
			window_target:GetFramebuffer(),
			window_target:GetExtent(),
			ffi.new("float[4]", 0.2, 0.2, 0.2, 1.0)
		)
		graphics_pipeline:Bind(cmd)
		local extent = window_target:GetExtent()
		local pc_data = PushConstants()
		pc_data.color = Color.FromHSV((os.clock() % 10) / 10, 1.0, 1.0):Cast(pc_data.color)
		pc_data.alpha = 1 --math.abs(math.sin(os.clock() * 0.5))
		graphics_pipeline:PushConstants(cmd, "fragment", 0, pc_data)
		cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
		cmd:SetScissor(0, 0, extent.width, extent.height)
		cmd:BindVertexBuffer(vertex_buffer, 0)
		cmd:BindIndexBuffer(index_buffer, 0)
		cmd:DrawIndexed(6, 1, 0, 0, 0)
		cmd:EndRenderPass()
		window_target:EndFrame()
	end

	threads.sleep(1)
	frame_count = frame_count + 1
end
