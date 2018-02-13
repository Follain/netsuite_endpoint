module NetsuiteIntegration
  module Services
    # Make sure "Sell Downloadble Files" is enabled in your NetSuite account
    # otherwise search won't work
    #
    # In order to retrieve a Matrix Item you also need to enable "Matrix Items"
    # in your Company settings
    #
    # Specify Item type because +search+ maps to NetSuite ItemSearch object
    # which will bring all kinds of items and not only inventory items
    #
    # Records need to be ordered by lastModifiedDate programatically since
    # NetSuite api doesn't allow us to do that on the request. That's the
    # reason the search lets the page size default of 1000 records. We'd better
    # catch all items at once and sort by date properly or we might end up
    # losing data
    class InventoryItem < Base
      attr_reader :poll_param

      def initialize(config, poll_param = 'netsuite_last_updated_after')
        super config
        @poll_param = poll_param
      end

      def latest
        valid_items.sort_by { |c| c.last_modified_date.utc }
      end

      def find_by_item_name(name)
        NetSuite::Records::InventoryItem.search({
          criteria: {
            basic: [{
              field: 'displayName',
              value: name,
              operator: 'contains'
            }]
          }
        }).results.first
      end

      def find_by_item_id(item_id)
        NetSuite::Records::InventoryItem.search({
          criteria: {
            basic: basic_criteria_all + [{ field: 'itemId', value: item_id, operator: 'is' }]
          },
          preferences: default_preferences
        }).results.first
      end

      # See ItemTypes examples here https://system.netsuite.com/help/helpcenter/en_US/SchemaBrowser/lists/v2013_2_0/accountingTypes.html#listAcctTyp:ItemType
      def item_type_to_fetch
        if (item_types = config["netsuite_item_types"]).present?
          item_types.split(";").map(&:strip).map do |item_type|
            # need this hack because of inconsistent type naming
            # https://github.com/spree/netsuite_endpoint/issues/7#issuecomment-41196467
            case item_type
            when 'AssemblyItem'
              '_assembly'
            when 'KitItem'
              '_kit'
            else
              "_#{item_type[0].downcase}#{item_type[1..-1]}"
            end
          end
        else
          ['_inventoryItem','_assembly']
        end
      end

      private
        def valid_items
          items = search

          ignored_items = ignore_future items
          drop_invalid_ids ignored_items
        end

        # We need to set bodyFieldsOnly false to grab the pricing matrix
        def search
          NetSuite::Records::InventoryItem.search({
            criteria: {
              basic: basic_criteria.push(polling_filter)
            },
            preferences: default_preferences
          }).results
        end

        def default_preferences
          {
            pageSize: 80,
            bodyFieldsOnly: false
          }
        end

        def basic_criteria
          [
            {
              field: 'type',
              operator: 'anyOf',
              type: 'SearchEnumMultiSelectField',
              value: item_type_to_fetch
            },
            {
              field: 'isInactive',
              value: false
            }
          ]
        end

         def basic_criteria_all
          [
            {
              field: 'type',
              operator: 'anyOf',
              type: 'SearchEnumMultiSelectField',
              value: item_type_to_fetch
            }
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

        def ignore_future(items)
          items.select do |item|
            item.last_modified_date.utc <= time_now
          end
        end

        def drop_invalid_ids(items)
          items.select { |item| item.item_id.present? }
        end

        # Help us mock this when running the specs. Otherwise we might get VCR
        # as different request might be done depending on this timestamp
        def time_now
          Time.now.utc
        end

        def last_updated_after
          Time.parse(config.fetch(poll_param)).iso8601
        end
    end
  end
end
