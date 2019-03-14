--[[
    Author: Alija Bobija
    Website: http://abobija.com
]]

local Api32 = {}

local function str_starts_with(haystack, needle)
    local h_len = haystack:len()
    local n_len = needle:len()

    return n_len <= h_len and haystack:sub(1, n_len) == needle
end

local function str_split(inputstr, sep)
    if sep == nil then sep = "%s" end
    local result = {}
    for str in inputstr:gmatch("([^"..sep.."]+)") do table.insert(result, str) end
    
    return result
end

local function json_parse(json_str)
    if json_str == nil then return nil end

    local ok
    local result
    
    ok, result = pcall(sjson.decode, json_str)

    if not ok then return nil end
    
    return result
end

local function json_stringify(table)
    local ok
    local json
    ok, json = pcall(sjson.encode, table)
    
    if ok then return json end
    return nil
end

local function get_http_header_value(hname, hlines)
    for _, hline in pairs(hlines) do
        if str_starts_with(hline, hname) then
            local colon_index = hline:find(':')

            if colon_index ~= nil then
                return hline:sub(colon_index + 2)
            end
        end
    end

    return nil
end

local function parse_http_header(request)
    local hlines = str_split(request, "\r\n")

    if #hlines > 0 then
        local hline1_parts = str_split(hlines[1])
        
        if #hline1_parts == 3 and hline1_parts[3] == 'HTTP/1.1' then
            local result = {
                method         = hline1_parts[1],
                path           = hline1_parts[2],
                std            = hline1_parts[3],
                content_length = get_http_header_value('Content-Length', hlines)
            }

            if result.content_length ~= nil then
                result.content_length = tonumber(result.content_length)
            end

            return result
        end
    end

    return nil
end

Api32.create = function(conf) 
    local self = {
        port          = conf.port,
        http_body_min = 10,
        http_body_max = 512
    }

    local endpoints = {}
    
    self.on = function(method, path, handler)
        table.insert(endpoints, {
            method  = method,
            path    = path,
            handler = handler
        })
        
        return self
    end

    self.on_get = function(path, handler)
        return self.on('GET', path, handler)
    end

    self.on_post = function(path, handler)
        return self.on('POST', path, handler)
    end
    
    local get_endpoint = function(method, path)
        for _, ep in pairs(endpoints) do
            if ep.method == method and ep.path == path then return ep end
        end

        return nil
    end
    
    local srv = net.createServer(net.TCP, 30)

    local sending     = false
    local http_header = nil
    local http_body   = nil
    
    local function stop_rec()
        sending     = false
        http_header = nil
        http_body   = nil
    end
    
    local function parse_http_request(sck)
        local res = {}
        
        local send = function(_sck)
            sending = true
            
            if #res > 0 then
                _sck:send(table.remove(res, 1))
            else
                sending = false
                _sck:close()
                res = nil
            end
        end
        
        sck:on('sent', send)
        
        local response_status = '200 OK'
        
        res[1] = 'HTTP/1.1 '
        res[#res + 1] = "Content-Type: application/json; charset=UTF-8\r\n"
        res[#res + 1] = "\r\n"
        
        if http_header == nil then
            response_status = '400 Bad Request'
        else
            local ep = get_endpoint(http_header.method, http_header.path)
            
            if ep == nil then
                response_status = '404 Not Found'
            else
                http_header   = nil
                local jreq    = json_parse(http_body)
                http_body     = nil
                local jres    = ep.handler(jreq)
                jreq          = nil
                res[#res + 1] = json_stringify(jres)
                jres          = nil
            end
        end
        
        res[1] = res[1] .. response_status .. "\r\n"
        
        stop_rec()
        send(sck)
    end
    
    local on_receive = function(sck, data)
        if sending then return end
        
        if http_header == nil then
            http_header = parse_http_header(data)
            data = nil
            
            if http_header ~= nil then
                -- Received data that propbably represent http header
                print('method ', http_header.method, ' path ', http_header.path, ' std ', http_header.std, ' content-length ', http_header.content_length)

                if http_header.content_length == nil
                    or http_header.content_length < self.http_body_min
                    or http_header.content_length > self.http_body_max then
                    -- It seems like request body is too short, too big or does not exist at all.
                    -- Parse request immediatelly
                    
                    parse_http_request(sck)
                end
            else
                -- Received some data which is not represent http header.
                -- Let's parse it anyway because error 400 shoud be sent to the client
                
                parse_http_request(sck)
            end
        else
            -- Receiving body packets
            
            if http_body == nil then
                http_body = data
            else
                http_body = http_body .. data
            end

            local http_body_len = http_body:len()
            
            if http_body_len >= http_header.content_length
                or http_body_len >= self.http_body_max then
                -- Received enough bytes of request body.
                
                parse_http_request(sck)
            end
        end
    end

    srv:listen(self.port, function(conn)
        stop_rec()
    
        conn:on('receive', on_receive)
        conn:on('disconnection', stop_rec)
    end)

    return self
end

return Api32