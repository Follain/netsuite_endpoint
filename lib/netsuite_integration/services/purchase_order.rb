module NetsuiteIntegration
  module Services
    class PurchaseOrder < Base
      attr_reader :poll_param

      def initialize(config, poll_param = 'netsuite_last_updated_after')
        super config
        @poll_param = poll_param
      end

      def latest
        search.sort_by { |c| c.last_modified_date.utc }
      end

      private

      def search
        NetSuite::Records::PurchaseOrder
          .search(criteria: {
                    basic: basic_criteria.push(polling_filter)
                  },
                  preferences: default_preferences).results
      end

      def default_preferences
        {
          pageSize: 600,
          bodyFieldsOnly: false
        }
      end

      def basic_criteria
        [
          field: 'status',
          operator: 'anyOf',
          type: 'SearchEnumMultiSelectField',
          value: %w[_purchaseOrderPendingReceipt _purchaseOrderClosed]
        ]
      end

      def polling_filter
        {
          field: 'lastModifiedDate',
          type: 'SearchDateField',
          operator: 'within',
          value: [
            last_updated_after,
            time_now.iso8601
          ]
        }
      end

      def time_now
        Time.now.utc
      end

      def last_updated_after
        Time.parse(config.fetch(poll_param)).iso8601
      end
    end
  end
end
