module NetsuiteIntegration
  class InventoryTransfer < Base
    attr_reader :config, :payload, :ns_transfer, :transfer_payload, :transfer

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @transfer_payload = payload[:transfer_order]
      create_transfer
    end

    def new_transfer?
      !find_transfer_by_external_id(transfer_id)
    end

    def ns_transfer
      @ns_transfer ||= NetSuite::Records::InventoryTransfer.get(ns_id)
    end

    def find_transfer_by_external_id(transfer_id)
      NetSuite::Records::InventoryTransfer.get(external_id: transfer_id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def transfer_id
      @transfer_id ||= transfer_payload['transfer_id']
    end

    def ns_id
      @ns_id ||= transfer_payload['id']
    end

    def transfer_date
      @transfer_date ||= transfer_payload['transfer_date']
    end

    def transfer_memo
      @transfer_memo ||= transfer_payload['transfer_memo']
    end

    def transfer_identifier
      @transfer_identifier ||= transfer_payload['transfer_identifier']
    end

    def transfer_location
      @transfer_location ||= transfer_payload['location']
    end

    def transfer_source_location
      @transfer_source_location ||= transfer_payload['source_location']
    end

    def build_item_list
      line = 0
      transfer_items = transfer_payload[:line_items].map do |item|
        # do not process zero qty transfers
        next unless item[:quantity].to_i != 0
        line += 1
        nsproduct_id = item[:nsproduct_id]

        if nsproduct_id.nil?
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
        end
        NetSuite::Records::InventoryTransferInventory.new(item: { internal_id: nsproduct_id },
                                                          line: line,
                                                          adjust_qty_by: item[:quantity])
      end
      NetSuite::Records::InventoryTransferInventoryList.new(replace_all: true,
                                                            inventory: transfer_items.compact)
    end

    def inventory_item_service
      @inventory_item_service ||= NetsuiteIntegration::Services::InventoryItem.new(@config)
    end

    def create_transfer
      if new_transfer?
        @transfer = NetSuite::Records::InventoryTransfer.new
        transfer.external_id = transfer_id
        transfer.memo = transfer_memo
        transfer.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(transfer_date.to_datetime)

        transfer.location = { internal_id: transfer_source_location }
        transfer.transfer_location = { internal_id: transfer_location }
        transfer.inventory_list = build_item_list
        # we can sometimes receive transfers were everything is zero!
        if transfer.inventory_list.inventory.present?
          transfer.add
          if transfer.errors.any? { |e| e.type != 'WARN' }
            raise "Tranfer create failed: #{transfer.errors.map(&:message)}"
          else
            line_item = { transfer_id: transfer_id,
                          netsuite_id: transfer.internal_id,
                          description: transfer_memo,
                          type: 'transfer_order' }
            ExternalReference.record :transfer_order, transfer_id,
                                     { netsuite: line_item },
                                     netsuite_id: transfer.internal_id
          end
        end
      end
    end
  end
end
