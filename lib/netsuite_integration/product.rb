module NetsuiteIntegration
  class Product
    attr_reader :config, :collection

    def initialize(config)
      @config = config
      @collection = Services::InventoryItem.new(@config).latest
    end

    def messages
      @messages ||= standalone_products + matrix_items
    end

    def last_modified_date
      collection.last.last_modified_date.utc + 1.second
    end

    def matrix_children
      @matrix_children ||= collection.select { |item| item.matrix_type == "_child" }
    end

    # TODO what if we still get matrix parents on the collection but not one of
    # child's parent is missing. Make sure every child in collection has its
    # parent present here
    def matrix_parents
      return @matrix_parents if @matrix_parents

      parents = collection.select { |item| item.matrix_type == "_parent" }
      @matrix_parents = if parents.empty? && !matrix_children.empty?
                          matrix_children.map { |child| get_parent_from_list child.parent.internal_id }
                        else
                          parents
                        end
    end

    def standalone_products
      ignore_matrix.map do |item|
        {
          id: item.item_id,
          name: item.store_display_name || item.item_id,
          description: item.sales_description,
          sku: item.item_id,
          price: get_item_base_price(item.pricing_matrix.prices),
          cost_price: item.cost_estimate,
          channel: "NetSuite"
        }
      end
    end

    # Payload expected by spree_endpoint
    #
    #   product: {
    #     ...
    #     variants: [
    #       {
    #        price: 19.99,
    #        sku: "hey_you",
    #        options: [
    #          { "size" => "small" },
    #          { "color" => "black" }
    #        ]
    #       }
    #     ]
    #   }
    #
    # Need to find the parent for each matrix child
    # Once parent is found need to match child matrix_option_list type and
    # value with those present on parent
    def matrix_items
      @matrix_items ||= matrix_parents.map do |item|
        {
          id: item.item_id,
          name: item.store_display_name || item.item_id,
          description: item.sales_description,
          sku: item.item_id,
          price: get_item_base_price(item.pricing_matrix.prices),
          cost_price: item.cost_estimate,
          channel: "NetSuite",
          variants: map_matrix_children(item)
        }
      end
    end

    # Dont send option values with null value
    #
    # [1] pry(#<NetsuiteIntegration::Product>)> options
    #   # not a valid options structure
    #   => [{"Product Color"=>"Lily White"}, {"Product Sizes"=>nil}, {"Size - CM"=>nil}]
    #
    # [2] pry(#<NetsuiteIntegration::Product>)> options.select { |o| o.values.all? }
    #   => [{"Product Color"=>"Lily White"}]
    #
    def map_matrix_children(parent)
      children = matrix_children.select { |item| item.parent.internal_id == parent.internal_id }

      children.map do |child|
        price = get_item_base_price(child.pricing_matrix.prices) || get_item_base_price(parent.pricing_matrix.prices)
        options = child.matrix_option_list.options.map do |option|
          { get_option_name(option.type_id) => get_option_value(option, parent) }
        end

        validated_options = options.select { |o| o.values.all? }.reduce Hash.new, :merge
        
        { price: price, sku: child.item_id, options: validated_options }
      end
    end

    private
      # Need to call +get+ on InventoryItem again so we can grab the option type
      # and value names. The search action doesn't return them
      #
      # Then map the option ids here with the ones found on the product
      #
      # Matrix options come as a somewhat confusing data structure. Note the
      # +value+ key of the CustomField might be either an array or a hash
      #
      #   => [#<NetSuite::Records::CustomField:0x007f8a919803a0
      #     @attributes=
      #      {:value=>
      #        [{:name=>"Turf", :@internal_id=>"1", :@type_id=>"529"},
      #         {:name=>"Cantelope", :@internal_id=>"2", :@type_id=>"529"}],
      #       :@script_id=>"custitem18"},
      #     @internal_id="4627",
      #     @type="platformCore:MultiSelectCustomFieldRef">,
      #     #<NetSuite::Records::CustomField:0x007f8a919802d8
      #     @attributes=
      #      {:value=>{:name=>"Large", :@internal_id=>"3", :@type_id=>"530"},
      #       :@script_id=>"custitem19"},
      #     @internal_id="4629",
      #     @type="platformCore:MultiSelectCustomFieldRef">,
      #
      def get_option_value(option, parent)
        full_parent = get_parent_from_list parent.internal_id

        # Let's assume all custom fields for this type are product options
        custom = full_parent.custom_field_list.custom_fields_by_type "MultiSelectCustomFieldRef"

        values = custom.map do |field|
          if field.value.is_a? Array
            field.value.select do |option_value|
              option_value[:"@type_id"] == option.type_id && option_value[:"@internal_id"] == option.value_id
            end
          elsif field.value.is_a? Hash
            if field.value[:"@type_id"] == option.type_id && field.value[:"@internal_id"] == option.value_id
              field.value
            end
          end
        end.flatten.compact

        values.first[:name] if values.first
      end

      def parents_list
        @parents_list ||= {}
      end

      def get_parent_from_list(parent_id)
        parents_list[parent_id] ||= NetSuite::Records::InventoryItem.get parent_id
      end

      def get_option_name(id)
        option_names[id] ||= NetSuite::Records::CustomRecordType.get(id).record_name
      end

      def option_names
        @option_names ||= {}
      end

      def ignore_matrix
        collection.reject { |item| ["_parent", "_child"].include? item.matrix_type }
      end

      # Crazy NetSuite pricing matrix structure
      #
      #   #<NetSuite::Records::RecordRef:0x007fdb3f1399e0 @internal_id=nil, @external_id=nil, @type=nil,
      #     @attributes={:currency=>{:name=>"USA", :@internal_id=>"1"},
      #         :price_level=>{:name=>"Base Price", :@internal_id=>"1"},
      #         :price_list=>{:price=>{:value=>"9.99", :quantity=>"0.0"}}}>,
      #   #<NetSuite::Records::RecordRef:0x007fdb3f1399b8 @internal_id=nil, @external_id=nil, @type=nil,
      #     @attributes={:currency=>{:name=>"USA", :@internal_id=>"1"},
      #         :price_level=>{:name=>"Online Wholesale Price", :@internal_id=>"6"}, :discount=>"-15.0",
      #         :price_list=>{:price=>{:value=>"8.49", :quantity=>"0.0"}}}>,
      #
      #     ...
      #
      # It can also hold more than one price in the price_list:
      #
      #   #<NetSuite::Records::RecordRef:0x007fdb3f0dbae8 @internal_id=nil, @external_id=nil, @type=nil,
      #     @attributes={:currency=>{:name=>"Euro", :@internal_id=>"4"},
      #       :price_level=>{:name=>"Base Price", :@internal_id=>"1"},
      #       :price_list=>{:price=>[
      #         {:value=>"89.0", :quantity=>"0.0"},
      #         {:value=>"84.0", :quantity=>"10.0"},
      #         {:value=>"79.0", :quantity=>"100.0"}]}}>
      #
      def get_item_base_price(prices)
        if prices.first && prices.first.attributes[:price_list]
          case price = prices.first.attributes[:price_list][:price]
          when Array
            price.first[:value]
          when Hash
            price[:value]
          end
        end
      end
  end
end
