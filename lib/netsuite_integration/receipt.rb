# frozen_string_literal: true

module NetsuiteIntegration
  class Receipt < Base
    attr_reader :config, :payload, :purchase_order, :nspo

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @purchase_order = payload[:purchase_order]
      @po_search = find_po_by_tran_id(payload['po_id'])
      internal_id = @po_search.internal_id
      @nspo = NetSuite::Records::PurchaseOrder.get(internal_id: internal_id)
      r = NetSuite::Records::ItemReceipt.new
      r.external_id  = purchase_order['line_items'].first['consignment_id'] + Time.new.to_s
      r.created_from = @nspo
      r.item_list = build_item_list
      r.add
      if r.errors.any? { |e| e.type != 'WARN' }
        # p.errors.first.type
        raise "Receipt create failed: #{r.errors.map(&:message)}"
      end
      # fail 'ciao'
    end

    def build_item_list
      # purchase_order = payload[:purchase_order]
      updatepo = false

      purchase_order_items = purchase_order[:line_items].map do |item|
        # check if item on PO
        unless nspoitem = @nspo.item_list.item.find { |x| x.item.name == item[:sku] }
          raise "Item \"#{item[:sku]}\" not found on PO"
        end

        # check po quantity
        updateline = nspoitem.quantity_received.to_i != 0 && (nspoitem.quantity.to_i - nspoitem.quantity_received.to_i) < item[:received].to_i
        if updateline
          updatepo ||= true
          nspoitem.quantity = (nspoitem.quantity_received.to_i + item[:received].to_i).to_s
        end

        # check for zero quantity receipts
        receipt_status = item[:received].to_i != 0

        NetSuite::Records::ItemReceiptItem.new({
                                                 item: { internal_id: nspoitem.item.internal_id },
                                                 order_line: item[:sequence_number] + 1,
                                                 item_receive: receipt_status,
                                                 quantity: item[:received]
                                               })
      end
      NetSuite::Records::ItemReceiptItemList.new(replace_all: true, item: purchase_order_items)

      # Update Po qty if over receipt
      if updatepo
        p = NetSuite::Records::PurchaseOrder.new({
                                                   internal_id: nspo.internal_id,
                                                   external_id: nspo.external_id
                                                 })
        attributes = nspo.attributes
        attributes[:item_list].items.each do |item|
          item.attributes = item.attributes.slice(:line, :quantity)
        end

        p.update({ item_list: attributes[:item_list] })
        if p.errors.any? { |e| e.type != 'WARN' }
          raise "Receipt create failed: #{p.errors.map(&:message)}"
       end
      end
    end

    def find_po_by_tran_id(tran_id)
      NetSuite::Records::PurchaseOrder.search(
        criteria: {
          basic: [{
            field: 'tranId',
            operator: 'is',
            value: tran_id
          }]
        },
        preferences: {
          pageSize: 100,
          bodyFieldsOnly: false
        }
      ).results.first
    end
  end
end
