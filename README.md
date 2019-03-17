# Api32
Lua library for simple way of creating JSON APIs for ESP32

## Usage
### Registration of `GET` endpoint
To registrate `GET` endpoint, use the `on_get` method.
```
require('api32')
.create()
.on_get('/info', function(jreq) 
	return {
		message = 'Hello world'
	}
end)
```

By sending HTTP `GET` request to previously created `info` endpoint (e.g. 192.168.0.32/info), `Api32` will process the received HTTP request, and return next `JSON` as response back to the client (web browser):
```
{ "message" : "Hello world" }
```

### Registration of `POST` endpoint
To registrate `POST` endpoint, just use the `on_post` method, instead of `on_get`.
```
require('api32')
.create()
.on_post('/config', function(jreq) 
	return {
		message = 'Congrats! You have successfully accessed the POST endpoint.'
	}
end)
```

By sending HTTP `POST` request to `/config` endpoint, the next `JSON` response will be returned:
```
{ "message" : "Congrats! You have successfully accessed the POST endpoint." }
```

## Dependencies
The library depends on the following NodeMCU modules:
  - `sjson`
  - `encoder`
