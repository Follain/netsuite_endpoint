# frozen_string_literal: true

module NetsuiteIntegration
  class InventoryAdjustment < Base
    attr_reader :config, :payload, :ns_adjustment, :adjustment_payload, :adjustment

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @adjustment_payload = if transfer_order?
                              payload[:transfer_order]
                            elsif sales_inv_adjustment?
                              payload[:sales_inv_adjustment]
                            else
                              payload[:inventory_adjustment]
                            end

      if adjustment_location.nil?
        raise 'Location Missing!! Sync vend & netsuite outlets'
      end

      create_adjustment
    end

    def new_adjustment?
      new_adjustment ||= !find_adjustment_by_external_id(adjustment_id)
    end

    def ns_adjustment
      @ns_adjustment ||= NetSuite::Records::InventoryAdjustment.get(ns_id)
    end

    def find_adjustment_by_external_id(adjustment_id)
      NetSuite::Records::InventoryAdjustment.get(external_id: adjustment_id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
    end

    def transfer_order?
      payload[:transfer_order].present?
    end

    def register_sale?
      payload[:register_sale].present?
    end

    def sales_inv_adjustment?
      payload[:sales_inv_adjustment].present?
    end

    def adjustment_id
      @adjustment_id ||= adjustment_payload['adjustment_id']
    end

    def ns_id
      @ns_id ||= adjustment_payload['id']
    end

    def adjustment_date
      @adjustment_date ||= adjustment_payload['adjustment_date']
    end

    def adjustment_account
      @adjustment_account ||= adjustment_payload['adjustment_account_number']
    end

    def adjustment_dept
      @adjustment_dept ||= adjustment_payload['adjustment_dept']
    end

    def adjustment_memo
      @adjustment_memo ||= adjustment_payload['adjustment_memo']
    end

    def adjustment_identifier
      @adjustment_identifier ||= adjustment_payload['adjustment_identifier']
    end

    def adjustment_location
      @adjustment_location ||= adjustment_payload['location']
    end

    def build_item_list
      line = 0
      adjustment_items = adjustment_payload[:line_items].map do |item|
        # do not process zero qty adjustments
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
        else
          invitem = find_sku_by_internal_id(nsproduct_id)
        end
        # rework for performance at somepoint no need to get inv item if qty <0
        # check average price and fill it in ..ns has habit of Zeroing it out when u hit zero quantity
        itemlocation = invitem.locations_list.locations.select { |e| e[:location_id][:@internal_id] == adjustment_location.to_s }.first
        if itemlocation[:average_cost_mli].to_i == 0 &&
           item[:quantity].to_i > 0
          # can only set unit price on takeon
          if itemlocation[:last_purchase_price_mli].to_i != 0
            unit_cost = itemlocation[:last_purchase_price_mli]
          elsif invitem.last_purchase_price.to_i != 0
            unit_cost = invitem.last_purchase_price
          elsif item[:cost].present?
            unit_cost = item[:cost]
           end
          # set default unit_price if none
          NetSuite::Records::InventoryAdjustmentInventory.new(item: { internal_id: nsproduct_id },
                                                              line: line,
                                                              unit_cost: unit_cost.to_i,
                                                              adjust_qty_by: item[:quantity],
                                                              location: { internal_id: adjustment_location })
        else
          NetSuite::Records::InventoryAdjustmentInventory.new(item: { internal_id: nsproduct_id },
                                                              line: line,
                                                              adjust_qty_by: item[:quantity],
                                                              location: { internal_id: adjustment_location })
        end
      end
      NetSuite::Records::InventoryAdjustmentInventoryList.new(replace_all: true,
                                                              inventory: adjustment_items.compact)
    end

    def inventory_item_service
      @inventory_item_service ||= NetsuiteIntegration::Services::InventoryItem.new(@config)
    end

    def find_sku_by_internal_id(id)
      #flip flop between inventory Items and assembly items ... assembly is less frequent
       NetSuite::Records::InventoryItem.get(id)
      # Silence the error
      # We don't care that the record was not found
    rescue NetSuite::RecordNotFound
      NetSuite::Records::AssemblyItem.get(id)
    rescue NetSuite::RecordNotFound
    end

    def create_adjustment
      if new_adjustment?
        # internal numbers differ between platforms
        if adjustment_account.blank?
          raise "GL Account: #{adjustment_account} not found!"
        end

        if adjustment_dept.blank?
          raise "GL Department: #{adjustment_dept} not found!"
        end

        @adjustment = NetSuite::Records::InventoryAdjustment.new
        adjustment.external_id = adjustment_id
        adjustment.memo = adjustment_memo
        adjustment.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(adjustment_date.to_datetime)

        adjustment.account = { internal_id: adjustment_account }
        if adjustment_dept.present?
          adjustment.department = { internal_id: adjustment_dept }
        end
        adjustment.adj_location = { internal_id: adjustment_location }
        adjustment.inventory_list = build_item_list
        # we can sometimes receive adjustments were everything is zero!
        if adjustment.inventory_list.inventory.present?
          adjustment.add
          if adjustment.errors.any? { |e| e.type != 'WARN' }
            raise "Adjustment create failed: #{adjustment.errors.map(&:message)}"
          else
            line_item = { adjustment_id: adjustment_id,
                          netsuite_id: adjustment.internal_id,
                          description: adjustment_memo,
                          type: 'Adjustment' }
            if transfer_order?
              ExternalReference.record :transfer_order, adjustment_id,
                                       { netsuite: line_item },
                                       netsuite_id: adjustment.internal_id
            elsif sales_inv_adjustment?
              ExternalReference.record :sales_inv_adjustment,
                                       adjustment_identifier,
                                       { netsuite: line_item },
                                       netsuite_id: adjustment.internal_id
            else
              ExternalReference.record :inventory_adjustment,
                                       adjustment_id,
                                       { netsuite: line_item },
                                       netsuite_id: adjustment.internal_id
            end
          end
        end
      end
    end
  end
end
