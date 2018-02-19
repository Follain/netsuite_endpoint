module NetsuiteIntegration
  class WorkOrderBuild < Base
    attr_reader :config, :payload, :ns_order, :order_payload, :receipt

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @order_payload = payload[:work_order_rec]
      # do not process duplicate receipts
      return unless new_receipt?

      @receipt = if quantity.to_i >= 0
                   NetSuite::Records::AssemblyBuild.initialize ns_order
                 else
                   NetSuite::Records::AssemblyUnBuild.initialize ns_order
                 end

      receipt.external_id = receipt_id
      receipt.memo = receipt_memo
      receipt.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(received_date.to_datetime)
      receipt.quantity = quantity
      build_item_list

      receipt.add

      if receipt.errors.any? { |e| e.type != 'WARN' }
        raise "Work build failed: #{receipt.errors.map(&:message)}"
      end
    end

    def new_receipt?
      @new_receipt ||= !find_rec_by_external_id(receipt_id)
    end

    def ns_order
      @ns_order = NetSuite::Records::WorkOrder.get(ns_id)
    end

    def find_rec_by_external_id(receipt_id)
      NetSuite::Records::AssemblyBuild.get(external_id: receipt_id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def find_location_by_internal_id(location_id)
      NetSuite::Records::Location.get(internal_id: location_id)
    # Silence the error
    # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def receipt_id
      order_payload['receipt_id']
    end

    def ns_id
      order_payload['id']
    end

    def received_date
      order_payload['received_date']
    end

    def receipt_memo
      order_payload['receipt_memo']
    end

    def quantity
      @quantity = order_payload['line_items'].first['received']
    end

    def build_item_list
      # NetSuite will throw an error when you dont return all items back
      # in the fulfillment request so we just set the quantity to 0 here
      # for those not present in the shipment payload
      @receipt.component_list.component.each do |receipt_item|
        receipt_item.quantity = quantity
      end
    end
  end
end
