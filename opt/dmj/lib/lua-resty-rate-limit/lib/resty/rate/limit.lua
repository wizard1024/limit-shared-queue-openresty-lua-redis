_M = { _VERSION = "1.1" }

local reset = 0

local function expire_key(redis_connection, key, interval, log_level)
    local expire, error = redis_connection:expire(key, interval)
    if not expire then
        ngx.log(log_level, "failed to get ttl: ", error)
        return
    end
end

local function ttl_key(redis_connection, key, interval, log_level)
	local ttl, error = redis_connection:pttl(key)
        if not ttl then
        	ngx.log(log_level, "failed to get ttl: ", error)
            	return
        end
        if ttl == -1 then
            	expire_key(redis_connection, key, interval, log_level)
        end
	if ttl == -2 then
		redis_connection:incr(key)
		expire_key(redis_connection, key, interval, log_level)
	end
		
end

-- Function to increse class queue and set TTL to key
local function bump_request_all(redis_connection, redis_pool_size, ip_key, rate, interval, rateTotal, rateTotalDec, intervalTotal, enforce_limit, log_level)
    	local proceed=true
    	local key = "RL:" .. ip_key
	local keyTotal = "RL:Total"
	local dec = 0

	--local lock, error = redis_connection:set("RL:Lock", "Locked", "PX", "1000", "NX")
	--while lock == ngx.null do
	--	ngx.sleep(0.001)
	--	lock, error = redis_connection:set("RL:Lock", "Locked", "PX", "1000", "NX")
	--end

    	local count, error = redis_connection:incr(key)
    	if not count then
        	ngx.log(log_level, "failed to incr count: ", error)
        	return
    	end
	local total, error = redis_connection:incr(keyTotal)	
	if not total then
		ngx.log(log_level, "Failed to get key: ", error)
	end
	--redis_connection:del("RL:Lock")

	local itotal = tonumber(total)
	if itotal == 1 then 
		expire_key(redis_connection, keyTotal, interval, log_level)
	end

	local icount = tonumber(count)
    	if icount == 1 then
        	expire_key(redis_connection, key, interval, log_level)
    	else
    		if enforce_limit then
			if icount <= rate then
				if itotal > rateTotal then
					-- DECR
					dec, error = redis_connection:decr(keyTotal)
					if not dec then
						ngx.log(log_level, "Failed to decr key:", error)
					end
					dec, error = redis_connection:decr(key)
					if not dec then
						ngx.log(log_level, "Failed to decr key:", error)
					end
					proceed = false
				end
			else 
				if itotal > rateTotalDec then
					-- DECR
					dec, error = redis_connection:decr(keyTotal)
					if not dec then
						ngx.log(log_level, "Failed to decr key:", error)
					end
					dec, error = redis_connection:decr(key)
					if not dec then
						ngx.log(log_level, "Failed to decr key:", error)
					end
					proceed = false
				end
			end
		else
			if icount <= rate then
				if itotal > rateTotal then
					-- DECR
					dec, error = redis_connection:decr(keyTotal)
					if not dec then
						ngx.log(log_level, "Failed to decr key:", error)
					end
					dec, error = redis_connection:decr(key)
					if not dec then
						ngx.log(log_level, "Failed to decr key:", error)
					end
					proceed = false
				end
			else 
				-- DECR
				dec, error = redis_connection:decr(keyTotal)
				if not dec then
					ngx.log(log_level, "Failed to decr key:", error)
				end
				dec, error = redis_connection:decr(key)
				if not dec then
					ngx.log(log_level, "Failed to decr key:", error)
				end
				proceed = false
			end
		end
    	end

    	return { proceed = proceed }
end

function _M.limit(config)
    -- We always use limit
    local use_limit = true

    if use_limit then
        local log_level = config.log_level or ngx.ERR
	-- Init from nginx config.
        if not config.connection then
            local ok, redis = pcall(require, "resty.redis")
            if not ok then
                ngx.log(log_level, "failed to require redis")
                return
            end

            local redis_config = config.redis_config or {}
            redis_config.timeout = redis_config.timeout or 1
            redis_config.host = redis_config.host or "127.0.0.1"
            redis_config.port = redis_config.port or 6379
            redis_config.pool_size = redis_config.pool_size or 100

            local redis_connection = redis:new()
            redis_connection:set_timeout(redis_config.timeout * 1000)

            local ok, error = redis_connection:connect(redis_config.host, redis_config.port)
            if not ok then
                ngx.log(log_level, "failed to connect to redis: ", error)
                return
            end

            config.redis_config = redis_config
	    -- Save established connection to config for use
            config.connection = redis_connection
        end

        local connection = config.connection
        local redis_pool_size = config.redis_config.pool_size
        local key = config.key or ngx.var.remote_addr
	local rateTotal = config.rateTotal or 100;
	--local rateTotal = 0
	local intervalTotal = config.intervalTotal or 1;
	local r_i = config.r_i or {{"0", 10, 1, false}}
	local rateTotalDec = rateTotal
	local rate = 10
	local interval = 1
	local enforce_limit = false
	local count_limit = 0	
	-- Determine parameters from config
    	for i,r_i_keys in ipairs(r_i) do
    	    if r_i_keys[1] == key then
    	    	rate = r_i_keys[2]
    	    	interval = r_i_keys[3]
		enforce_limit = r_i_keys[4]
    	    end
	    count_limit = count_limit + 1
    	end
	rateTotalDec = rateTotalDec - (count_limit * 4)
	
        local response, error = bump_request_all(connection, redis_pool_size, key, rate, interval, rateTotal, rateTotalDec, intervalTotal, enforce_limit, log_level)
        if not response then
            return
        end

        if response.proceed then
		-- Return connection in pool
    		local ok, error = connection:set_keepalive(60000, redis_pool_size)
    		if not ok then
    		    ngx.log(log_level, "failed to set keepalive: ", error)
    		end
	else	
		ngx.status = 429
		ngx.say('{"status_code":25,"status_message":"Your request count is over the allowed limit."}')
		-- Return connection in pool
    		local ok, error = connection:set_keepalive(60000, redis_pool_size)
    		if not ok then
    		    ngx.log(log_level, "failed to set keepalive: ", error)
    		end
		ngx.exit(ngx.HTTP_OK)
        end
    else
        return
    end
end

return _M
