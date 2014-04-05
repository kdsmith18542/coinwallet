#!/usr/bin/ruby
$LOAD_PATH.unshift File.dirname(__FILE__)
require 'rubygems'
require 'redis'
require 'ripple_rpc'
require 'bitcoin_rpc'
require 'digest/md5'

@@config = YAML.load_file('config.yml')

class Redis
  def setm(k, o)
    set(k, Marshal.dump(o))
  end
  def getm(k)
    m = get(k)
    m ? Marshal.load(m) : nil
  end
end

@@redis = Redis.new

def getrpc(coinname)
  d = @@config['coins'][coinname]
  uri = "http://#{d['user']}:#{d['password']}@#{d['host']}:#{d['port']}"
  BitcoinRPC.new(uri)
end

def getripplerpc
  d = @@config['ripple']
  account_id = d['account_id']
  master_seed = d['master_seed']
  uri = "http://#{d['host']}:#{d['port']}"
  RippleRPC.new(uri, account_id, master_seed)
end

def poll(rrpc, interval, min)
  max = -1
  limit = 200
  params = {
    'account' => rrpc.account_id,
    'ledger_index_min' => min,
    'ledger_index_max' => max,
    'limit' => limit,
  }
  result = rrpc.account_tx(params)
  unless result['status'] == 'success'
    sleep interval
    next
  end
  lmin = result['ledger_index_min']
  lmax = result['ledger_index_max']
  txs = result['transactions']
  if txs.empty?
    sleep interval
    next
  elsif txs.size >= limit
    raise txs # TODO
  end
  min = lmax + 1
  txs.each do |txo|
    tx = txo['tx']
    type = tx['TransactionType']
    next unless type == 'Payment'
    ledger_index = tx['ledger_index']
    amount = tx['Amount']
    next unless Hash === amount
    ai = amount['issuer']
    next unless rrpc.account_id == ai
    dst = tx['Destination']
    next unless dst == ai
    ac = amount['currency']
    av = amount['value']
    coins = @@config['coins']
    coinid, coin = coins.find{|k,v|v['symbol'] == ac}
    next unless coinid
    from = tx['Account']
    tag = tx['DestinationTag']
    @@redis.keys('id:*').each do |k|
      v = @@redis.getm(k)
      next unless v[:rippleaddr] == from
      tag2 = Digest::MD5.digest(k).unpack('V')[0] & 0x7fffffff
      next unless tag == tag2
      moveto = k
      rpc = getrpc(coinid)
      rpc.move('iou', moveto, av.to_f)
    end
  end
  @@redis.set('polling:ledger', min)
  min
end

def getvalue(x)
  case x
  when Hash
    [x['value'].to_f, x['currency']]
  else
    [x.to_f / 1000000, 'XRP']
  end
end

def getprices(rpc, sym)
  issuer = rpc.account_id
  params = {
    'taker_gets' => { 'currency' => sym, 'issuer' => issuer },
    'taker_pays' => { 'currency' => 'XRP' },
  }
  2.times.map do |i|
    result = rpc.book_offers(params)
    return nil unless result['status'] == 'success'
    offers = result['offers']
    offer = offers.first
    gs = getvalue(offer['TakerGets'])
    ps = getvalue(offer['TakerPays'])
    price = i == 0 ? ps[0] / gs[0] : gs[0] / ps[0]
    ps = params['taker_pays']
    params['taker_pays'] = params['taker_gets']
    params['taker_gets'] = ps
    price
  end
end

def main
  rrpc = getripplerpc
  interval = 60
  min = @@redis.get('polling:ledger') || "-1"
  min = min.to_i
  loop do
    begin
      rprices = @@redis.getm('polling:prices') || {}
      coins = @@config['coins']
      coins.each do |k,v|
        sym = v['symbol']
        prices = getprices(rrpc, sym)
        rprices[sym.to_sym] = { :bid => prices[1], :ask => prices[0] }
      end
      @@redis.setm('polling:prices', rprices)
      min = poll(rrpc, interval, min)
    rescue => x
p :error, x
      sleep interval
    end
  end
end

main
