module NetsuiteIntegration
  class MaintainInventoryItem < Base
    attr_reader :config, :payload, :ns_inventoryitem, :inventoryitem_payload, :item

    def initialize(config, payload = {})
      super(config, payload)
      @config = config

      @inventoryitem_payload = payload[:product]

      # always find sku using internal id incase of sku rename
      item = if !nsproduct_id.nil?
               inventory_item_service.find_by_internal_id(nsproduct_id)
             else
               inventory_item_service.find_by_item_id_all(sku)
             end

      # awlays keep external_id in numeric format
      ext_id = if sku.is_a? Numeric
                 sku.to_i
               else
                 sku
               end

      if !item.present?
        item = NetSuite::Records::InventoryItem.new(
          item_id: sku,
          external_id: ext_id,
          # causes too many issuses !! display_name: description[0,40],
          tax_schedule: { internal_id: taxschedule },
          upc_code: sku,
          vendor_name: description[0, 60],
          purchase_description: description,
          stock_description: description[0, 21]
        )
        item.add
      elsif item.record_type.include?('InventoryItem') && item.is_inactive==false
            item.update(
              item_id: sku,
              external_id: ext_id,
              # dont use causes too many process issuses !! display_name: description[0,40],
              tax_schedule: { internal_id: taxschedule },
              upc_code: sku,
              vendor_name: description[0, 60],
              purchase_description: description,
              stock_description: description[0, 21]
            )
      end

      if item.errors.present? { |e| e.type != 'WARN' }
        raise "Item Update/create failed: #{item.errors.map(&:message)}"
      else
        line_item = { sku: sku, netsuite_id: item.internal_id,
                      description: description }
        ExternalReference.record :product, sku, { netsuite: line_item },
                                 netsuite_id: item.internal_id
      end
    end

    def sku
     inventoryitem_payload['sku']
    end

    def taxschedule
      inventoryitem_payload['tax_type']
    end

    def description
      inventoryitem_payload['description']
    end

    def nsproduct_id
      inventoryitem_payload['nsproduct_id']
    end

    def inventory_item_service
      @inventory_item_service ||= NetsuiteIntegration::Services::InventoryItem
                                  .new(@config)
    end
  end
end
