module NetsuiteIntegration
  class TransferOrder
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def messages
      @messages ||= transfer_orders
    end

    def last_modified_date
      collection.last.last_modified_date.utc + 1.second
    end

    def collection
      @collection ||= Services::TransferOrder.new(@config).latest
    end

    def transfer_orders

      collection.map do |po|
        {
          id: po.tran_id,
          name: po.memo,
          alt_po_number: po.internal_id,
          orderdate: po.created_date,
          status: po.status,
          type: 'TRANSFER',
          source_location: {
            name: po.location.attributes[:name],
            external_id: po.location.external_id,
            internal_id: po.location.internal_id
          },
          vendor: {},
          location: {
            name: po.transfer_location.attributes[:name],
            external_id: po.transfer_location.external_id,
            internal_id: po.transfer_location.internal_id
          },
          line_items: items(po),
          channel: 'NetSuite'
        }
      end
    end

    def items(po)
      po.item_list.item.each_with_index.map do |item, index|
        {
          itemno: item.item.attributes[:name],
          internal_id: item.item.internal_id,
          description: item.description,
          quantity: item.quantity,
          vendor: {},
          location: {}
        }
      end
    end
  end
end
