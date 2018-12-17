module NetsuiteIntegration
    class Location
      attr_reader :config, :collection

      def initialize(config)
        @config = config
        @collection = Services::Location.new(@config).latest
      end

      def messages
        @messages ||= locations
      end

      def last_modified_date
        DateTime.now
      end

      def locations
        collection.map do |location|
          {
            id: location.internal_id,
            name: location.name,
            channel: 'NetSuite'
          }
        end
      end
    end
  end
