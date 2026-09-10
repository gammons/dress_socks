RSpec.describe DressSocks::Socket do

  context 'connects via socket' do
    let(:socket) { DressSocks::Socket.new('socktest.ngrok.io', 80, socks_server: '104.209.187.64', socks_port: 1080, socks_username: 'socksuser', socks_password: '8ewsVnpBfm8FDjcYdpkjFyG2') }

    it 'should get data' do
      socket.write("GET /users/sign_in HTTP/1.1\r\nHost: socktest.ngrok.io\r\nConnection: close\r\nUser-Agent: Test\r\n\r\n\r\n")
    end

  end

end

RSpec.describe DressSocks::Socket, '#initialize cleanup' do
  # Timeout.timeout around the handshake can fire after the TCP connect has
  # succeeded. Without an ensure, the caller never receives the object, so
  # nothing closes the descriptor until GC finalises it.
  #
  # These examples drive #initialize directly on an allocated instance so the
  # constructor can be exercised without a real network. Note the use of
  # __send__ rather than send: this class descends from BasicSocket, where
  # #send is the send(2) syscall, not Object#send.
  def build_socket_raising(error, tcp_connected: true)
    socket = described_class.allocate
    allow(socket).to receive(:initialize_tcp) { raise error unless tcp_connected }
    allow(socket).to receive(:socks_authenticate).and_raise(error) if tcp_connected
    allow(socket).to receive(:closed?).and_return(false)
    allow(socket).to receive(:close)
    socket
  end

  it 'closes the descriptor when the handshake is interrupted' do
    socket = build_socket_raising(Timeout::Error)

    expect do
      socket.__send__(:initialize, 'mx.example.com', 25, socks_server: '10.0.0.1', socks_port: 1080)
    end.to raise_error(Timeout::Error)

    expect(socket).to have_received(:close)
  end

  # The interrupt is most likely to land here: socks_connect ends in
  # socks_receive_reply, a chain of blocking recv calls. This example also pins
  # where handshake_complete is assigned -- moving it inside the Timeout block
  # ahead of socks_connect would leak the descriptor again.
  it 'closes the descriptor when the interrupt lands in the SOCKS connect' do
    socket = described_class.allocate
    allow(socket).to receive(:initialize_tcp)
    allow(socket).to receive(:socks_authenticate)
    allow(socket).to receive(:socks_connect).and_raise(Timeout::Error)
    allow(socket).to receive(:closed?).and_return(false)
    allow(socket).to receive(:close)

    expect do
      socket.__send__(:initialize, 'mx.example.com', 25, socks_server: '10.0.0.1', socks_port: 1080)
    end.to raise_error(Timeout::Error)

    expect(socket).to have_received(:close)
  end

  it 'does not attempt to close when the TCP connect itself failed' do
    socket = build_socket_raising(Errno::ECONNREFUSED, tcp_connected: false)

    expect do
      socket.__send__(:initialize, 'mx.example.com', 25, socks_server: '10.0.0.1', socks_port: 1080)
    end.to raise_error(Errno::ECONNREFUSED)

    expect(socket).not_to have_received(:close)
  end

  it 'leaves a successful connection open' do
    socket = described_class.allocate
    allow(socket).to receive(:initialize_tcp)
    allow(socket).to receive(:socks_authenticate)
    allow(socket).to receive(:socks_connect)
    allow(socket).to receive(:closed?).and_return(false)
    allow(socket).to receive(:close)

    socket.__send__(:initialize, 'mx.example.com', 25, socks_server: '10.0.0.1', socks_port: 1080)

    expect(socket).not_to have_received(:close)
  end
end
