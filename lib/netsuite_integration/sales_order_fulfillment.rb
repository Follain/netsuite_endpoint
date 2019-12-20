module NetsuiteIntegration
    class SalesOrderfulfillment < Base
      attr_reader :config, :payload, :salesorder_payload, :salesorder, :fulfillment

      def initialize(config, payload = {})
        super(config, payload)
        @config = config
        @salesorder_payload = payload[:shipment]
        @salesorder = find_salesorder_by_ext_id(salesorder_id)
        if pending_fulfillment?
          create_fulfillment
        end
      end

      def pending_fulfillment?
        @salesorder&.order_status
                 &.in?(%w(_pendingFulfillment _pendingReceiptPartFulfilled)) ||
        @salesorder&.order_status.nil?
      end

      def new_fulfillment?
        new_fulfillment = !find_fulfillment_by_ext_id(salesorder_id + '-' + tracking_number)
      end

      def fulfillment_date
        #salesorder_payload['shipped_at']
        DateTime.now.to_s(:iso8601)
      end

      def salesorder_id
        salesorder_payload['salesorder_id']
      end

      def tracking_number
        salesorder_payload['tracking'].to_s
      end

      def package_desc
        salesorder_payload['carrier'] + '-' + salesorder_payload['service_level']
      end

      def location_id
        salesorder_payload['location_d']
      end

      def build_fulfillment_item_list
        # NetSuite will through an error when you dont return all items back
        # in the fulfillment request so we just set the quantity to 0 here
        # for those not present in the shipment payload
        fulfillment.item_list.items.each do |fulfillment_item|
          item = salesorder_payload[:line_items].find do |i|
            i[:sku] == fulfillment_item.item.name.split(' ')[0]
          end
          fulfillment_item.location = {internal_id: salesorder_payload[:location_id]}

            if item && quantity_remaining !=0
              fulfillment_item.quantity=item[:quantity]
              else
                if fulfillment_item.item.name.include?("giftcard")
                   fulfillment_item.quantity=quantity_remaining
                else
                    0
                end
              end
        end
      end

      def build_fulfillment_package_list
        package=NetSuite::Records::ItemFulfillmentPackage.new(package_tracking_number:tracking_number,package_weight:1, package_descr: package_desc)
        NetSuite::Records::ItemFulfillmentPackageList.new(package: package)
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

      def find_salesorder_by_ext_id(id)
        NetSuite::Records::SalesOrder.get(external_id: id)
        # Silence the error
        # We don't care that the record was not found
      rescue NetSuite::RecordNotFound
      end

      def create_fulfillment
        if new_fulfillment? &&
           pending_fulfillment?
          @fulfillment = NetSuite::Records::ItemFulfillment.initialize @salesorder
          fulfillment.external_id = salesorder_id+tracking_number
          fulfillment.memo = 'QL Shipment'
          fulfillment.tran_date = NetSuite::Utilities.normalize_time_to_netsuite_date(fulfillment_date.to_datetime)
          build_fulfillment_item_list
          fulfillment.package_list=build_fulfillment_package_list

          fulfillment.add

          if fulfillment.errors.any? { |e| e.type != 'WARN' }
            raise "Fullfilment create failed: #{fulfillment.errors.map(&:message)}"
          else
            line_item = { salesorder_id: salesorder_id,
                          netsuite_tran_id: salesorder.internal_id,
                          description: 'QL Shipment',
                          type: 'shipment' }
            ExternalReference.record :shipment, salesorder_id,
                                     { netsuite: line_item },
                                     netsuite_id: fulfillment.internal_id
          end
        end
      end
    end
  end