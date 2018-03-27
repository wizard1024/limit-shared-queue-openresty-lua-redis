_M = { _VERSION = "1.1" }

local reset = 0

local function expire_key(redis_connection, key, interval, log_level)
    local expire, error = redis_connection:expire(key, interval)
    if not expire then
        ngx.log(log_level, "failed to get ttl: ", error)
        return
    end
end

-- Function to check Parent queue for limits
local function overlimit(redis_connection, ip_key, rate_max, interval, log_level)
	local result = false
    	local key = "RL:" .. ip_key
	local keyTotal = "RL:Total"
	local lock, error = redis_connection:set("RL:Lock", "Locked", "PX", "10000", "NX")
	while lock == ngx.null do
		lock, error = redis_connection:set("RL:Lock", "Locked", "PX", "10000", "NX")
	end
	local total, error = redis_connection:incr(keyTotal)	
	redis_connection:del("RL:Lock")
	if not total then
		ngx.log(log_level, "Failed to get key: ", error)
	end
	if tonumber(total) == 1 then 
		result = false
		expire_key(redis_connection, keyTotal, interval, log_level)
	else
		if tonumber(total) > rate_max then
			result = true
			redis_connection:decr(keyTotal)
		else 
			result = false
       			local ttl, error = redis_connection:pttl(keyTotal)
       			if not ttl then
       			    ngx.log(log_level, "failed to get ttl: ", error)
       			    return
       			end
       			if ttl == -2 then
       			    ttl = interval
       			    expire_key(redis_connection, keyTotal, interval, log_level)
       			end
		end
	end
	return result
end

-- Function to increse class queue and set TTL to key
local function bump_request(redis_connection, redis_pool_size, ip_key, rate, interval, current_time, log_level)
    local key = "RL:" .. ip_key

    local count, error = redis_connection:incr(key)
    if not count then
        ngx.log(log_level, "failed to incr count: ", error)
        return
    end

    if tonumber(count) == 1 then
        reset = (current_time + interval)
        expire_key(redis_connection, key, interval, log_level)
    else
        local ttl, error = redis_connection:pttl(key)
        if not ttl then
            ngx.log(log_level, "failed to get ttl: ", error)
            return
        end
        if ttl == -2 then
            ttl = interval
            expire_key(redis_connection, key, interval, log_level)
        end
        reset = (current_time + (ttl * 0.001))
    end

    local remaining = rate - count

    return { count = count, remaining = remaining, reset = reset }
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
	local intervalTotal = config.intervalTotal or 1;
	local r_i = config.r_i or {{"0", 10, 1, false}}
	local rateTotalDec = rateTotal
	local rate = 10
	local interval = 1
	local enforce_limit = false
	-- Determine parameters from config
    	for i,r_i_keys in ipairs(r_i) do
    	    if r_i_keys[1] == key then
    	    	rate = r_i_keys[2]
    	    	interval = r_i_keys[3]
		enforce_limit = r_i_keys[4]
    	    end
	    rateTotalDec = rateTotalDec - 1;
    	end
	
        local current_time = ngx.now()
        local response, error = bump_request(connection, redis_pool_size, key, rate, interval, current_time, log_level)
        if not response then
            return
        end

        if response.count > rate then
		if enforce_limit then
			if overlimit(connection, key, rateTotalDec, intervalTotal, log_level) then 
	            		local retry_after = math.floor(response.reset - current_time)
	            		if retry_after < 0 then
	            		    retry_after = 0
	            		end
	            		ngx.header["Access-Control-Expose-Headers"] = "Retry-After"
	            		ngx.header["Access-Control-Allow-Origin"] = "*"
	            		ngx.header["Content-Type"] = "application/json; charset=utf-8"
	            		ngx.header["Retry-After"] = retry_after
	            		ngx.status = 429
	            		ngx.say('{"status_code":25,"status_message":"Your request count (' .. response.count .. ') is over the allowed limit of ' .. rate .. '."}')
				-- Return connection in pool
    				local ok, error = connection:set_keepalive(60000, redis_pool_size)
    				if not ok then
    				    ngx.log(log_level, "failed to set keepalive: ", error)
    				end
	            		ngx.exit(ngx.HTTP_OK)
            	 	else
	        		ngx.header["X-RateLimit-Limit"] = rate
	        		ngx.header["X-RateLimit-Remaining"] = math.floor(response.remaining)
	        		ngx.header["X-RateLimit-Reset"] = math.floor(response.reset)
	        		ngx.header["X-RateLimit-Limit-Total"] = rateTotalDec
				-- Return connection in pool
    				local ok, error = connection:set_keepalive(60000, redis_pool_size)
    				if not ok then
    				    ngx.log(log_level, "failed to set keepalive: ", error)
    				end
			end
		else	
	            	local retry_after = math.floor(response.reset - current_time)
	            	if retry_after < 0 then
	            	    retry_after = 0
	            	end
	            	ngx.header["Access-Control-Expose-Headers"] = "Retry-After"
	            	ngx.header["Access-Control-Allow-Origin"] = "*"
	            	ngx.header["Content-Type"] = "application/json; charset=utf-8"
	            	ngx.header["Retry-After"] = retry_after
	            	ngx.status = 429
	            	ngx.say('{"status_code":25,"status_message":"Your request count (' .. response.count .. ') is over the allowed limit of ' .. rate .. '."}')
			-- Return connection in pool
    			local ok, error = connection:set_keepalive(60000, redis_pool_size)
    			if not ok then
    			    ngx.log(log_level, "failed to set keepalive: ", error)
    			end
	            	ngx.exit(ngx.HTTP_OK)
		end
        else
	    	if overlimit(connection, key, rateTotal, intervalTotal, log_level) then 
	    		local retry_after = math.floor(response.reset - current_time)
	    		if retry_after < 0 then
	    		    retry_after = 0
	    		end
	    		ngx.header["Access-Control-Expose-Headers"] = "Retry-After"
	    		ngx.header["Access-Control-Allow-Origin"] = "*"
	    		ngx.header["Content-Type"] = "application/json; charset=utf-8"
	    		ngx.header["Retry-After"] = retry_after
	    		ngx.status = 429
	    		ngx.say('{"status_code":25,"status_message":"Your request count (' .. response.count .. ') is over the allowed limit of ' .. rate .. '."}')
	        	-- Return connection in pool
    	        	local ok, error = connection:set_keepalive(60000, redis_pool_size)
    	        	if not ok then
    	        	    ngx.log(log_level, "failed to set keepalive: ", error)
    	        	end
	    		ngx.exit(ngx.HTTP_OK)
		else
			ngx.header["X-RateLimit-Limit"] = rate
			ngx.header["X-RateLimit-Remaining"] = math.floor(response.remaining)
			ngx.header["X-RateLimit-Reset"] = math.floor(response.reset)
			ngx.header["X-RateLimit-Limit-Total"] = rateTotalDec
			-- Return connection in pool
			local ok, error = connection:set_keepalive(60000, redis_pool_size)
			if not ok then
			    ngx.log(log_level, "failed to set keepalive: ", error)
			end
		end
        end
    else
        return
    end
end

return _M
