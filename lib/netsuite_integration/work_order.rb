module NetsuiteIntegration
  class WorkOrder
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def messages
      @messages ||= work_orders
    end

    def last_modified_date
      collection.last.last_modified_date.utc + 1.second
    end

    def collection
      @collection ||= Services::WorkOrder.new(@config).latest
    end

    def work_orders
      collection.map do |po|
        {
          id: 'wo' + po.tran_id.to_s,
          name: po.memo,
          channel: 'NetSuite',
          alt_po_number: po.internal_id,
          orderdate: po.created_date,
          status: po.status,
          vendor: {
            name: po.subsidiary.attributes[:name]
          },
          location: {
            name: po.location.attributes[:name],
            external_id: po.location.external_id,
            internal_id: po.location.internal_id
          },
          line_items:[ {
            itemno: po.assembly_item.attributes[:name],
            internal_id: po.assembly_item.internal_id,
            description: nil,
            quantity: po.quantity,
            unit_price: 0,
            vendor: {
              name: po.subsidiary.attributes[:name]
            },
            location: {
              name: po.location.attributes[:name]
            }
          }] }
      end
    end

  end
end