--[[
    Title          : Library for easy way of creating HTTP JSON Api Service for ESP32
    Author         : Alija Bobija
    Author-Website : https://abobija.com
    GitHub Repo    : https://github.com/abobija/api32
    
    Dependencies:
        - sjson
        - encoder
]]

local Api32 = {}

local function str_starts_with(haystack, needle)
    return haystack:sub(1, #needle) == needle
end

local function str_split(inputstr, sep)
    if sep == nil then sep = "%s" end
    local result = {}
    for str in inputstr:gmatch("([^"..sep.."]+)") do table.insert(result, str) end
    
    return result
end

local function json_parse(json_str)
    local ok
    local result
    ok, result = pcall(sjson.decode, json_str)

    if ok then return result end
    return nil
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
        if str_starts_with(hline:lower(), hname:lower()) then
            local colon_index = hline:find(':')

            if colon_index ~= nil then
                return hline:sub(colon_index + 2)
            end
        end
    end

    return nil
end

local function get_auth_from_http_header(hlines)
    local auth_line = get_http_header_value('Authorization', hlines)

    if auth_line == nil then return nil end

    local parts = str_split(auth_line)

    if #parts == 2 and parts[1]:lower() == 'basic' then
        local key = parts[2]
        parts = nil

        local ok
        local decoded_key
        ok, decoded_key = pcall(encoder.fromBase64, key)
        
        key = nil

        if ok then
            parts = str_split(decoded_key, ':')
            decoded_key = nil

            if #parts == 2 then
                return {
                    user = parts[1],
                    pwd  = parts[2]
                }
            end
        end
    end
    
    return nil
end

local function parse_http_header(request, params)
    local options = {
        parse_auth = false
    }

    if params ~= nil then
        if params.parse_auth ~= nil then options.parse_auth = params.parse_auth end
    end

    local hlines = str_split(request, "\r\n")

    if #hlines > 0 then
        local hline1_parts = str_split(hlines[1])
        
        if #hline1_parts == 3 and hline1_parts[3] == 'HTTP/1.1' then
            local result = {
                method = hline1_parts[1],
                path   = hline1_parts[2],
                std    = hline1_parts[3]
            }

            hline1_parts = nil
            
            result.content_length = get_http_header_value('Content-Length', hlines)

            if options.parse_auth then
                result.auth = get_auth_from_http_header(hlines)
            end
            
            hlines = nil

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
        http_body_min = conf.http_body_min,
        http_body_max = conf.http_body_max,
        port          = conf.port,
        auth          = conf.auth
    }
    
    -- Defaults
    if self.http_body_min == nil then self.http_body_min = 10 end
    if self.http_body_max == nil then self.http_body_max = 512 end
    if self.port == nil then self.port = 80 end
    
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

    local sending = false
    local http_header = nil
    local http_req_body_buffer = nil

    local function stop_rec()
        sending = false
        http_header = nil
        http_req_body_buffer = nil
    end

    local is_authorized = function()
        return self.auth == nil or (
            http_header ~= nil
            and http_header.auth ~= nil
            and self.auth.user == http_header.auth.user
            and self.auth.pwd == http_header.auth.pwd
        )
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
        local response_body = nil
        
        res[1] = 'HTTP/1.1 '
        res[#res + 1] = "Content-Type: application/json; charset=UTF-8\r\n"
        
        if http_header == nil then
            response_status = '400 Bad Request'
        else
            if not is_authorized() then
                response_status = '401 Unauthorized'
                res[#res + 1]   = 'WWW-Authenticate: Basic realm="User Visible Realm", charset="UTF-8"\r\n'
            else
                local ep = get_endpoint(http_header.method, http_header.path)
                
                if ep == nil then
                    response_status = '404 Not Found'
                else
                    http_header          = nil
                    local jreq           = json_parse(http_req_body_buffer)
                    http_req_body_buffer = nil
                    local jres           = ep.handler(jreq)
                    jreq                 = nil
                    response_body        = json_stringify(jres)
                    jres                 = nil
                end
            end
        end
        
        res[1] = res[1] .. response_status .. "\r\n"
        res[#res + 1] = "\r\n"

        if response_body ~= nil then
            res[#res + 1] = response_body
            response_body = nil
        end
        
        stop_rec()
        send(sck)
    end
    
    local on_receive = function(sck, data)
        if sending then return end
        
        if http_header == nil then
            local eof_head = data:find("\r\n\r\n")
            local head_data = nil
            
            if eof_head ~= nil then
                head_data = data:sub(1, eof_head - 1)
                http_req_body_buffer = data:sub(eof_head + 4)
            end
            
            data = nil

            if head_data ~= nil then
                http_header = parse_http_header(head_data, {
                    parse_auth = self.auth ~= nil
                })
                
                head_data = nil
            end

            if http_header ~= nil then
                if http_header.content_length == nil
                    or http_header.content_length < self.http_body_min
                    or http_header.content_length > self.http_body_max then
                    -- It seems like request body is too short, too big or does not exist at all.
                    
                    -- Parse request immediatelly
                    return parse_http_request(sck)
                end
            else
                -- Received some data which does not represent the http header.
                -- Let's parse it anyway because error 400 shoud be sent back to the client
                
                return parse_http_request(sck)
            end
        end

        if data ~= nil and http_header ~= nil then
            -- Buffering request body
            
            if http_req_body_buffer == nil then
                http_req_body_buffer = data
            else
                http_req_body_buffer = http_req_body_buffer .. data
            end
        end

        -- Check if body has received
        if http_req_body_buffer ~= nil then
            local http_body_len = http_req_body_buffer:len()
            
            if (http_header.content_length ~= nil and http_body_len >= http_header.content_length)
                or http_body_len >= self.http_body_max then
                -- Received enough bytes of request body.
                
                return parse_http_request(sck)
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
