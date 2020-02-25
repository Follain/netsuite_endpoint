module NetsuiteIntegration
  class MaintainInventoryVariants < Base
      attr_reader :config, :payload, :ns_inventoryitem, :inventoryitem_payload

      def initialize(config, payload = {})
        super(config, payload)
        @config = config

        @inventoryitem_payload = payload[:product]
        @errors=[]
        inventoryitem_payload['variants'].map do |line_item|
          if line_item['changed']
              add_sku(line_item)
          end
        end
        if @errors.present?
          raise "update/create errors #{@errors.first}"
        end
      end

      def add_sku(line_item)
        sku=line_item['sku']
        taxschedule=line_item['tax_type']
        description=line_item['name']
        ns_id=line_item['ns_id']
        cost=line_item['cost_price']
        image=line_item['image']

        # awlays keep external_id in numeric format
        ext_id = if sku.is_a? Numeric
                   sku.to_i
                 else
                   sku
                 end

        # always find sku using internal id incase of sku rename
        if !ns_id.nil?
            item=inventory_item_service.find_by_internal_id(ns_id)
        end
        # check again conversion issues
        if !item.present?
          item=inventory_item_service.find_by_item_id_all(sku)
        end

        # exit if no changes limit tye amout of nestuite calls/changes
        stock_desc=description.rstrip[0,21]

        if !item.present?
          item = NetSuite::Records::InventoryItem.new(item_id: sku,
                     external_id: ext_id,
                     tax_schedule: { internal_id: taxschedule },
                     upc_code: sku,
                     cost: cost,
                     last_purchase_price: cost,
                     vendor_name: description[0, 60],
                     purchase_description: description,
                     sales_description: description,
                     stock_description: stock_desc,
                     custom_field_list: {custom_field:{reference_id_type:'script_id',
                                          script_id:'custitemmg_thumbnail_url',
                                          internal_id:88,
                                          type:'platformCore:StringCustomFieldRef'},
                                          value:image}

                     )
          item.add
          else
          ns_image =if item.custom_field_list.respond_to?(:custitemmg_thumbnail_url)
            item.custom_field_list.custitemmg_thumbnail_url.value end

            if   (description[0, 60]!=item.vendor_name ||
              sku!=item.item_id ||
              ns_id!=item.internal_id ||
              ns_image!=image )
              cfl=item.custom_field_list
              cfl.custitemmg_thumbnail_url={internal_id:88}
              cfl.custitemmg_thumbnail_url=image
              #ignore assemblies
              if item.record_type.include?('InventoryItem') &&
                item.is_inactive==false &&
                item.member_list.item_member.empty?
                item.update(item_id: sku,
                  external_id: ext_id,
                  tax_schedule: { internal_id: taxschedule },
                  upc_code: sku,
                  cost: item.cost||cost,
                  vendor_name: description[0, 60],
                  purchase_description: description,
                  sales_description: description,
                  stock_description: stock_desc,
                  custom_field_list: cfl
                )
              end
            end
        end

        if item.errors.present? { |e| e.type != 'WARN' }
          if !item.errors.map(&:message).first.include?('Uniqu')
            @errors<< "Item Update/create failed: #{item.errors.map(&:message)}"
          end
        else
          line_item = { sku: sku, netsuite_id: item.internal_id,
                        description: description ,image: image, cost: cost}
          ExternalReference.record :product, sku, { netsuite: line_item },
                                   netsuite_id: item.internal_id
        end
    end

    def inventory_item_service
      @inventory_item_service ||= NetsuiteIntegration::Services::InventoryItem
                                  .new(@config)
    end
  end
end