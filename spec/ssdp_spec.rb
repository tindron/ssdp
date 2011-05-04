require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "SSDP" do
  before :all do
    @ssdp = SSDP.new
  end

  it "uses it's own reserved multicast broadcast address: 239.255.255.250" do
    @ssdp.instance_variable_get(:@broadcast).should == "239.255.255.250"
  end

  it "uses it's own reserved multicast broadcast port: 1900" do
    @ssdp.instance_variable_get(:@port).should == 1900
  end

  it "sets TTL to 4 by default" do
    @ssdp.instance_variable_get(:@ttl).should == 4
  end

  it "allows you to set TTL to a different value" do
    ssdp = UPnPSavon::SSDP.new(1)
    ssdp.instance_variable_get(:@ttl).should == 1
  end

  describe "#new_socket" do
    before do
      @socket = @ssdp.new_socket
    end

    after do
      @socket.close
    end

    it "returns a UDPSocket" do
      @socket.class.should == UDPSocket
      puts @socket.addr
    end
  end
end
