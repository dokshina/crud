local buffer = require('buffer')
local msgpack = require('msgpack')
local key_def_lib = require('key_def')
local merger = require('merger')

local SELECT_FUNC_NAME = '__select'
local CALL_FUNC_NAME = '__call'

local key_def_cache = {}
setmetatable(key_def_cache, {__mode = 'k'})

local function get_key_def(replicasets, space_name, index_name)
    -- Get requested and primary index metainfo.
    local conn = select(2, next(replicasets)).master.conn
    local primary_index = conn.space[space_name].index[0]
    local index = conn.space[space_name].index[index_name]

    if key_def_cache[index] ~= nil then
        return key_def_cache[index]
    end

    -- Create a key def.
    local key_def = key_def_lib.new(index.parts)
    if not index.unique then
        key_def = key_def:merge(key_def_lib.new(primary_index.parts))
    end

    key_def_cache[index] = key_def

    return key_def
end

local function decode_metainfo(buf)
    -- Skip an array around a call return values.
    local len
    len, buf.rpos = msgpack.decode_array_header(buf.rpos, buf:size())
    assert(len == 2)

    -- Decode a first return value (metainfo).
    local res
    res, buf.rpos = msgpack.decode(buf.rpos, buf:size())
    return res
end

--- Wait for a data chunk and request for the next data chunk.
local function fetch_chunk(context, state)
    local net_box_opts = context.net_box_opts
    local buf = context.buffer
    local call_args = context.call_args
    local replicaset = context.replicaset
    local future = state.future

    -- The source was entirely drained.
    if future == nil then
        return nil
    end

    -- Wait for requested data.
    local res, err = future:wait_result()
    if res == nil then
        error(err)
    end

    -- Decode metainfo, leave data to be processed by the merger.
    local cursor = decode_metainfo(buf)

    -- Check whether we need the next call.
    if cursor.is_end then
        local next_state = {}
        return next_state, buf
    end

    -- Request the next data while we processing the current ones.
    -- Note: We reuse the same buffer for all request to a replicaset.
    local next_call_args = call_args

    -- change context.call_args too, but it does not matter
    next_call_args[4].after_tuple = cursor.after_tuple
    local next_future = replicaset:callro(CALL_FUNC_NAME,
            {{func_name = SELECT_FUNC_NAME, func_args = next_call_args}},
            net_box_opts)

    local next_state = {future = next_future}
    return next_state, buf
end

local reverse_iterators = {
    [box.index.LE] = true,
    [box.index.LT] = true,
    [box.index.REQ] = true,
}

local function new(replicasets, space_name, index_id, conditions, opts)
    opts = opts or {}
    local key_def = get_key_def(replicasets, space_name, index_id)
    local call_args = {space_name, index_id, conditions, opts}

    -- Request a first data chunk and create merger sources.
    local merger_sources = {}
    for _, replicaset in pairs(replicasets) do
        -- Perform a request.
        local buf = buffer.ibuf()
        local net_box_opts = {is_async = true, buffer = buf, skip_header = true}
        local future = replicaset:callro(CALL_FUNC_NAME,
                {{func_name = SELECT_FUNC_NAME, func_args = call_args}},
                net_box_opts)

        -- Create a source.
        local context = {
            net_box_opts = net_box_opts,
            buffer = buf,
            call_args = call_args,
            replicaset = replicaset,
        }
        local state = {future = future}
        local source = merger.new_buffer_source(fetch_chunk, context, state)
        table.insert(merger_sources, source)
    end

    local merger_inst = merger.new(key_def, merger_sources, {
        reverse = reverse_iterators[opts.iter],
    })
    return merger_inst
end

return {
    new = new,
}
