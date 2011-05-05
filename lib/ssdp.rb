require 'ipaddr'
require_relative 'core_ext/socket_patch'
require 'thread'
require 'time'
require 'uri'

require 'ssdp/notification'
require 'ssdp/response'
require 'ssdp/search'

# Simple Service Discovery Protocol for the UPnP Device Architecture.
#
# Currently SSDP only handles the discovery portions of SSDP.
#
# To listen for SSDP notifications from UPnP devices:
#
#   ssdp = SSDP.new
#   notifications = ssdp.listen
#
# To discover all devices and services:
#
#   ssdp = SSDP.new
#   resources = ssdp.search
#
# After a device has been found you can create a Device object for it:
#
#   UPnP::Control::Device.create resource.location
#
# Based on code by Kazuhiro NISHIYAMA (zn@mbf.nifty.com)
class SSDP
  VERSION = '0.1.0'
  DEVICE_SCHEMA_PREFIX = 'urn:schemas-upnp-org:device'
  SERVICE_SCHEMA_PREFIX = 'urn:schemas-upnp-org:service'

  # SSDP Error class
  class Error < StandardError
  end

  # Default broadcast address
  BROADCAST = '239.255.255.250'

  # Default port
  PORT = 1900

  # Default timeout
  TIMEOUT = 1

  # Default packet time to live (hops)
  TTL = 4

  # Broadcast address to use when sending searches and listening for
  # notifications.
  attr_accessor :broadcast

  # Listener accessor for tests.
  attr_accessor :listener

  # A WEBrick::Log logger for unified logging.
  attr_writer :log

  # Thread that periodically notifies for advertise.
  attr_reader :notify_thread

  # Port to use for SSDP searching and listening.
  attr_accessor :port

  # Queue accessor for tests.
  attr_accessor :queue

  # Thread that handles search requests for advertise.
  attr_reader :search_thread

  # Socket accessor for tests.
  attr_accessor :socket

  # Time to wait for SSDP responses.
  attr_accessor :timeout

  # TTL for SSDP packets.
  attr_accessor :ttl

  # Creates a new SSDP object.  Use the accessors to override broadcast, port,
  # timeout or ttl.
  #
  # @param [Fixnum] ttl Use a different TTL than the default value of 4.
  def initialize(ttl=TTL)
    @broadcast = BROADCAST
    @port = PORT
    @timeout = TIMEOUT
    @ttl = ttl

    @log = nil

    @listener = nil
    @queue = Queue.new

    @search_thread = nil
    @notify_thread = nil
  end

  # Listens for M-SEARCH requests and advertises the requested services.
  def advertise(root_device, port, hosts)
    @socket ||= new_socket

    @notify_thread = Thread.start do
      loop do
        hosts.each do |host|
          uri = "http://#{host}:#{port}/description"

          send_notify uri, 'upnp:rootdevice', root_device

          root_device.devices.each do |d|
            send_notify uri, d.name, d
            send_notify uri, d.type_urn, d
          end

          root_device.services.each do |s|
            send_notify uri, s.type_urn, s
          end
        end

        sleep 60
      end
    end

    listen

    @search_thread = Thread.start do
      loop do
        search = @queue.pop

        break if search == :shutdown

        next unless Search === search

        case search.target
        # TODO: DEVICE_SCHEMA_PREFIX = 'urn:schemas-upnp-org:device'
        when /^#{DEVICE_SCHEMA_PREFIX}/ then
          devices = root_device.devices.select do |d|
            d.type_urn == search.target
          end

          devices.each do |d|
            hosts.each do |host|
              uri = "http://#{host}:#{port}/description"
              send_response uri, search.target, "#{d.name}::#{search.target}", d
            end
          end
        when 'upnp:rootdevice' then
          hosts.each do |host|
            uri = "http://#{host}:#{port}/description"
            send_response uri, search.target, search.target, root_device
          end
        else
          warn "Unhandled target #{search.target}"
        end
      end
    end

    sleep

  ensure
    @queue.push :shutdown
    stop_listening
    @notify_thread.kill

    @socket.close if @socket and not @socket.closed?
    @socket = nil
  end

  def byebye(root_device, hosts)
    @socket ||= new_socket

    hosts.each do |host|
      send_notify_byebye 'upnp:rootdevice', root_device

      root_device.devices.each do |d|
        send_notify_byebye d.name, d
        send_notify_byebye d.type_urn, d
      end

      root_device.services.each do |s|
        send_notify_byebye s.type_urn, s
      end
    end
  end

  # Discovers UPnP devices sending NOTIFY broadcasts.
  #
  # If given a block, yields each Notification as it is received and never
  # returns.  Otherwise, discover waits for timeout seconds and returns all
  # notifications received in that time.
  #
  # @yield [SSDP::Notification]
  def discover
    @socket ||= new_socket

    listen

    if block_given? then
      loop do
        notification = @queue.pop

        yield notification
      end
    else
      sleep @timeout

      notifications = []
      notifications << @queue.pop until @queue.empty?
      notifications
    end
  ensure
    stop_listening
    @socket.close if @socket and not @socket.closed?
    @socket = nil
  end

  # Listens for UDP packets from devices in a Thread and enqueues them for
  # processing.  Requires a socket from search or discover.
  def listen
    return @listener if @listener and @listener.alive?

    @listener = Thread.start do
      loop do
        response, (family, port, hostname, address) = @socket.recvfrom 1024

        begin
          adv = parse response

          info = case adv
                 when Notification then adv.type
                 when Response     then adv.target
                 when Search       then adv.target
                 else                   'unknown'
                 end

          response =~ /\A(\S+)/
          log :debug, "SSDP recv #{$1} #{hostname}:#{port} #{info}"

          @queue << adv
        rescue
          warn $!.message
          warn $!.backtrace
        end
      end
    end
  end

  # TODO: Re-implement logging.
  def log(level, message)
    return unless @log

    @log.send level, message
  end

  # Sets up a UDPSocket for multicast send and receive.
  #
  # @return [UDPSocket]
  def new_socket
    membership = IPAddr.new(@broadcast).hton + IPAddr.new('0.0.0.0').hton
    ttl = [@ttl].pack 'i'

    socket = UDPSocket.new

    socket.setsockopt Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, membership
    socket.setsockopt Socket::IPPROTO_IP, Socket::IP_MULTICAST_LOOP, "\000"
    socket.setsockopt Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, ttl
    socket.setsockopt Socket::IPPROTO_IP, Socket::IP_TTL, ttl

    socket.bind '0.0.0.0', @port

    socket
  end

  # Returns a Notification, Response or Search created from +response+.
  #
  # @param [String] response
  # @return [SSDP::Notification, SSDP::Response, SSDP::Search]
  def parse(response)
    case response
    when /\ANOTIFY/ then
      SSDP::Notification.parse response
    when /\AHTTP/ then
      SSDP::Response.parse response
    when /\AM-SEARCH/ then
      SSDP::Search.parse response
    else
      raise Error, "Unknown response #{response[/\A.*$/]}"
    end
  end

  # Sends M-SEARCH requests looking for +targets+.  Waits timeout seconds
  # for responses then returns the collected responses.
  #
  # Supply no arguments to search for all devices and services.
  #
  # Supply <tt>:root</tt> to search for root devices only.
  #
  # Supply <tt>[:device, 'device_type:version']</tt> to search for a specific
  # device type.
  #
  # Supply <tt>[:service, 'service_type:version']</tt> to search for a
  # specific service type.
  #
  # Supply <tt>"uuid:..."</tt> to search for a UUID.
  #
  # Supply <tt>"urn:..."</tt> to search for a URN.
  def search(*targets)
    @socket ||= new_socket

    if targets.empty? then
      send_search 'ssdp:all'
    else
      targets.each do |target|
        if target == :root then
          send_search 'upnp:rootdevice'
        elsif Array === target and target.first == :device then
          target = [DEVICE_SCHEMA_PREFIX, target.last]
          send_search target.join(':')
        elsif Array === target and target.first == :service then
          target = [SERVICE_SCHEMA_PREFIX, target.last]
          send_search target.join(':')
        elsif String === target and target =~ /\A(urn|uuid|ssdp):/ then
          send_search target
        end
      end
    end

    listen
    sleep @timeout

    responses = []
    responses << @queue.pop until @queue.empty?
    responses
  ensure
    stop_listening
    @socket.close if @socket and not @socket.closed?
    @socket = nil
  end

  # Builds and sends a NOTIFY message.
  def send_notify(uri, type, obj)
    if type =~ /^uuid:/ then
      name = obj.name
    else
      # HACK maybe this should be .device?
      name = "#{obj.root_device.name}::#{type}"
    end

    server_info = "Ruby SSDP/#{SSDP::VERSION}"
    device_info = "#{obj.root_device.class}/#{obj.root_device.version}"

    http_notify = <<-HTTP_NOTIFY
NOTIFY * HTTP/1.1\r
HOST: #{@broadcast}:#{@port}\r
CACHE-CONTROL: max-age=120\r
LOCATION: #{uri}\r
NT: #{type}\r
NTS: ssdp:alive\r
SERVER: #{server_info} UPnP/1.0 #{device_info}\r
USN: #{name}\r
\r
    HTTP_NOTIFY

    log :debug, "SSDP sent NOTIFY #{type}"

    @socket.send http_notify, 0, @broadcast, @port
  end

  # Builds and sends a byebye NOTIFY message.
  #
  # @param [String] service_type
  # @param [?] obj
  def send_notify_byebye(service_type, obj)
    if service_type =~ /^uuid:/ then
      name = obj.name
    else
      # HACK maybe this should be .device?
      name = "#{obj.root_device.name}::#{service_type}"
    end

    http_notify = <<-HTTP_NOTIFY
NOTIFY * HTTP/1.1\r
HOST: #{@broadcast}:#{@port}\r
NT: #{service_type}\r
NTS: ssdp:byebye\r
USN: #{name}\r
\r
    HTTP_NOTIFY

    log :debug, "SSDP sent byebye #{service_type}"

    @socket.send http_notify, 0, @broadcast, @port
  end

  # Builds and sends a response to an M-SEARCH request.
  #
  # @param [String] location
  # @param [String] service_type
  # @param [String] service_name AKA the USN.
  # @param [?] device
  def send_response(location, service_type, service_name, device)
    server_info = "Ruby SSDP/#{SSDP::VERSION}"
    device_info = "#{device.root_device.class}/#{device.root_device.version}"

    http_response = <<-HTTP_RESPONSE
HTTP/1.1 200 OK\r
CACHE-CONTROL: max-age=120\r
EXT:\r
LOCATION: #{location}\r
SERVER: #{server_info} UPnP/1.0 #{device_info}\r
ST: #{service_type}\r
NTS: ssdp:alive\r
USN: #{service_name}\r
Content-Length: 0\r
\r
    HTTP_RESPONSE

    log :debug, "SSDP sent M-SEARCH OK #{service_type}"

    @socket.send http_response, 0, @broadcast, @port
  end

  # Builds and sends an M-SEARCH request looking for +service_type+.
  #
  # @param [String] service_type The URI of type of service to look for, given
  #   as a String.
  def send_search(service_type)
    @socket ||= new_socket
    search = <<-HTTP_REQUEST
M-SEARCH * HTTP/1.1\r
HOST: #{@broadcast}:#{@port}\r
MAN: "ssdp:discover"\r
MX: #{@timeout}\r
ST: #{service_type}\r
\r
    HTTP_REQUEST

    log :debug, "SSDP sent M-SEARCH #{service_type}"

    @socket.send search, 0, @broadcast, @port
  end

  # Stops and clears the listen thread.
  def stop_listening
    @listener.kill if @listener
    @queue = Queue.new
    @listener = nil
  end
end


