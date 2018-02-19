module NetsuiteIntegration
  class PurchaseOrderReceipt < Base
    attr_reader :config, :payload, :ns_order, :order_payload, :receipt

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @over_receipt = false
      @items_to_receive = false
      @order_payload = payload[:purchase_order]

      # do not process duplicate receipts
      return unless new_receipt?

      update_po_overreceipt(ns_order)

      @receipt = NetSuite::Records::ItemReceipt.initialize ns_order
      receipt.external_id = receipt_id
      receipt.memo = receipt_memo
      receipt.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(received_date.to_datetime)
      build_item_list

      # add new receipt after updating the po
      # exit if there are no receipts/qty else ns will throw error ns requires at least 1 item
      return unless @items_to_receive

      receipt.add
      if receipt.errors.any? { |e| e.type != 'WARN' }
        raise "Receipt create failed: #{receipt.errors.map(&:message)}"
      end
    end

    def new_receipt?
      @new_receipt ||= !find_rec_by_external_id(receipt_id)
    end

    def ns_order
      @ns_order = NetSuite::Records::PurchaseOrder.get(ns_id)
    end

    def find_rec_by_external_id(receipt_id)
      NetSuite::Records::ItemReceipt.get(external_id: receipt_id)
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
      @receipt_id ||= order_payload['receipt_id']
    end

    def ns_id
      @ns_id ||= order_payload['id']
    end

    def received_date
      @received_date ||= order_payload['received_date']
    end

    def receipt_memo
      @receipt_memo ||= order_payload['receipt_memo']
    end

    def touch_item(obj)
      #touch item so top level is update for stitch
      item = NetSuite::Records::InventoryItem.new(
        item_id: obj.item.internal_id
      )
      item.update
    end

    def build_item_list
      # NetSuite will throw an error when you dont return all items back
      # in the fulfillment request so we just set the quantity to 0 here
      # for those not present in the shipment payload
      @receipt.item_list.items.each do |receipt_item|
        item = order_payload[:line_items].find do |i|
          i[:sku] == receipt_item.item.name
        end

        #required for stitch
        touch_item(receipt_item)

        if item && item[:received].to_i > 0
          receipt_item.quantity = item[:received].to_i
          receipt_item.item_receive = true
          @items_to_receive = true

          if receipt_item.location.internal_id.nil?
            receipt_item.location = find_location_by_internal_id(item[:location])
          end

        else
          receipt_item.quantity = 0
          receipt_item.item_receive = false
        end
      end
    end

    def update_po_overreceipt(ns_order)
      ns_order.item_list.items.each do |order_item|
        item = order_payload[:line_items].find { |i| i[:sku] == order_item.item.name }
        next unless item
        # reopen po if it has been closed by mistake!
        # closed status must be 'F' not false ... ns inconsistency
        if order_item.is_closed
          order_item.is_closed = 'F'
          @over_receipt = true
        end
        # check for over receipts!
        next unless (order_item.quantity.to_i - order_item.quantity_received.to_i) < item[:received].to_i
        # first overreceipt works free of charge no update required!
        next unless order_item.quantity_received.to_i != 0
        @over_receipt = true
        order_item.quantity =
          (order_item.quantity_received.to_i + item[:received].to_i)
      end

      # Update po

      if @over_receipt
        attributes = ns_order.attributes
        attributes[:item_list].items.each do |item|
          item.attributes = item.attributes.slice(:line, :quantity, :is_closed)
        end
        ns_order.update(item_list: attributes[:item_list])
        if ns_order.errors.any? { |e| e.type != 'WARN' }
          raise "PO over receipt update failed (business error): #{ns_order.errors.map(&:message)}"
        end
      end
    end
  end
end