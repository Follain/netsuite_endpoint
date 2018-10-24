module NetsuiteIntegration
    class Inventory
      attr_reader :config, :collection,:pages

      def initialize(config)
        @config = config
        @collection=[]
        @pages = Services::InventoryItem.new(@config).search_all
      end

      def messages
        @messages ||= inventory_items
      end

      def last_modified_date
        collection.last.last_modified_date.utc + 1.second
      end

      def inventory_items
        pages.results_in_batches do |batch| batch.each do | item| collection << item end end

        @inventory_items ||= collection.select { |item| item.item_id.present? && item.is_inactive==false}
        @inventory_items.map do |item|
          {
            id: item.item_id,
            channel: "NetSuite",
            name: item.vendor_name,
            description: item.purchase_description,
            sku: item.item_id,
            internal_id: item.internal_id,
            locations: inventory(item.locations_list.locations)
          }
        end
      end

      def inventory(item)
        inventory= item.map do |item|
          {location:item[:location],
          internal_id: item[:location_id][:@internal_id].to_i,
          quantity_available: item[:quantity_available].to_i}
      end
    end
  end
end