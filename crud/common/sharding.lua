local vshard = require('vshard')

local utils = require('crud.common.utils')

local sharding = {}

function sharding.get_bucket_id_by_key(key, _)
    return vshard.router.bucket_id_strcrc32(key)
end

function sharding.get_bucket_id_by_tuple(tuple, space)
    local key = utils.extract_key(tuple, space.index[0].parts)
    return sharding.get_bucket_id_by_key(key)
end

return sharding
