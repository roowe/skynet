local skynet = require "skynet"
require "skynet.manager"

if ... == "echo" then
	skynet.start(function()
		skynet.dispatch("lua", function(_, _, payload)
			skynet.retpack(payload)
		end)
	end)
	return
end

local function smoke()
	require "client.crypt"
	require "lpeg"
	require "sproto.core"
	require "bson"
	local md5 = require "md5"
	assert(md5.sumhexa("") == "d41d8cd98f00b204e9800998ecf8427e")

	local echo = skynet.newservice(SERVICE_NAME, "echo")
	local payload = "round-trip\0payload"
	assert(skynet.call(echo, "lua", payload) == payload)
	local before = skynet.now()
	skynet.sleep(2)
	assert(skynet.now() - before >= 2)
end

skynet.start(function()
	skynet.timeout(500, function()
		io.stderr:write("skynet build smoke timed out\n")
		os.exit(1)
	end)
	local ok, err = xpcall(smoke, debug.traceback)
	if not ok then
		io.stderr:write(err, "\n")
		os.exit(1)
	end
	print("skynet build smoke ok")
	skynet.abort()
end)
