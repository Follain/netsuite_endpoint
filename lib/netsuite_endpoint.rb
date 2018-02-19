require 'sinatra'
require 'endpoint_base'

require File.expand_path(File.dirname(__FILE__) + '/netsuite_integration')

class NetsuiteEndpoint < EndpointBase::Sinatra::Base
  set :logging, true
  # suppress netsuite warnings
  set :show_exceptions, false

  error Errno::ENOENT, NetSuite::RecordNotFound, NetsuiteIntegration::NonInventoryItemException do
    result 500, env['sinatra.error'].message
  end

  error Savon::SOAPFault do
    result 500, env['sinatra.error'].to_s
  end

  before do
    @config['netsuite_last_updated_after'] ||= Time.at(@payload['last_poll'].to_i).to_s if @payload.present?

    if config = @config
      # https://github.com/wombat/netsuite_integration/pull/27
      # Set connection/flow parameters with environment variables if they aren't already set from the request
      %w[email password account role sandbox api_version wsdl_url silent].each do |env_suffix|
        if ENV["NETSUITE_#{env_suffix.upcase}"].present? && config["netsuite_#{env_suffix}"].nil?
          config["netsuite_#{env_suffix}"] = ENV["NETSUITE_#{env_suffix.upcase}"]
        end
      end

      @netsuite_client ||= NetSuite.configure do
        reset!

        wsdl config['netsuite_wsdl_url'] if config['netsuite_wsdl_url'].present?

        if config['netsuite_api_version'].present?
          api_version config['netsuite_api_version']
        else
          api_version '2013_2'
        end

        if config['netsuite_role'].present?
          role config['netsuite_role']
        else
          role 3
        end

        sandbox config['netsuite_sandbox'].to_s == 'true' || config['netsuite_sandbox'].to_s == '1'

        account      config.fetch('netsuite_account')
        consumer_key config.fetch('netsuite_consumer_key')
        consumer_secret config.fetch('netsuite_consumer_secret')
        token_id config.fetch('netsuite_token_id')
        token_secret config.fetch('netsuite_token_secret')
        wsdl_domain  ENV['NETSUITE_WSDL_DOMAIN'] || 'system.netsuite.com'

        read_timeout 240
        log_level    :info
      end
    end
  end

  def self.fetch_endpoint(path, service_class, key)
    post path do
      service = service_class.new(@config)

      service.messages.each do |message|
        add_object key, message
      end

      if service.collection.any?
        add_parameter 'netsuite_last_updated_after', service.last_modified_date
      else
        add_parameter 'netsuite_last_updated_after', @config['netsuite_last_updated_after']
        add_value key.pluralize, []
      end

      count = service.messages.count
      @summary = "#{count} #{key.pluralize count} found in NetSuite"

      result 200, @summary
    end
  end

  fetch_endpoint '/get_products',
                 NetsuiteIntegration::Product,
                 'product'
  fetch_endpoint '/get_purchase_orders',
                 NetsuiteIntegration::PurchaseOrder,
                 'purchase_order'
  fetch_endpoint '/get_work_orders',
                 NetsuiteIntegration::WorkOrder,
                 'work_order'
  fetch_endpoint '/get_vendors',
                 NetsuiteIntegration::Vendor,
                 'vendor'

  post '/add_inventory_adjustment' do
    NetsuiteIntegration::InventoryAdjustment.new(@config, @payload)
    summary = 'Netsuite Inventory Adjustment Created '
    result 200, summary
  end

  post '/add_inventory_transfer' do
    NetsuiteIntegration::InventoryTransfer.new(@config, @payload)
    summary = 'Netsuite Inventory Transfer Created '
    result 200, summary
  end

  post '/add_purchase_order_receipt' do
    NetsuiteIntegration::PurchaseOrderReceipt.new(@config, @payload)
    summary = 'Netsuite Receipt Created '
    result 200, summary
  end

  post '/add_work_order_build' do
    NetsuiteIntegration::WorkOrderBuild.new(@config, @payload)
    summary = 'Netsuite WorkOrderBuild Created '
    result 200, summary
  end

  post '/add_transfer_order_receipt' do
    NetsuiteIntegration::TransferOrderReceipt.new(@config, @payload)
    summary = 'Netsuite Receipt Created '
    result 200, summary
  end

  post '/maintain_inventory_item' do
    NetsuiteIntegration::MaintainInventoryItem.new(@config, @payload)
    summary = 'Netsuite Item Created/Updated '
    result 200, summary
  end

  post '/add_gl_journal' do
    NetsuiteIntegration::GlJournal.new(@config, @payload)
    summary = 'Netsuite GL Journal Created '
    result 200, summary
  end

end
