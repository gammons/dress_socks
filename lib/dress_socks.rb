require "socket"
require "resolv"
# Socket#initialize re-raises its synchronous timeouts as Timeout::Error.
# That constant reaches us transitively through resolv today, which is an
# accident we should not depend on.
require "timeout"

require "dress_socks/version"
require "dress_socks/socket"
require 'dress_socks/errors'

module DressSocks

end
