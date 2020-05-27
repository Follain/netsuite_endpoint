# frozen_string_literal: true

module NetsuiteIntegration
  class MaintainTransferOrder < Base
    attr_reader :config, :payload, :transfer_payload, :transfer, :fulfillment, :receipt, :invtransfer

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @transfer_payload = payload[:transfer_order]
      @transfer = find_transfer_by_tran_id(transfer_name)
      if new_transfer?
        raise "Error transfer missing in Netsuite, please add #{transfer_name}!!" end

      if transfer_closed? && received?
        not_pending_over_receipts
        create_over_receipt_invtransfer
      elsif sent?
        create_transfer
        create_fulfillment
      elsif received?
        # catch all incase vend sequence gets mixed up
        create_transfer
        create_fulfillment
        create_receipt
      end
    end

    def pending_receipt?
      @transfer&.order_status
               &.in?(%w[_pendingReceipt _pendingReceiptPartFulfilled])
    end

    def pending_fulfillment?
      @transfer&.order_status
               &.in?(%w[_pendingFulfillment _pendingReceiptPartFulfilled]) ||
        @transfer&.order_status.nil?
    end

    def transfer_closed?
      @transfer&.order_status&.in?(%w[_closed])
    end

    def new_transfer?
      @transfer.present?
    end

    def new_fulfillment?
      !find_fulfillment_by_ext_id(transfer_name + 'SENT')
    end

    def new_receipt?
      !find_receipt_by_ext_id(transfer_id)
    end

    def sent?
      transfer_payload['transfer_status'] == 'SENT'
    end

    def received?
      transfer_payload['transfer_status'] == 'RECEIVED'
    end

    def transfer_date
      transfer_payload['transfer_date']
    end

    def transfer_memo
      transfer_payload['transfer_memo']
    end

    def transfer_name
      transfer_payload['transfer_name']
    end

    def transfer_id
      transfer_payload['transfer_id']
    end

    def transfer_location
      transfer_payload['location']
    end

    def transfer_source_location
      transfer_payload['source_location']
    end

    def build_transfer_item_list
      line = 0
      transfer_items = transfer_payload[:line_items].map do |item|
        # do not process zero qty transfers
        next unless item[:quantity].to_i != 0

        line += 1

        # fix correct reference else abort if sku not found!
        sku = item[:sku]
        invitem = inventory_item_service.find_by_item_id(sku)
        if invitem.present?
          nsproduct_id = invitem.internal_id
          line_obj = { sku: sku, netsuite_id: invitem.internal_id,
                       description: invitem.purchase_description }
          ExternalReference.record :product, sku, { netsuite: line_obj },
                                   netsuite_id: invitem.internal_id
        else
          raise "Error Item/sku missing in Netsuite, please add #{sku}!!"
        end

        NetSuite::Records::TransferOrderItem.new(item: { internal_id: nsproduct_id },
                                                 rate: item_cost(invitem, transfer_source_location),
                                                 line: line,
                                                 quantity: item[:quantity])
      end
      NetSuite::Records::TransferOrderItemList.new(replace_all: true,
                                                   item: transfer_items.compact)
    end

    def not_pending_over_receipts
      transfer_payload[:line_items].each do |i|
        @over_receipt_items << { sku: i[:sku],
                                 received: i[:received],
                                 nsproduct_id: i[:nsproduct_id] }
      end
    end

    def build_receipt_item_list
      # NetSuite will through an error when you dont return all items back
      # in the fulfillment request so we just set the quantity to 0 here
      # for those not present in the shipment payload
      @receipt.item_list.items.each do |receipt_item|
        item = transfer_payload[:line_items].find do |i|
          i[:sku] == receipt_item.item.name.split(' ')[0]
        end

        if item
          # issue netsuite does not allow over receipts, infact it just ignores them !!!
          # capture themn and issue another transfer for the balance
          over_receipt = (receipt_item.quantity_remaining.to_i - item[:received].to_i) * -1
          if over_receipt > 0
            @over_receipt_items << { sku: receipt_item.item.name.split(' ')[0],
                                     received: over_receipt,
                                     nsproduct_id: receipt_item.item.internal_id }
          end
          receipt_item.quantity = item[:received]
          receipt_item.item_receive = true
          if receipt_item.location.internal_id.nil?
            receipt_item.location = { internal_id: transfer_location }
          end
        else
          receipt_item.quantity = 0
          receipt_item.item_receive = false
        end
      end
    end

    def build_fulfillment_item_list
      # NetSuite will through an error when you dont return all items back
      # in the fulfillment request so we just set the quantity to 0 here
      # for those not present in the shipment payload
      fulfillment.item_list.items.each do |fulfillment_item|
        item = transfer_payload[:line_items].find do |i|
          i[:sku] == fulfillment_item.item.name.split(' ')[0]
        end

        fulfillment_item.quantity = if item
                                      item[:quantity]
                                    else
                                      0
                                    end
      end
    end

    def inventory_item_service
      @inventory_item_service ||= NetsuiteIntegration::Services::InventoryItem.new(@config)
    end

    def find_fulfillment_by_ext_id(id)
      NetSuite::Records::ItemFulfillment.get(external_id: id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def find_transfer_by_ext_id(id)
      NetSuite::Records::TransferOrder.get(external_id: id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def find_transfer_by_tran_id(tran_id)
      NetSuite::Records::TransferOrder.search({
                                                criteria: {
                                                  basic: {
                                                    field: 'tranId',
                                                    operator: 'equalTo',
                                                    value: tran_id
                                                  }
                                                }
                                              }).results.first
    end

    def find_receipt_by_ext_id(id)
      NetSuite::Records::ItemReceipt.get(external_id: id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def create_fulfillment
      status = 'SENT'
      if new_fulfillment? &&
         pending_fulfillment?
        @fulfillment = NetSuite::Records::ItemFulfillment.initialize @transfer
        fulfillment.external_id = transfer_name + status
        fulfillment.memo = transfer_memo
        fulfillment.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(transfer_date.to_datetime)
        build_fulfillment_item_list

        fulfillment.add

        if fulfillment.errors.any? { |e| e.type != 'WARN' }
          raise "Fullfilment create failed: #{fulfillment.errors.map(&:message)}"
        else
          line_item = { transfer_name: transfer_name,
                        netsuite_tran_id: transfer.internal_id,
                        description: transfer_memo,
                        type: 'transfer_order' }
          ExternalReference.record :transfer_order, transfer_name + status,
                                   { netsuite: line_item },
                                   netsuite_id: fulfillment.internal_id
        end
      end
    end

    def create_receipt
      @over_receipt_items = []
      status = 'RECEIVED'
      if new_receipt?
        if pending_receipt?
          @receipt = NetSuite::Records::ItemReceipt.initialize @transfer
          receipt.external_id = transfer_id
          receipt.memo = transfer_memo
          receipt.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(transfer_date.to_datetime)
          build_receipt_item_list

          receipt.add

          if receipt.errors.any? { |e| e.type != 'WARN' }
            raise "Receipt create failed: #{receipt.errors.map(&:message)}"
          else
            line_item = { transfer_name: transfer_name,
                          netsuite_tran_id: @transfer.internal_id,
                          description: transfer_memo,
                          type: 'transfer_order' }
            ExternalReference.record :transfer_order, transfer_name + status,
                                     { netsuite: line_item },
                                     netsuite_id: receipt.internal_id
          end
        else
          not_pending_over_receipts
        end
        create_over_receipt_invtransfer
      end
    end

    def create_over_receipt_invtransfer
      if @over_receipt_items.any?
        @invtransfer = NetSuite::Records::InventoryTransfer.new
        invtransfer.external_id = transfer_id + 'OVER'
        invtransfer.memo = transfer_memo + ' Over Receipt'
        invtransfer.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(transfer_date.to_datetime)

        invtransfer.location = { internal_id: transfer_source_location }
        invtransfer.transfer_location = { internal_id: transfer_location }
        invtransfer.inventory_list = build_over_receipt_item_list
        # we can sometimes receive transfers were everything is zero!
        if invtransfer.inventory_list.inventory.present?
          invtransfer.add
          if invtransfer.errors.any? { |e| e.type != 'WARN' }
            raise "Inv Tranfer(over rec) create failed: #{invtransfer.errors.map(&:message)}"
          else
            line_item = { transfer_id: transfer_id,
                          netsuite_id: invtransfer.internal_id,
                          description: transfer_memo,
                          type: 'transfer_order' }
            ExternalReference.record :transfer_order, transfer_id,
                                     { netsuite: line_item },
                                     netsuite_id: invtransfer.internal_id
          end
        end
      end
    end

    def build_over_receipt_item_list
      line = 0
      invtransfer_items = @over_receipt_items.map do |item|
        # do not process zero qty transfers
        next unless item[:received].to_i != 0

        line += 1
        # fix correct reference else abort if sku not found!
        sku = item[:sku]
        invitem = inventory_item_service.find_by_item_id(sku)
        if invitem.present?
          nsproduct_id = invitem.internal_id
          line_obj = { sku: sku, netsuite_id: invitem.internal_id,
                       description: invitem.purchase_description }
          ExternalReference.record :product, sku, { netsuite: line_obj },
                                   netsuite_id: invitem.internal_id
        else
          raise "Error Item/sku missing in Netsuite, please add #{sku}!!"
        end
        NetSuite::Records::InventoryTransferInventory.new(item: { internal_id: nsproduct_id },
                                                          line: line,
                                                          adjust_qty_by: item[:received])
      end
      NetSuite::Records::InventoryTransferInventoryList.new(replace_all: true,
                                                            inventory: invtransfer_items.compact)
    end

    def item_cost(invitem, location)
      itemlocation = invitem
                     .locations_list.locations
                     .select { |e| e[:location_id][:@internal_id] == location.to_s }
                     .first

      if itemlocation[:average_cost_mli].to_f != 0
        itemlocation[:average_cost_mli].to_f
      elsif invitem.average_cost != 0
        invitem.average_cost
      elsif itemlocation[:last_purchase_price_mli].to_f != 0
        itemlocation[:last_purchase_price_mli].to_f
      elsif invitem.last_purchase_price != 0
        invitem.last_purchase_price
      end
    end

    def create_transfer
      if new_transfer?
        @transfer = NetSuite::Records::TransferOrder.new
        transfer.external_id = transfer_name
        transfer.memo = transfer_memo
        # if set to yes u cnat do partial receipts!! ... but now we have to manage the cost ourselves
        transfer.use_item_cost_as_transfer_cost = false
        transfer.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(transfer_date.to_datetime)
        transfer.location = { internal_id: transfer_source_location }
        transfer.transfer_location = { internal_id: transfer_location }
        transfer.item_list = build_transfer_item_list
        # we can sometimes receive transfers were everything is zero!
        if transfer.item_list.item.present?
          transfer.add
          if transfer.errors.any? { |e| e.type != 'WARN' }
            raise "Tranfer create failed: #{transfer.errors.map(&:message)}"
          else
            line_item = { transfer_name: transfer_name,
                          netsuite_id: transfer.internal_id,
                          description: transfer_memo,
                          type: 'transfer_order' }
            ExternalReference.record :transfer_order, transfer_name,
                                     { netsuite: line_item },
                                     netsuite_id: transfer.internal_id
          end
        end
      end
    end
  end
end
