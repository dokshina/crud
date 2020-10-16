local checks = require('checks')
local errors = require('errors')
local vshard = require('vshard')

local call = require('crud.common.call')
local registry = require('crud.common.registry')
local utils = require('crud.common.utils')
local sharding = require('crud.common.sharding')
local dev_checks = require('crud.common.dev_checks')

local GetError = errors.new_class('Get',  {capture_stack = false})

local get = {}

local GET_FUNC_NAME = '__get'

local function call_get_on_storage(space_name, key)
    dev_checks('string', '?')

    local space = box.space[space_name]
    if space == nil then
        return nil, GetError:new("Space %q doesn't exist", space_name)
    end

    local tuple = space:get(key)
    return tuple
end

function get.init()
    registry.add({
        [GET_FUNC_NAME] = call_get_on_storage,
    })
end

--- Get tuple from the specified space by key
--
-- @function call
--
-- @param string space_name
--  A space name
--
-- @param key
--  Primary key value
--
-- @tparam ?number opts.timeout
--  Function call timeout
--
-- @return[1] object
-- @treturn[2] nil
-- @treturn[2] table Error description
--
function get.call(space_name, key, opts)
    checks('string', '?', {
        timeout = '?number',
        bucket_id = '?number',
    })

    opts = opts or {}

    local space = utils.get_space(space_name, vshard.router.routeall())
    if space == nil then
        return nil, GetError:new("Space %q doesn't exist", space_name)
    end

    if box.tuple.is(key) then
        key = key:totable()
    end

    local bucket_id = opts.bucket_id or sharding.get_bucket_id_by_key(key, space)
    local replicaset, err = vshard.router.route(bucket_id)
    if replicaset == nil then
        return nil, GetError:new("Failed to get replicaset for bucket_id %s: %s", bucket_id, err.err)
    end

    local results, err = call.rw(GET_FUNC_NAME, {space_name, key}, {
        replicasets = {replicaset},
        timeout = opts.timeout,
    })

    if err ~= nil then
        return nil, GetError:new("Failed to get: %s", err)
    end

    local tuple = results[replicaset.uuid]
    return {
        metadata = table.copy(space:format()),
        rows = {tuple},
    }
end

return get
