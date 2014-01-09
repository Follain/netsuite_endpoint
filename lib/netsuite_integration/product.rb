module NetsuiteIntegration
  class Product
    attr_reader :config, :collection

    def initialize(config)
      @config = config
      @collection = NetsuiteIntegration::Services::InventoryItem.new(@config).latest
    end

    def messages
      collection.map do |item|
        {
          product: {
            name: item.store_display_name,
            available_on: Time.now,
            description: item.store_description,
            sku: item.item_id,
            external_ref: "",
            price: item.cost,
            cost_price: item.cost,
            url: ""
          }
        }
      end
    end

    def last_modified_date
      collection.last.last_modified_date
    end
  end
end