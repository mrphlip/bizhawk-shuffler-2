local plugin = {}

plugin.name = "Solo Z3R Multiworld"
plugin.author = "authorblues"

plugin.settings =
{
	{ name='swapbutton', type='boolean', label='Force Game Swap on P2 L Button?' },
}

plugin.description =
[[
	Intended to work with seeds generated by Aerinon's Z3 DoorRandomizer fork, and has been confirmed to work with some other forks of this project (such as codemann8's overworld shuffle).

	https://github.com/aerinon/ALttPDoorRandomizer

	Create a multiworld randomizer seed and generate roms for all players. Put them all in the games/ folder, and the plugin will shuffle like normal, sending items between seeds when necessary.

	Special thanks to Aerinon for providing significant help to get this working. Thanks also to Ankou for helping me sort out weird SNES+Bizhawk issues, and CodeGorilla for extensive testing.

	TIP: Generate seeds with unique sprites and name the players according to the sprites, so that send/recv messages will be meaningful and easily understood.
]]

local this_player_id = -1
local this_seed = -1

local ROM_NAME_ADDR = 0x7FC0 -- 15 bytes
local ROM_NAME_PATTERN = { 0x45, 0x52, nil, nil, nil, 0x5F, nil, 0x5F, nil, 0x5F }

local OUTGOING_ITEM_ADDR = 0x02D8
local OUTGOING_PLAYER_ADDR = 0xC098
local INCOMING_ITEM_ADDR = 0xF4D2
local INCOMING_PLAYER_ADDR = 0xF4D3
local RECV_COUNT_ADDR = 0xF4F0 -- 2 bytes

local SRAM_DATA_START = 0xF000
local SRAM_DATA_SIZE = 0x3E4

local CLEAR_DELAY_FRAMES = 1

local prev_sram_data = nil

local function get_game_mode()
	return mainmemory.read_u8(0x0010)
end

local function is_normal_gameplay()
	local g = get_game_mode()
	return g == 0x07 or g == 0x09 or g == 0x0B
end

-- takes an address and a delimiter as parameters
-- returns integer equivalent of BCD value and address following delimiter
local function read_BCD_to_delimiter(addr, stop)
	local result = 0
	for i = 1,20 do
		local value = memory.read_u8(addr, "CARTROM")
		if value == stop then break end
		result = (result * 10) + (value - 0x30)
		addr = addr + 1
	end

	return result, addr+1
end

local function get_sram_data()
	return mainmemory.readbyterange(SRAM_DATA_START, SRAM_DATA_SIZE)
end

-- returns sram changes as a consistent, serialized string
local function get_changes(old, new)
	local changes = {}
	for addr,oldvalue in pairs(old) do
		local diff = bit.bxor(oldvalue, new[addr])
		if diff ~= 0 then
			local cstr = string.format('%04x,%02x', addr, diff)
			table.insert(changes, cstr)
		end
	end
	table.sort(changes)
	return table.concat(changes, ';')
end

-- this assumes no values are anything other than primitive and
-- are guaranteed to have the same keys (this is not a general purpose function)
local function table_equal(t1, t2)
	for k,v1 in pairs(t1) do
		local v2 = t2[k]
		-- if there isn't a matching value or types differ
		if v2 == nil or type(v1) ~= type(v2) then
			return false
		end
		-- if the primitive values don't match
		if v1 ~= v2 then return false end
	end
	return true
end

local function add_item_if_unique(list, item)
	for _,v in ipairs(list) do
		if table_equal(v, item) then
			return false
		end
	end

	table.insert(list, item)
	return true
end

function plugin.on_setup(data, settings)
	data.meta = data.meta or {}
end

function plugin.on_game_load(data, settings)
	-- a handful of checks to make sure this is a SNES game first
	local has_cartrom = false
	for i,domain in ipairs(memory.getmemorydomainlist()) do
		if domain == "CARTROM" then has_cartrom = true end
	end

	-- if the cartrom isn't present, or it is too small, bail
	if not has_cartrom then return end
	if memory.getmemorydomainsize("CARTROM") < 0x200000 then return end

	-- if the rom name does not seem to be from a valid Z3R rom, ignore it
	for i,val in ipairs(ROM_NAME_PATTERN) do
		local mem = memory.read_u8(ROM_NAME_ADDR + i - 1, "CARTROM")
		if val ~= nil and mem ~= val then return end
	end

	--this_player_id = tonumber(get_current_game():match("_P(%d+)_"))
	local protocol, team_id = 0, 0
	local addr = ROM_NAME_ADDR + 2

	protocol, addr = read_BCD_to_delimiter(addr, 0x5F)
	team_id, addr = read_BCD_to_delimiter(addr, 0x5F)
	this_player_id, addr = read_BCD_to_delimiter(addr, 0x5F)
	this_seed = read_BCD_to_delimiter(addr, 0x00)

	prev_sram_data = get_sram_data()
	data.meta[this_seed] = data.meta[this_seed] or {itemqueues={}, queuedsend={}, cleardelay={}}

	local meta = data.meta[this_seed]
	meta.itemqueues[this_player_id] = meta.itemqueues[this_player_id] or {}
	meta.queuedsend[this_player_id] = meta.queuedsend[this_player_id] or {}
	meta.cleardelay[this_player_id] = meta.cleardelay[this_player_id] or 0

	-- this should forcibly debounce the L press
	data.prevL = true
end

function plugin.on_frame(data, settings)
	-- no player id means that the rom isn't Z3R
	if this_player_id == -1 then return end

	local meta = data.meta[this_seed]
	local player_id, item_id
	local sram_data = get_sram_data()

	if is_normal_gameplay() then
		player_id = mainmemory.read_u8(OUTGOING_PLAYER_ADDR)
		item_id = mainmemory.read_u8(OUTGOING_ITEM_ADDR)

		local prev_player = data.prev_player or 0
		data.prev_player = player_id

		if player_id ~= 0 and prev_player == 0 then
			table.insert(meta.queuedsend[this_player_id],
				{item=item_id, src=this_player_id, target=player_id})
			meta.cleardelay[this_player_id] = CLEAR_DELAY_FRAMES
			data.prev_player = 0
			mainmemory.write_s8(OUTGOING_PLAYER_ADDR, 0)
		end

		local queue_len = #meta.itemqueues[this_player_id]
		local recv_count = mainmemory.read_u16_le(RECV_COUNT_ADDR)
		if recv_count > queue_len then
			mainmemory.write_u16_le(RECV_COUNT_ADDR, 0)
			recv_count = 0
		end

		if recv_count < queue_len and mainmemory.read_u8(INCOMING_ITEM_ADDR) == 0 then
			local obj = meta.itemqueues[this_player_id][recv_count+1]
			mainmemory.write_u8(INCOMING_ITEM_ADDR, obj.item)
			mainmemory.write_u8(INCOMING_PLAYER_ADDR, obj.src)
			mainmemory.write_u16_le(RECV_COUNT_ADDR, recv_count+1)
		end
	elseif get_game_mode() == 0x00 then
		-- if we somehow got to the title screen (reset?) with items queued to
		-- be sent, but we never saw the sram changes, the player was very
		-- naughty and tried to create a race condition. very naughty! bad player!
		meta.queuedsend[this_player_id] = {}
	end

	-- clear the outgoing items addresses no matter the gamemode
	if (meta.cleardelay[this_player_id] or 0) > 0 then
		if meta.cleardelay[this_player_id] == 0 then
			mainmemory.write_u8(OUTGOING_PLAYER_ADDR, 0)
			mainmemory.write_u8(OUTGOING_ITEM_ADDR, 0)
		else
			meta.cleardelay[this_player_id] = meta.cleardelay[this_player_id] - 1
		end
	end

	-- when SRAM changes arrive and there are items queued to be sent, match them up
	if #meta.queuedsend[this_player_id] > 0 then
		-- calculate the changes only when there are items queued
		-- this operation is expensive!
		local changes = get_changes(prev_sram_data, sram_data)
		if #changes > 0 then
			local item = table.remove(meta.queuedsend[this_player_id], 1)
			item.meta = changes -- add the sram changes to the object to identify repeats
			meta.itemqueues[item.target] = meta.itemqueues[item.target] or {}
			add_item_if_unique(meta.itemqueues[item.target], item)
		end
	end

	prev_sram_data = sram_data

	if settings.swapbutton then
		local currL = joypad.get(2).L
		if not data.prevL and currL then swap_game() end
		data.prevL = currL
	end
end

return plugin
