RSpec.describe DressSocks::Socket, '#initialize' do
  # These examples drive real descriptors against a loopback listener rather
  # than stubbing close/closed?. Stubs only prove a message was sent to a
  # mock; they cannot prove a file descriptor was released.
  #
  # Several examples drive #initialize on an allocated instance, which is
  # exactly what .new does, so a reference to the socket survives a
  # constructor that raises and its descriptor can be inspected afterwards.
  # Note __send__ rather than send: this class descends from BasicSocket,
  # where #send is the send(2) syscall, not Object#send.

  # RFC 5737 TEST-NET-1. Reserved for documentation and not routed on the
  # public internet, so a connect attempt hangs rather than being refused.
  BLACKHOLE_IP = '192.0.2.1'.freeze

  # Short enough to keep the suite fast, long enough not to race the loopback.
  TIMEOUT = 0.3

  let(:servers) { [] }
  let(:threads) { [] }

  after do
    threads.each(&:kill)
    servers.each { |server| server.close unless server.closed? }
  end

  def listener
    TCPServer.new('127.0.0.1', 0).tap { |server| servers << server }
  end

  def port_of(server)
    server.addr[1]
  end

  # Completes the TCP handshake via the accept backlog and then says nothing,
  # so the client's first recv blocks until the read timeout fires.
  def silent_server
    listener
  end

  # Answers the SOCKS5 method negotiation, then goes silent. The timeout
  # therefore lands inside socks_connect -> socks_receive_reply, which is
  # where a real interrupt is most likely to land and which pins the
  # placement of the handshake_complete flag.
  def server_stalling_after_auth
    server = listener
    threads << Thread.new do
      client = server.accept
      client.recv(3)
      client.write("\005\000")
      sleep
    end
    server
  end

  # A complete, successful SOCKS5 no-auth negotiation.
  def working_socks_server
    server = listener
    threads << Thread.new do
      client = server.accept
      client.recv(3)                                   # version identifier
      client.write("\005\000")                         # no authentication
      client.recv(512)                                 # connect request
      client.write("\005\000\000\001#{[127, 0, 0, 1].pack('C4')}#{[0].pack('n')}")
      sleep                                            # hold the connection open
    end
    server
  end

  # A port that was bound and immediately released, so a connect to it is
  # refused rather than hanging.
  def closed_port
    server = TCPServer.new('127.0.0.1', 0)
    port = port_of(server)
    server.close
    port
  end

  describe 'through a SOCKS proxy' do
    it 'raises Timeout::Error when the handshake read exceeds the timeout' do
      server = silent_server

      expect do
        described_class.new('mx.example.com', 25,
                            socks_server: '127.0.0.1', socks_port: port_of(server),
                            timeout_duration: TIMEOUT)
      end.to raise_error(Timeout::Error, /SOCKS handshake/)
    end

    it 'raises Timeout::Error when the interrupt lands in the SOCKS connect' do
      server = server_stalling_after_auth

      expect do
        described_class.new('mx.example.com', 25,
                            socks_server: '127.0.0.1', socks_port: port_of(server),
                            timeout_duration: TIMEOUT)
      end.to raise_error(Timeout::Error, /SOCKS handshake/)
    end

    it 'closes the descriptor when the handshake read times out' do
      server = silent_server
      socket = described_class.allocate

      expect do
        socket.__send__(:initialize, 'mx.example.com', 25,
                        socks_server: '127.0.0.1', socks_port: port_of(server),
                        timeout_duration: TIMEOUT)
      end.to raise_error(Timeout::Error)

      expect(socket).to be_closed
    end

    it 'closes the descriptor when the interrupt lands in the SOCKS connect' do
      server = server_stalling_after_auth
      socket = described_class.allocate

      expect do
        socket.__send__(:initialize, 'mx.example.com', 25,
                        socks_server: '127.0.0.1', socks_port: port_of(server),
                        timeout_duration: TIMEOUT)
      end.to raise_error(Timeout::Error)

      expect(socket).to be_closed
    end

    # The whole point of the change: the bound is enforced by the socket
    # itself, at a known point, rather than by a watchdog thread that raises
    # asynchronously into whatever happens to be running.
    it 'bounds the handshake without a Timeout watchdog' do
      server = silent_server
      expect(Timeout).not_to receive(:timeout)

      expect do
        described_class.new('mx.example.com', 25,
                            socks_server: '127.0.0.1', socks_port: port_of(server),
                            timeout_duration: TIMEOUT)
      end.to raise_error(Timeout::Error)
    end

    it 'raises Timeout::Error when the TCP connect exceeds the timeout' do
      socket = described_class.allocate

      error = begin
                socket.__send__(:initialize, 'mx.example.com', 25,
                                socks_server: BLACKHOLE_IP, socks_port: 1080,
                                timeout_duration: TIMEOUT)
                nil
              rescue Errno::ENETUNREACH, Errno::EHOSTUNREACH, Errno::ECONNREFUSED => e
                skip "no blackhole route in this environment (#{e.class}); " \
                     'cannot exercise a real connect timeout here'
              rescue Timeout::Error => e
                e
              end

      expect(error).to be_a(Timeout::Error)
      expect(error.message).to match(/SOCKS proxy/)
    end

    # A refused connect leaves the stream uninitialized. Calling closed? on it
    # raises IOError, which would mask the real error, so the cleanup must not
    # reach closed? at all.
    it 'does not attempt to close when the TCP connect itself failed' do
      port = closed_port

      expect do
        described_class.new('mx.example.com', 25,
                            socks_server: '127.0.0.1', socks_port: port,
                            timeout_duration: TIMEOUT)
      end.to raise_error(Errno::ECONNREFUSED)
    end

    it 'leaves a successful connection open' do
      server = working_socks_server

      socket = described_class.new('mx.example.com', 25,
                                   socks_server: '127.0.0.1', socks_port: port_of(server),
                                   timeout_duration: TIMEOUT)

      expect(socket).not_to be_closed
      socket.close
    end

    # The socket is handed to Net::SMTP, which manages its own much longer
    # read_timeout. Leaving the short handshake bound applied to the
    # underlying IO would fire during normal SMTP reads.
    it 'resets the socket timeout after a successful handshake' do
      server = working_socks_server

      socket = described_class.new('mx.example.com', 25,
                                   socks_server: '127.0.0.1', socks_port: port_of(server),
                                   timeout_duration: TIMEOUT)

      expect(socket.timeout).to be_nil
      socket.close
    end
  end

  describe 'without a SOCKS proxy' do
    it 'connects directly and applies no handshake timeout' do
      server = silent_server

      socket = described_class.new('127.0.0.1', port_of(server))

      expect(socket).not_to be_closed
      expect(socket.timeout).to be_nil
      socket.close
    end
  end
end
